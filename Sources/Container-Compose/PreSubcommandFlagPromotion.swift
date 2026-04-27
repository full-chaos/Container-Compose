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

/// Reorders argv so that recognized global flags placed BEFORE the subcommand
/// are moved to immediately AFTER the subcommand.
///
/// `swift-argument-parser` only recognizes `@Option` flags in the position
/// where they're declared — i.e. after the subcommand. `docker compose` users
/// expect to be able to write the globals first, e.g.
///
///     container-compose -f compose.yml build
///
/// This helper rewrites that to:
///
///     container-compose build -f compose.yml
///
/// before the parser sees it, matching the `docker compose` UX.
///
/// Recognized globals (PLAN.md §3.3 option 2):
///   - `-f` / `--file`
///   - `-p` / `--project-name`
///   - `--profile`
///   - `--env-file`
///   - `--project-directory`
///
/// Behavior:
///   - Walks args left-to-right. For each recognized global before the first
///     non-flag token (= the subcommand), captures the flag and its value.
///     Equals-form (`--file=path`) is captured as a single token; space-form
///     (`-f path`) consumes the next token.
///   - Order of repeated flags is preserved (e.g. `--profile a --profile b`).
///   - Stops scanning as soon as it hits a non-flag — that token is the
///     subcommand. Everything from the subcommand onward stays in place,
///     with the captured globals inserted IMMEDIATELY AFTER the subcommand.
///   - Unrecognized flags before the subcommand are left in their original
///     position. swift-argument-parser will produce its normal error.
///   - If no subcommand is found (all tokens are flags, e.g. `--help` or
///     `--version`), returns the args unchanged.
///   - Empty input returns empty output.
///
/// - Parameter args: The captured argv (without the program name).
/// - Returns: The reordered argv.
public func promoteGlobalFlags(_ args: [String]) -> [String] {
    guard !args.isEmpty else { return args }

    // Recognized global option flag tokens. None are bool — each takes one value.
    let recognizedGlobals: Set<String> = [
        "-f", "--file",
        "-p", "--project-name",
        "--profile",
        "--env-file",
        "--project-directory",
    ]

    var leading: [String] = []          // tokens we leave where they are (unrecognized flags)
    var promoted: [String] = []         // captured globals, to insert after subcommand
    var i = 0

    while i < args.count {
        let token = args[i]

        // Once we hit a non-flag, that's the subcommand — stop scanning.
        if !token.hasPrefix("-") {
            break
        }

        // Equals form: --file=path or --profile=dev
        if let eqRange = token.range(of: "=") {
            let name = String(token[..<eqRange.lowerBound])
            if recognizedGlobals.contains(name) {
                promoted.append(token)
                i += 1
                continue
            }
            // Unrecognized — leave in place.
            leading.append(token)
            i += 1
            continue
        }

        // Space-separated form: -f path / --profile dev
        if recognizedGlobals.contains(token) {
            promoted.append(token)
            i += 1
            // Consume the next token as the value if it exists.
            if i < args.count {
                promoted.append(args[i])
                i += 1
            }
            continue
        }

        // Unrecognized flag — leave in place.
        leading.append(token)
        i += 1
    }

    // No subcommand found (only flags, e.g. --help / --version) — return unchanged.
    if i >= args.count {
        return args
    }

    // i points at the subcommand. Trailing args = subcommand + everything after.
    let subcommand = args[i]
    let trailing = Array(args[(i + 1)...])

    // If we didn't promote anything, return the original args unchanged
    // (preserves exact ordering of unrecognized leading flags).
    if promoted.isEmpty {
        return args
    }

    return leading + [subcommand] + promoted + trailing
}
