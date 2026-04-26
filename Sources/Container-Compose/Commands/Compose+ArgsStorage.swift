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
    /// Filesystem and storage flags: working_dir today. Phase 2D extends with
    /// tmpfs, devices, sysctls, volumes_from, init, stop_signal,
    /// stop_grace_period.
    ///
    /// `volumes` mounting stays inline in `configService` for now because
    /// `configVolume(_:)` is async and mutates the filesystem (creating
    /// missing host directories). Phase 2D will refactor that helper to be
    /// callable from a builder.
    enum StorageArgs {
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []

            if let workingDir = ctx.service.working_dir {
                let resolved = resolveVariable(workingDir, with: ctx.environmentVariables)
                args.append(contentsOf: ["--workdir", resolved])
            }

            return args
        }
    }
}
