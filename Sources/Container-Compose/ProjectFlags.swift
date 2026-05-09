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

import ArgumentParser
import Foundation

/// Project-context flags that match `docker compose`'s pre-subcommand globals.
///
/// Promoted from the pre-subcommand position by
/// `ArgvNormalizer.promoteGlobalFlags(_:)` (see `PreSubcommandFlagPromotion.swift`)
/// so that users can write
///
///     container-compose -p myproj --project-directory /some/path up
///
/// and have the flags reach the subcommand's parser.
///
/// Resolution precedence is centralised in `resolveProjectName(...)` and
/// `resolveProjectDirectory(...)` in `Helper Functions.swift`.
public struct ProjectFlags: ParsableArguments {
    public init() {}

    @Option(
        name: [.customShort("p"), .customLong("project-name")],
        help: "Project name override (defaults to compose 'name:' field, then cwd basename)."
    )
    public var projectName: String?

    @Option(
        name: .customLong("project-directory"),
        help: "Project root directory for resolving relative paths (defaults to the compose file's directory)."
    )
    public var projectDirectory: String?

    /// CHAOS-1446: bounded concurrency cap for image pull/build fan-out
    /// (`compose pull`, `compose build`, and the image-prep phase of
    /// `compose up`/`compose create`). When omitted, falls back to the
    /// `COMPOSE_PARALLEL_LIMIT` env var, then to
    /// `ParallelLimitResolver.defaultLimit` (16). Resolution is centralized
    /// in `ParallelLimitResolver.resolved(cli:env:)` so every call site
    /// applies the same precedence and validation.
    @Option(
        name: .customLong("parallel"),
        help: "Maximum concurrent image pulls/builds (default \(ParallelLimitResolver.defaultLimit), or COMPOSE_PARALLEL_LIMIT env var). Honored by pull/build/up/create; ignored elsewhere."
    )
    public var parallel: Int?
}
