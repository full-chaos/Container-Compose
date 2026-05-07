//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

extension ComposeUp {
    /// CPU, memory, pids, shm, OOM, ulimits and other resource-tuning flags.
    ///
    /// Override policy: top-level service properties take precedence over the
    /// equivalent field under `deploy.resources.limits`. When a top-level
    /// value is present the deploy value is skipped entirely so each flag
    /// appears in the argv exactly once.
    enum ResourceArgs {
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []
            let svc = ctx.service

            // --cpus: precedence:
            //   1. top-level `cpus` (cpus_top)
            //   2. `deploy.resources.limits.cpus`
            //   3. `deploy.resources.reservations.cpus` (degraded fallback)
            //
            // Apple container's `--cpus` is a fixed VM allocation, not a soft floor.
            // Compose `reservations` semantics (cgroup-style soft minimum under contention)
            // are not meaningful in the VM-per-container model — each container is its own
            // dedicated VM with no inter-container contention inside it. When a reservation
            // is the only signal we have, we map it onto `--cpus` as a fixed allocation and
            // warn the user that Docker-style soft semantics are not honored. When a limit
            // is also present, the limit wins and we warn that the reservation is ignored.
            // See CHAOS-1336 + docs/feature-parity.md (Tier 1).
            let cpuLimit = svc.cpus_top.map { String($0) } ?? svc.deploy?.resources?.limits?.cpus
            let cpuReservation = svc.deploy?.resources?.reservations?.cpus

            if let cpus = cpuLimit {
                args.append(contentsOf: ["--cpus", cpus])
                if cpuReservation != nil {
                    warnCpuReservationIgnored(limit: cpus, reservation: cpuReservation)
                }
            } else if let cpus = cpuReservation {
                warnUnsupportedRuntimeFieldOnce(
                    "service.deploy.resources.reservations.cpus",
                    "Note: 'service.deploy.resources.reservations.cpus' is mapped to '--cpus' as a fixed VM allocation; Apple container does not implement soft reservation semantics."
                )
                args.append(contentsOf: ["--cpus", cpus])
            }

            // --memory: precedence:
            //   1. top-level `mem_limit`
            //   2. `deploy.resources.limits.memory`
            //   3. top-level `mem_reservation` (degraded fallback)
            //   4. `deploy.resources.reservations.memory` (degraded fallback)
            //
            // Same rationale as --cpus above. See CHAOS-1336.
            let memLimit = svc.mem_limit ?? svc.deploy?.resources?.limits?.memory
            let topLevelMemReservation = svc.mem_reservation
            let deployMemReservation = svc.deploy?.resources?.reservations?.memory
            let memReservation = topLevelMemReservation ?? deployMemReservation

            if let mem = memLimit {
                args.append(contentsOf: ["--memory", mem])
                if memReservation != nil {
                    warnMemoryReservationIgnored(limit: mem, reservation: memReservation)
                }
            } else if let mem = memReservation {
                let key = topLevelMemReservation != nil
                    ? "service.mem_reservation"
                    : "service.deploy.resources.reservations.memory"
                warnUnsupportedRuntimeFieldOnce(
                    key,
                    "Note: '\(key)' is mapped to '--memory' as a fixed VM allocation; Apple container does not implement soft reservation semantics."
                )
                args.append(contentsOf: ["--memory", mem])
            }

            // Trivially-unsupported runtime fields (mem/cpu/oom/pids/shm/gpus):
            // each is a presence-only check that emits the same warn-once shape.
            // Centralized in `warnUnsupportedContainerRuntimeFields` so this
            // builder stays focused on argv emission. Bespoke comparisons
            // (cpu/memory reservation-vs-limit handling above) intentionally
            // remain inline because they pick a message based on values.
            warnUnsupportedContainerRuntimeFields(svc, supportsBlkioFlags: ctx.supportsBlkioFlags)

