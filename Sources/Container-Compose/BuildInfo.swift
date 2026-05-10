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

/// Build-time identification metadata. Default values represent a clean
/// release build — `Main.versionString` then prints just the marketing
/// version (e.g. `container-compose version 0.11.0`).
///
/// Non-release builds (`make debug`, `make build-stamped`, CI snapshots)
/// overwrite this file via `make version-stamp` so the running binary
/// reports the exact commit it was built from. Reset with
/// `make clean-version-stamp` (or just `make build` / `make release`,
/// which depend on it).
///
/// IMPORTANT: do not commit a modified version of this file. The release
/// targets restore the empty default before building so a tagged release
/// always reports a clean version string. Local developer modifications
/// from `make debug` are expected to revert via `make clean-version-stamp`
/// before opening a PR.
public enum BuildInfo {
    /// Short git SHA of the commit this binary was built from. Empty
    /// string means "release build, no commit suffix".
    public static let gitCommit: String = ""

    /// Build kind tag. `"release"` for tagged release builds; `"snapshot"`
    /// for non-release builds stamped by `make version-stamp`. Combined
    /// with `gitCommit` in the version string when non-empty + non-release.
    public static let buildKind: String = "release"
}
