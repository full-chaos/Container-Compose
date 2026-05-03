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

            // --memory-swappiness
            if svc.mem_swappiness != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.mem_swappiness",
                    "Note: 'mem_swappiness' is parsed but not supported by Apple container; ignored."
                )
            }

            // --memory-swap
            if svc.memswap_limit != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.memswap_limit",
                    "Note: 'memswap_limit' is parsed but not supported by Apple container; ignored."
                )
            }

            // --pids-limit
            if svc.pids_limit != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.pids_limit",
                    "Note: 'pids_limit' is parsed but not supported by Apple container; ignored."
                )
            }

            // --shm-size
            if let shm = svc.shm_size {
                args.append(contentsOf: ["--shm-size", shm])
            }

            // --oom-kill-disable (flag only, emitted when true)
            if svc.oom_kill_disable == true {
                warnUnsupportedRuntimeFieldOnce(
                    "service.oom_kill_disable",
                    "Note: 'oom_kill_disable' is parsed but not supported by Apple container; ignored."
                )
            }

            // --oom-score-adj
            if svc.oom_score_adj != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.oom_score_adj",
                    "Note: 'oom_score_adj' is parsed but not supported by Apple container; ignored."
                )
            }

            // --cpu-shares
            if svc.cpu_shares != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.cpu_shares",
                    "Note: 'cpu_shares' is parsed but not supported by Apple container; ignored."
                )
            }

            // --cpuset-cpus
            if svc.cpuset != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.cpuset",
                    "Note: 'cpuset' is parsed but not supported by Apple container; ignored."
                )
            }

            // --cpu-period
            if svc.cpu_period != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.cpu_period",
                    "Note: 'cpu_period' is parsed but not supported by Apple container; ignored."
                )
            }

            // --cpu-quota
            if svc.cpu_quota != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.cpu_quota",
                    "Note: 'cpu_quota' is parsed but not supported by Apple container; ignored."
                )
            }

            // --cpu-rt-period
            if svc.cpu_rt_period != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.cpu_rt_period",
                    "Note: 'cpu_rt_period' is parsed but not supported by Apple container; ignored."
                )
            }

            // --cpu-rt-runtime
            if svc.cpu_rt_runtime != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.cpu_rt_runtime",
                    "Note: 'cpu_rt_runtime' is parsed but not supported by Apple container; ignored."
                )
            }

            // --cpu-count
            if svc.cpu_count != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.cpu_count",
                    "Note: 'cpu_count' is parsed but not supported by Apple container; ignored."
                )
            }

            // --cpu-percent
            if svc.cpu_percent != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.cpu_percent",
                    "Note: 'cpu_percent' is parsed but not supported by Apple container; ignored."
                )
            }

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

            // --gpus
            if svc.gpus != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.gpus",
                    "Note: 'gpus' is parsed but not supported by Apple container; ignored."
                )
            }

            // blkio_config
            if svc.blkio_config != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.blkio_config",
                    "Note: 'blkio_config' is parsed but not supported by Apple container; ignored."
                )
            }

            return args
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
