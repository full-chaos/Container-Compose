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
import TestHelpers

/// Tiny seam wiring sanity-check. The real argv-shape regression suite lands
/// in PR-2 (`RuntimeArgvTests.swift`).
@Suite("RunCommandRunner seam smoke")
struct RunCommandRunnerSmokeTests {

    @Test("Recorder starts empty and records a probe call without spawning")
    func recorderRecordsProbeWithoutSpawning() async throws {
        let recorder = RecordingRunner()
        #expect(await recorder.recordedRequests().isEmpty)

        let probe = RunRequest(
            kind: .probe,
            argv: ["container", "--version"],
            cwd: nil
        )
        let result = try await recorder.run(probe, onStdout: nil, onStderr: nil)

        // Default probe stub is `true`, so probeAvailable should be true.
        #expect(result.probeAvailable == true)
        #expect(result.exitCode == 0)

        let recorded = await recorder.recordedRequests()
        #expect(recorded.count == 1)
        #expect(recorded[0].request == probe)
        #expect(recorded[0].sequence == 0)
    }
}
