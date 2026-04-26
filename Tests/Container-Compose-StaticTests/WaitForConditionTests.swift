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

import Testing
import Foundation
@testable import ContainerComposeCore

// MARK: - RuntimeAvailability

/// Lightweight helper that probes whether the Apple `container` runtime is
/// available on the current machine.  It checks for the presence of the
/// `container` executable in well-known paths; no actual daemon connection is
/// attempted so the check is safe to call from static test suites.
enum RuntimeAvailability {
    static func isAvailable() -> Bool {
        let candidates = [
            "/usr/local/bin/container",
            "/opt/homebrew/bin/container",
            "/usr/bin/container",
        ]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - WaitForConditionTests

/// Verifies the `waitForCondition` helper that lives in `Compose+Wait.swift`.
///
/// These tests are *static* (no running daemon required for the compile-time
/// checks) except for the one test that actually invokes the helper — that test
/// is gated on `RuntimeAvailability.isAvailable()` so it is automatically
/// skipped on CI machines that don't have the Apple container runtime installed.
@Suite("WaitForCondition Helper Tests")
struct WaitForConditionTests {

    // MARK: Compile-time signature verification

    /// Verifies that `ComposeUp` exposes the expected `waitForCondition` method
    /// with the correct parameter types and default values.  The test itself is
    /// a no-op at runtime — it exists purely to confirm that the code compiles
    /// with the expected API surface.
    @Test("waitForCondition has the expected API signature (compile-time check)")
    func waitForConditionSignatureCompiles() {
        // Use a closure to reference the method without calling it; this is
        // enough for the compiler to verify the signature at build time.
        let _: (ComposeUp) -> (String, DependsOnCondition, TimeInterval, TimeInterval) async throws -> Void
            = { composeUp in composeUp.waitForCondition(_:condition:timeout:interval:) }

        // If this file compiles, the signature test passes.
    }

    /// Verifies that `DependsOnCondition` has the three expected cases.
    @Test("DependsOnCondition has the correct cases")
    func dependsOnConditionCases() {
        let all = DependsOnCondition.allCases
        #expect(all.contains(.serviceStarted))
        #expect(all.contains(.serviceHealthy))
        #expect(all.contains(.serviceCompletedSuccessfully))
        #expect(all.count == 3)
    }

    /// Verifies that `DependsOnCondition` raw values match the Docker Compose spec.
    @Test("DependsOnCondition raw values match Docker Compose spec")
    func dependsOnConditionRawValues() {
        #expect(DependsOnCondition.serviceStarted.rawValue == "service_started")
        #expect(DependsOnCondition.serviceHealthy.rawValue == "service_healthy")
        #expect(DependsOnCondition.serviceCompletedSuccessfully.rawValue == "service_completed_successfully")
    }

    /// Verifies that `ComposeWaitError.timeout` has a non-empty localized description.
    @Test("ComposeWaitError.timeout has a localized description")
    func composeWaitErrorDescription() {
        let error = ComposeWaitError.timeout(
            containerName: "test-project-db",
            condition: .serviceStarted,
            seconds: 60
        )
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.errorDescription?.contains("test-project-db") == true)
    }

    // MARK: Runtime-gated test

    /// Verifies that `waitForCondition` throws when the named container does not
    /// exist.  This test is skipped automatically on machines where the Apple
    /// container runtime is not installed.
    ///
    /// Note: `ComposeUp` is an `AsyncParsableCommand` that requires a working
    /// directory and compose file to `run()`, but `waitForCondition` only needs
    /// `projectName` to be set — which we can do directly since `projectName`
    /// has internal access.  We therefore instantiate `ComposeUp()` and set
    /// `projectName` without invoking the full startup path.
    @Test(
        "waitForCondition throws on nonexistent container (runtime-gated)",
        .enabled(if: RuntimeAvailability.isAvailable(), "Apple container runtime not available")
    )
    func waitForConditionThrowsOnNonexistentContainer() async throws {
        var composeUp = ComposeUp()
        composeUp.projectName = "cc-test-nonexistent-\(UUID().uuidString.prefix(8))"

        // With a 1-second timeout and a container name that cannot exist,
        // waitForCondition must throw before the deadline expires.
        await #expect(throws: (any Error).self) {
            try await composeUp.waitForCondition(
                "no-such-service",
                condition: .serviceStarted,
                timeout: 1.0,
                interval: 0.2
            )
        }
    }
}
