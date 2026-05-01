//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
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

// MARK: - SystemKeyCommands

enum SystemKeyCommands {
    /// Returns the auth store URL, defaulting to `~/.container-compose/auth.json`.
    /// Tilde expansion is handled for explicit overrides.
    static func resolveAuthFile(_ override: String?) -> URL {
        guard let path = override, !path.isEmpty else {
            return ServeDaemon.defaultAuthFilePath
        }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}
