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
    /// User identity, capability, and privilege flags: user, privileged,
    /// read_only, and (in Phase 2A) cap_add, cap_drop, security_opt,
    /// userns_mode, group_add.
    enum SecurityArgs {
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []

            if let user = ctx.service.user {
                args.append(contentsOf: ["--user", user])
            }
            if ctx.service.privileged == true { args.append("--privileged") }
            if ctx.service.read_only == true { args.append("--read-only") }

            // Phase 2A — capabilities & security flags
            for cap in ctx.service.cap_add ?? [] {
                args.append(contentsOf: ["--cap-add", cap])
            }
            for cap in ctx.service.cap_drop ?? [] {
                args.append(contentsOf: ["--cap-drop", cap])
            }
            for opt in ctx.service.security_opt ?? [] {
                args.append(contentsOf: ["--security-opt", opt])
            }
            if let userns = ctx.service.userns_mode {
                args.append(contentsOf: ["--userns", userns])
            }
            for group in ctx.service.group_add ?? [] {
                args.append(contentsOf: ["--group-add", group])
            }

            return args
        }
    }
}
