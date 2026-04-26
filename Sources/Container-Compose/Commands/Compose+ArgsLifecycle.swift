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
    /// Container identity and lifecycle flags: platform, name, detach,
    /// stdin/tty, and (in Phase 2E) restart, stop_signal, stop_grace_period,
    /// init, pull_policy, runtime, post_start, pre_stop.
    enum LifecycleArgs {
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []

            if let platform = ctx.service.platform {
                args.append(contentsOf: ["--platform", platform])
            }

            if ctx.detach {
                args.append("-d")
            }

            args.append(contentsOf: ["--name", ctx.containerName])

            if ctx.service.stdin_open == true { args.append("-i") }
            if ctx.service.tty == true { args.append("-t") }

            // NOTE: service.restart is parsed but not applied — `container run`
            // doesn't expose --restart. Phase 2E will route this through the
            // higher-level container restart manager when available.

            return args
        }
    }
}
