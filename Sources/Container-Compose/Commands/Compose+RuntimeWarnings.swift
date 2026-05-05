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

/// Emits warn-once notices for service runtime fields that are parsed from the
/// compose file but not honored by Apple container's `container run` argv. Mirrors
/// `warnUnsupportedContainerBuildFields` and centralizes the otherwise repetitive
/// `if svc.X != nil { warnUnsupportedRuntimeFieldOnce(...) }` blocks that
/// previously lived inline across `ResourceArgs`. Bespoke comparisons (cpu /
/// memory reservation-vs-limit) intentionally stay inline because they pick a
/// message based on field values, not just presence.
///
/// Field-key strings (the first arg to `warnUnsupportedRuntimeFieldOnce`) are
/// load-bearing: they are dedup keys used by tests and by the warn-once
/// machinery to ensure each unsupported field prints at most once per process.
/// Message text is also asserted by tests — change either with care.
func warnUnsupportedContainerRuntimeFields(_ svc: Service) {
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
    if svc.shm_size != nil {
        warnUnsupportedRuntimeFieldOnce(
            "service.shm_size",
            "Note: 'shm_size' is parsed but not supported by Apple container; ignored."
        )
    }

    // --oom-kill-disable (flag only, emitted when true). `oom_kill_disable`
    // is `Bool?`; an explicit `false` should NOT warn — the user is opting in
    // to the default behavior, which Apple container already provides.
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
}

/// Emits warn-once notices for storage-adjacent service fields that Apple
/// container does not honor (`sysctls`, `devices`). Both fields use the
/// `!isEmpty` guard so an explicit empty mapping/list silently no-ops, which
/// matches the inline behavior these calls replaced.
func warnUnsupportedContainerStorageFields(_ svc: Service) {
    if let sysctls = svc.sysctls, !sysctls.isEmpty {
        warnUnsupportedRuntimeFieldOnce(
            "service.sysctls",
            "Note: 'sysctls' is parsed but not supported by Apple container; ignored."
        )
    }

    if let devices = svc.devices, !devices.isEmpty {
        warnUnsupportedRuntimeFieldOnce(
            "service.devices",
            "Note: 'devices' is parsed but not supported by Apple container; ignored."
        )
    }
}

/// Emits warn-once notices for the lifecycle-stop fields (`stop_signal`,
/// `stop_grace_period`). Apple container's `container run` accepts neither
/// `--stop-signal` nor `--stop-timeout` (verified Tier 0 R2 audit), so these
/// always warn-and-skip. Used by `ComposeRun` (the `compose run` one-off path)
/// to mirror the equivalent logic in `LifecycleArgs` for the standard `up`
/// path. Warn-once dedup means calling from both sites is safe.
func warnUnsupportedContainerLifecycleStopFields(_ svc: Service) {
    if svc.stop_signal != nil {
        warnUnsupportedRuntimeFieldOnce(
            "service.stop_signal",
            "Note: 'service.stop_signal' is parsed but not supported by Apple container; ignored."
        )
    }

    if svc.stop_grace_period != nil {
        warnUnsupportedRuntimeFieldOnce(
            "service.stop_grace_period",
            "Note: 'service.stop_grace_period' is parsed but not supported by Apple container; ignored."
        )
    }
}
