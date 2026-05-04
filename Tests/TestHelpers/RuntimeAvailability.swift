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
    /// Maximum time to wait for `container --version` before treating the
    /// runtime as unavailable. Apple's `container` daemon can wedge — XPC
    /// connections cycle activate→cancel forever — and an unbounded wait
    /// would hang every dynamic suite's `.enabled(if:)` check, blowing up
    /// total test runtime.
    private static let probeTimeoutSeconds: TimeInterval = 5.0

    /// Cached probe result. Computed once per test process to avoid spawning
    /// N child processes for N suites (each suite trait calls `isAvailable()`).
    nonisolated(unsafe) private static var cachedResult: Bool?
    private static let cacheLock = NSLock()

    /// Returns true if `container --version` exits cleanly within
    /// `probeTimeoutSeconds`. The result is cached for the lifetime of the
    /// test process; subsequent calls return without re-probing.
    public static func isAvailable() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedResult { return cached }
        let result = probe()
        cachedResult = result
        return result
    }

    private static func probe() -> Bool {
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

        let deadline = Date().addingTimeInterval(probeTimeoutSeconds)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                // Give SIGTERM a moment, then escalate.
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return process.terminationStatus == 0
    }
}