            args.append(contentsOf: blkioArgs(for: svc.blkio_config, supportsBlkioFlags: ctx.supportsBlkioFlags))

            // --ulimit NAME=SOFT:HARD (or NAME=VALUE when soft == hard)
            if let ulimits = svc.ulimits {
                for (name, ulimit) in ulimits.sorted(by: { $0.key < $1.key }) {
                    if ulimit.soft == ulimit.hard {
                        args.append(contentsOf: ["--ulimit", "\(name)=\(ulimit.soft)"])
                    } else {
                        args.append(contentsOf: ["--ulimit", "\(name)=\(ulimit.soft):\(ulimit.hard)"])
                    }
                }
            }

            return args
        }

        static func blkioArgs(for blkio: BlkioConfig?, supportsBlkioFlags: Bool) -> [String] {
            guard supportsBlkioFlags, let blkio else { return [] }

            var args: [String] = []

            if let weight = blkio.weight {
                args.append(contentsOf: ["--blkio-weight", "\(weight)"])
            }

            for device in blkio.weight_device ?? [] {
                args.append(contentsOf: ["--blkio-weight-device", "\(device.path):\(device.weight)"])
            }

            for device in blkio.device_read_bps ?? [] {
                args.append(contentsOf: ["--device-read-bps", "\(device.path):\(device.rate)"])
            }

            for device in blkio.device_write_bps ?? [] {
                args.append(contentsOf: ["--device-write-bps", "\(device.path):\(device.rate)"])
            }

            for device in blkio.device_read_iops ?? [] {
                args.append(contentsOf: ["--device-read-iops", "\(device.path):\(device.rate)"])
            }

            for device in blkio.device_write_iops ?? [] {
                args.append(contentsOf: ["--device-write-iops", "\(device.path):\(device.rate)"])
            }

            return args
        }

        static func supportsBlkioFlags(for command: String) async -> Bool {
            let probe = Process()
            probe.executableURL = URL(filePath: "/usr/bin/env")
            probe.arguments = ["container", command, "--blkio-weight", "500", "--help"]
            probe.standardOutput = Pipe()
            probe.standardError = Pipe()

            do {
                try probe.run()
                probe.waitUntilExit()
                return probe.terminationStatus == 0
            } catch {
                return false
            }
        }

        private static func warnCpuReservationIgnored(limit: String, reservation: String?) {
            guard let reservation else { return }

            if let limitValue = Double(limit),
               let reservationValue = Double(reservation),
               reservationValue > limitValue {
                warnUnsupportedRuntimeFieldOnce(
                    "service.cpu.reservation-exceeds-limit",
                    "Note: reservation (\(reservation)) exceeds limit (\(limit)); reservation will be ignored. This is invalid compose input — please fix the YAML."
                )
            } else {
                warnUnsupportedRuntimeFieldOnce(
                    "service.cpu.reservation-with-limit",
                    "Note: CPU reservation is ignored because a CPU limit is set; Apple container does not implement soft reservation semantics (limit applied as fixed VM allocation)."
                )
            }
        }

        private static func warnMemoryReservationIgnored(limit: String, reservation: String?) {
            guard let reservation else { return }

            if let limitBytes = try? parseComposeMemoryBytes(limit),
               let reservationBytes = try? parseComposeMemoryBytes(reservation),
               reservationBytes > limitBytes {
                warnUnsupportedRuntimeFieldOnce(
                    "service.memory.reservation-exceeds-limit",
                    "Note: reservation (\(reservation)) exceeds limit (\(limit)); reservation will be ignored. This is invalid compose input — please fix the YAML."
                )
            } else {
                warnUnsupportedRuntimeFieldOnce(
                    "service.memory.reservation-with-limit",
                    "Note: memory reservation is ignored because a memory limit is set; Apple container does not implement soft reservation semantics (limit applied as fixed VM allocation)."
                )
            }
        }
    }
}
