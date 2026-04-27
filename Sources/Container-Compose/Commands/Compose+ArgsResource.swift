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

            // --cpus: top-level cpus_top wins over deploy.resources.limits.cpus
            if let cpus = svc.cpus_top {
                args.append(contentsOf: ["--cpus", String(cpus)])
            } else if let cpus = svc.deploy?.resources?.limits?.cpus {
                args.append(contentsOf: ["--cpus", cpus])
            }

            // --memory: top-level mem_limit wins over deploy.resources.limits.memory
            if let mem = svc.mem_limit {
                args.append(contentsOf: ["--memory", mem])
            } else if let mem = svc.deploy?.resources?.limits?.memory {
                args.append(contentsOf: ["--memory", mem])
            }

            // --memory-reservation
            if let memReservation = svc.mem_reservation {
                args.append(contentsOf: ["--memory-reservation", memReservation])
            }

            // --memory-swappiness
            if let swappiness = svc.mem_swappiness {
                args.append(contentsOf: ["--memory-swappiness", String(swappiness)])
            }

            // --memory-swap
            if let memswap = svc.memswap_limit {
                args.append(contentsOf: ["--memory-swap", memswap])
            }

            // --pids-limit
            if let pids = svc.pids_limit {
                args.append(contentsOf: ["--pids-limit", String(pids)])
            }

            // --shm-size
            if let shm = svc.shm_size {
                args.append(contentsOf: ["--shm-size", shm])
            }

            // --oom-kill-disable (flag only, emitted when true)
            if svc.oom_kill_disable == true {
                args.append("--oom-kill-disable")
            }

            // --oom-score-adj
            if let oomScore = svc.oom_score_adj {
                args.append(contentsOf: ["--oom-score-adj", String(oomScore)])
            }

            // --cpu-shares
            if let shares = svc.cpu_shares {
                args.append(contentsOf: ["--cpu-shares", String(shares)])
            }

            // --cpuset-cpus
            if let cpuset = svc.cpuset {
                args.append(contentsOf: ["--cpuset-cpus", cpuset])
            }

            // --cpu-period
            if let period = svc.cpu_period {
                args.append(contentsOf: ["--cpu-period", String(period)])
            }

            // --cpu-quota
            if let quota = svc.cpu_quota {
                args.append(contentsOf: ["--cpu-quota", String(quota)])
            }

            // --cpu-rt-period
            if let rtPeriod = svc.cpu_rt_period {
                args.append(contentsOf: ["--cpu-rt-period", String(rtPeriod)])
            }

            // --cpu-rt-runtime
            if let rtRuntime = svc.cpu_rt_runtime {
                args.append(contentsOf: ["--cpu-rt-runtime", String(rtRuntime)])
            }

            // --cpu-count
            if let count = svc.cpu_count {
                args.append(contentsOf: ["--cpu-count", String(count)])
            }

            // --cpu-percent
            if let percent = svc.cpu_percent {
                args.append(contentsOf: ["--cpu-percent", String(percent)])
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

            // --gpus — emit as --gpus (warn-emit: Apple container may not support this flag)
            if let gpus = svc.gpus {
                switch gpus {
                case .all:
                    args.append(contentsOf: ["--gpus", "all"])
                case .requests(let requests):
                    for req in requests {
                        var spec: [String] = []
                        if let count = req.count { spec.append("count=\(count)") }
                        if let ids = req.device_ids, !ids.isEmpty {
                            spec.append("device=\(ids.joined(separator: ","))")
                        }
                        if let caps = req.capabilities, !caps.isEmpty {
                            spec.append("capabilities=\(caps.joined(separator: ","))")
                        }
                        args.append(contentsOf: ["--gpus", spec.joined(separator: ",")])
                    }
                }
                print("Note: 'gpus' is parsed and forwarded as --gpus; Apple container may reject this flag.")
            }

            // blkio_config — emit per-field (warn-emit: Apple container may not support these flags)
            if let blkio = svc.blkio_config {
                if let w = blkio.weight {
                    args.append(contentsOf: ["--blkio-weight", "\(w)"])
                }
                for d in blkio.weight_device ?? [] {
                    args.append(contentsOf: ["--blkio-weight-device", "\(d.path):\(d.weight)"])
                }
                for d in blkio.device_read_bps ?? [] {
                    args.append(contentsOf: ["--device-read-bps", "\(d.path):\(d.rate)"])
                }
                for d in blkio.device_write_bps ?? [] {
                    args.append(contentsOf: ["--device-write-bps", "\(d.path):\(d.rate)"])
                }
                for d in blkio.device_read_iops ?? [] {
                    args.append(contentsOf: ["--device-read-iops", "\(d.path):\(d.rate)"])
                }
                for d in blkio.device_write_iops ?? [] {
                    args.append(contentsOf: ["--device-write-iops", "\(d.path):\(d.rate)"])
                }
                print("Note: 'blkio_config' is parsed and forwarded; Apple container may not support these flags.")
            }

            return args
        }
    }
}
