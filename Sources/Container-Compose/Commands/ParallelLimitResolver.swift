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

import ArgumentParser
import Foundation

// MARK: - ParallelLimitResolver

/// Resolves the effective parallel-operation limit for fan-out commands
/// (`pull`, `build`, image-prep phases of `up`/`create`). Centralized so
/// the CLI / env / default precedence is applied identically everywhere
/// — `ComposePull`, `ComposeBuild`, and `ComposeUp` all consult the same
/// resolver in Phase 2.
///
/// CHAOS-1446 Phase 1 ships only the resolver. Phase 2 wires the
/// `--parallel` CLI flag (per Lead Decision D1, on the relevant commands
/// — NOT on `ProjectFlags`, to avoid polluting non-fan-out subcommands).
public enum ParallelLimitResolver {

    /// Default concurrency cap when no CLI flag and no env var is set.
    /// 16 matches Docker Compose's `COMPOSE_PARALLEL_LIMIT` default and
    /// is large enough to saturate a typical multi-service compose file
    /// without flooding the host with subprocesses.
    public static let defaultLimit: Int = 16

    /// Name of the env var consulted when no CLI flag is supplied.
    public static let envVarName: String = "COMPOSE_PARALLEL_LIMIT"

    /// Resolve the effective limit honoring the precedence chain:
    /// 1. `cli` (if non-nil) — wins even if env is invalid.
    /// 2. `env[envVarName]` (if set) — must parse as positive integer.
    /// 3. `defaultLimit`.
    ///
    /// Throws `ArgumentParser.ValidationError` for any invalid value the
    /// resolver was actually consulted on (cli < 1, or env that is
    /// non-integer / zero / negative when no cli was supplied). An
    /// invalid env var with a valid CLI is silently ignored — CLI
    /// always wins per the precedence contract.
    ///
    /// - Parameters:
    ///   - cli: value of `--parallel <N>` from the user's invocation;
    ///     `nil` means the flag was not supplied.
    ///   - env: process environment dictionary. Production callers pass
    ///     `ProcessInfo.processInfo.environment`; tests pass synthesized
    ///     dictionaries to exercise edge cases.
    /// - Returns: a validated positive `Int`.
    public static func resolved(
        cli: Int?,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        if let cli {
            guard cli >= 1 else {
                throw ValidationError("--parallel must be >= 1 (got \(cli))")
            }
            return cli
        }

        if let raw = env[envVarName] {
            guard let parsed = Int(raw) else {
                throw ValidationError(
                    "\(envVarName) must be a positive integer (got '\(raw)')"
                )
            }
            guard parsed >= 1 else {
                throw ValidationError(
                    "\(envVarName) must be >= 1 (got \(parsed))"
                )
            }
            return parsed
        }

        return defaultLimit
    }
}
