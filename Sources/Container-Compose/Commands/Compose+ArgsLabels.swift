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
    /// Emits `--label key=value` flags for each entry in `service.labels`.
    ///
    /// Labels are sorted by key so that the generated argv is deterministic
    /// across runs (important for tests and idempotent tooling).
    enum LabelsArgs {
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []
            if let labels = ctx.service.labels {
                for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
                    args.append(contentsOf: ["--label", "\(key)=\(value)"])
                }
            }
            return args
        }
    }
}
