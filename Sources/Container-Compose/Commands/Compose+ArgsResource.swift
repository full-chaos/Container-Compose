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
            if svc.mem_reservation != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.mem_reservation",
                    "Note: 'mem_reservation' is parsed but not supported by Apple container; ignored."
                )
            } else if svc.deploy?.resources?.reservations?.memory != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.deploy.resources.reservations.memory",
                    "Note: 'deploy.resources.reservations.memory' is parsed but not supported by Apple container; ignored."
                )
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
    }
}
