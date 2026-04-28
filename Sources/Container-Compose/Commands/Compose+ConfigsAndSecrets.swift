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
    /// Builds bind-mount argv for service-level configs and secrets.
    ///
    /// For each `ServiceConfig` / `ServiceSecret` referenced by a service, this
    /// enum looks up the corresponding top-level `Config` / `Secret` definition
    /// to find its `file:` source path, then emits a `-v <hostPath>:<target>`
    /// pair for `container run`.
    ///
    /// Warnings are printed (not thrown) for unsupported or unresolvable cases:
    /// - Config / secret not present in the top-level map
    /// - Config / secret declared as `external:` (no local source file available)
    /// - Config / secret with a `file:` of nil
    /// - `uid`, `gid`, or `mode` fields — parsed but not enforceable via `-v`
    enum ConfigsSecretsArgs {
        /// Returns bind-mount argv for all service-level configs and secrets.
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []

            // MARK: Configs

            if let serviceConfigs = ctx.service.configs {
                for sc in serviceConfigs {
                    // Flatten [String: Config?]? → Config? for the given key
                    guard let topLevel = ctx.dockerCompose.configs?[sc.source] ?? nil else {
                        print("Warning: Service '\(ctx.serviceName)' references config '\(sc.source)' which is not defined at top-level; skipping.")
                        continue
                    }

                    if topLevel.external?.isExternal == true {
                        print("Warning: External config '\(sc.source)' has no source file; skipping mount.")
                        continue
                    }

                    guard let sourceFile = topLevel.file else {
                        print("Warning: Config '\(sc.source)' has no 'file:' source; skipping.")
                        continue
                    }

                    if topLevel.templateDriver != nil {
                        print("Note: 'template_driver' for config '\(sc.source)' Detected, But Not Supported by the current runtime; the raw file will be mounted as-is.")
                    }

                    let target = sc.target ?? "/\(sc.source)"
                    let resolvedSource = (sourceFile as NSString).expandingTildeInPath
                    args.append(contentsOf: ["-v", "\(resolvedSource):\(target)"])

                    if sc.uid != nil || sc.gid != nil || sc.mode != nil {
                        print("Note: uid/gid/mode for config '\(sc.source)' are parsed but not enforced via container run -v; the file's permissions on the host apply.")
                    }
                }
            }

            // MARK: Secrets

            if let serviceSecrets = ctx.service.secrets {
                for ss in serviceSecrets {
                    // Flatten [String: Secret?]? → Secret? for the given key
                    guard let topLevel = ctx.dockerCompose.secrets?[ss.source] ?? nil else {
                        print("Warning: Service '\(ctx.serviceName)' references secret '\(ss.source)' which is not defined at top-level; skipping.")
                        continue
                    }

                    if topLevel.external?.isExternal == true {
                        print("Warning: External secret '\(ss.source)' has no source file; skipping mount.")
                        continue
                    }

                    guard let sourceFile = topLevel.file else {
                        print("Warning: Secret '\(ss.source)' has no 'file:' source; skipping.")
                        continue
                    }

                    if topLevel.templateDriver != nil {
                        print("Note: 'template_driver' for secret '\(ss.source)' Detected, But Not Supported by the current runtime; the raw file will be mounted as-is.")
                    }

                    let target = ss.target ?? "/run/secrets/\(ss.source)"
                    let resolvedSource = (sourceFile as NSString).expandingTildeInPath
                    args.append(contentsOf: ["-v", "\(resolvedSource):\(target)"])

                    if ss.uid != nil || ss.gid != nil || ss.mode != nil {
                        print("Note: uid/gid/mode for secret '\(ss.source)' are parsed but not enforced via container run -v; the file's permissions on the host apply.")
                    }
                }
            }

            return args
        }
    }
}
