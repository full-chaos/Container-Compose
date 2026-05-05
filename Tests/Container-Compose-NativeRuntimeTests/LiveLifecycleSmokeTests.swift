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

#if os(macOS)

import Foundation
import Testing
@testable import ContainerComposeCore

/// Live-VM smoke test placeholder for the full
/// `create → start → statistics → stop → remove` cycle on macOS 26 with the
/// virtualization entitlement. Gated by the `CONTAINER_COMPOSE_RUN_NATIVE_TESTS`
/// env var so CI and inner-loop runs skip it by default. The body lands when
/// PR3 wires `ContainerManager.create(...)` and PR2 ships the `.entitlements`
/// file + codesign flow — see `docs/plans/phase2-sdk-signatures.md` and
/// `docs/plans/runtime-abstraction-leaks.md` Leak #7.
///
/// Why a placeholder now? PR4 owns the test target structure and the
/// statistics translation closure. Landing the placeholder alongside this PR
/// gives PR3 a concrete location to drop the live-VM body without relitigating
/// target setup or naming.
@Suite("Live VM lifecycle smoke (opt-in)")
struct LiveLifecycleSmokeTests {

    private static var optedIn: Bool {
        ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_RUN_NATIVE_TESTS"] == "1"
    }

    @Test(
        "live VM smoke — create → start → statistics → stop → remove",
        .enabled(if: LiveLifecycleSmokeTests.optedIn)
    )
    func liveLifecycleSmoke() async throws {
        // Body lands with PR3 / Phase 2 lifecycle wiring.
        // Required preconditions:
        //   - macOS 26 host
        //   - signed binary with com.apple.developer.virtualization entitlement (PR2)
        //   - vmlinux kernel acquired (PR3)
        // Until then the `.enabled(if:)` predicate skips this test even when
        // the suite is selected.
        Issue.record("Live VM smoke not yet wired — PR3 / PR2 prerequisites pending.")
    }
}

#endif
