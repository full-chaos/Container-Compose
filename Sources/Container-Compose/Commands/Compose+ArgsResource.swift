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
    /// CPU, memory, and other resource-tuning flags. Today: cpus and memory
    /// from `deploy.resources.limits`. Phase 2B adds top-level service.cpus,
    /// mem_limit, mem_reservation, pids_limit, shm_size, ulimits, oom_*.
    enum ResourceArgs {
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []

            if let cpus = ctx.service.deploy?.resources?.limits?.cpus {
                args.append(contentsOf: ["--cpus", cpus])
            }
            if let memory = ctx.service.deploy?.resources?.limits?.memory {
                args.append(contentsOf: ["--memory", memory])
            }

            return args
        }
    }
}
