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
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite("compose ps reads through Runtime.list (CHAOS-1346 Phase 1 wiring)")
struct ComposePsRuntimeWiringTests {

    @Test("ComposePs invokes RuntimeEnvironment.current.list exactly once")
    func psInvokesRuntimeList() async throws {
        let recorder = RecordingRuntime(stubbedContainers: [
            RuntimeContainer(
                id: "wiringproject-web-1",
                imageReference: "nginx:1",
                status: .running
            )
        ])
        try await RuntimeEnvironment.$current.withValue(recorder) {
            let yaml = """
            name: wiringproject
            services:
              web:
                image: nginx:1
            """
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "ps-runtime-wiring-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let composePath = dir.appending(path: "compose.yml")
            try yaml.write(to: composePath, atomically: true, encoding: .utf8)

            var cmd = try ComposePs.parse([
                "--file", composePath.path,
                "--quiet"
            ])
            try await cmd.run()
        }
        let entries = await recorder.entriesSnapshot()
        #expect(entries == [.list])
    }
}
