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

/// Probes for the Apple `container` CLI so dynamic tests skip cleanly on
/// machines without the runtime (e.g. CI runners, contributor laptops).
///
/// Dynamic tests apply this via Swift Testing's `.enabled(if:)` suite trait
/// rather than a per-test guard, because the suites' `ContainerDependentTrait`
/// boots the container system *before* the test body — a body-level guard
/// would never run.
public enum RuntimeAvailability {
    /// Returns true if `container --version` exits cleanly within a few seconds.
    public static func isAvailable() -> Bool {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["container", "--version"]
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]) { _, new in new }

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
