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
    /// Filesystem and storage flags: working_dir and tmpfs.
    /// devices, sysctls, volumes_from, device_cgroup_rules, and storage_opt are
    /// unsupported by Apple container and emit a warning instead of flags.
    ///
    /// `volumes` mounting stays inline in `configService` for now because
    /// `configVolume(_:)` is async and mutates the filesystem (creating
    /// missing host directories).
    enum StorageArgs {
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []

            // working_dir — supports ${VAR} substitution
            if let workingDir = ctx.service.working_dir {
                let resolved = resolveVariable(workingDir, with: ctx.environmentVariables)
                args.append(contentsOf: ["--workdir", resolved])
            }

            // tmpfs — one --tmpfs flag per mount path
            if let tmpfsList = ctx.service.tmpfs {
                for path in tmpfsList {
                    args.append(contentsOf: ["--tmpfs", path])
                }
            }

            // sysctls — not supported by Apple container; warn once and skip
            if let sysctls = ctx.service.sysctls, !sysctls.isEmpty {
                warnUnsupportedRuntimeFieldOnce("service.sysctls", "Note: 'sysctls' is parsed but not supported by Apple container; ignored.")
            }

            // devices — not supported by Apple container; warn once and skip
            if let devices = ctx.service.devices, !devices.isEmpty {
                warnUnsupportedRuntimeFieldOnce("service.devices", "Note: 'devices' is parsed but not supported by Apple container; ignored.")
            }

            // volumes_from — not supported by Apple container; warn and skip
            if let volumesFrom = ctx.service.volumes_from, !volumesFrom.isEmpty {
                print("Note: 'volumes_from' for service '\(ctx.serviceName)' is not supported by Apple container; ignored.")
            }

            // device_cgroup_rules — not supported by Apple container; warn and skip
            if let deviceCgroupRules = ctx.service.device_cgroup_rules, !deviceCgroupRules.isEmpty {
                print("Note: 'device_cgroup_rules' for service '\(ctx.serviceName)' is not supported by Apple container; ignored.")
            }

            // storage_opt — not supported by Apple container; warn and skip
            if let storageOpt = ctx.service.storage_opt, !storageOpt.isEmpty {
                print("Note: 'storage_opt' for service '\(ctx.serviceName)' is not supported by Apple container; ignored.")
            }

            return args
        }
    }
}
