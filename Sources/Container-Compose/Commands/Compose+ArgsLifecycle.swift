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

            // --init: only emitted when explicitly set to true
            if ctx.service.init_ == true {
                args.append("--init")
            }

            // apple/container does not accept --stop-signal / --stop-timeout
            // (verified Tier 0 R2 audit). Centralized in Compose+RuntimeWarnings.
            warnUnsupportedContainerLifecycleStopFields(ctx.service)

            // --runtime: pass the runtime name
            if let runtime = ctx.service.runtime {
                args.append(contentsOf: ["--runtime", runtime])
            }

            if let restart = ctx.service.restart {
                args.append(contentsOf: ["--restart", restart])
            }

            // logging: parsed, but Apple container does not expose
            // --log-driver / --log-opt on `container run`.
            warnUnsupportedContainerLoggingFields(ctx.service)

            return args
        }

        /// Parses a Go duration string (e.g. "30s", "1m", "1m30s") or a raw
        /// integer string (e.g. "5") into an integer number of seconds.
        ///
        /// Supported units: `h` (hours), `m` (minutes), `s` (seconds).
        /// Returns `nil` if the string cannot be parsed.
        static func parseGoDuration(_ input: String) -> Int? {
            let trimmed = input.trimmingCharacters(in: .whitespaces)

            // Fast path: raw integer (no unit suffix)
            if let raw = Int(trimmed) {
                return raw
            }

            // Parse sequences of <digits><unit>
            var total = 0
            var remaining = trimmed[...]
            var matched = false

            let unitMultipliers: [(suffix: String, multiplier: Int)] = [
                ("h", 3600),
                ("m", 60),
                ("s", 1),
            ]

            while !remaining.isEmpty {
                // Consume leading digits
                let digits = remaining.prefix(while: { $0.isNumber })
                guard !digits.isEmpty, let value = Int(digits) else { break }
                remaining = remaining.dropFirst(digits.count)

                // Match a unit character
                var unitFound = false
                for (suffix, multiplier) in unitMultipliers {
                    if remaining.hasPrefix(suffix) {
                        total += value * multiplier
                        remaining = remaining.dropFirst(suffix.count)
                        unitFound = true
                        matched = true
                        break
                    }
                }
                guard unitFound else { break }
            }

            // Valid only if we consumed the entire string and matched something
            guard matched, remaining.isEmpty else { return nil }
            return total
        }
    }
}
