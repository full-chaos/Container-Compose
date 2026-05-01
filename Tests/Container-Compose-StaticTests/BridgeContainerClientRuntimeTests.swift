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
import ContainerAPIClient
import ContainerResource
@testable import ContainerComposeCore
import TestHelpers

@Suite("BridgeContainerClientRuntime delegates to ContainerClientProvider")
struct BridgeContainerClientRuntimeTests {

    @Test("list() routes through the bound provider")
    func listRoutesThroughProvider() async throws {
        let recorder = RecordingContainerClientProvider()
        let bridge = BridgeContainerClientRuntime()
        try await ContainerClientEnvironment.$current.withValue(recorder) {
            let containers = try await bridge.list(filters: .all)
            #expect(containers.isEmpty)
        }
        let entries = await recorder.entriesSnapshot()
        #expect(entries.contains(.list(filters: String(describing: ContainerListFilters.all))))
    }

    @Test("get() throws notFound when provider has no container")
    func getThrowsNotFound() async throws {
        let recorder = RecordingContainerClientProvider()
        let bridge = BridgeContainerClientRuntime()
        await ContainerClientEnvironment.$current.withValue(recorder) {
            await #expect(throws: RuntimeError.self) {
                _ = try await bridge.get(id: "ghost")
            }
        }
    }

    @Test("create() throws notSupported (Phase 1 contract)")
    func createIsUnsupported() async throws {
        let bridge = BridgeContainerClientRuntime()
        await #expect(throws: RuntimeError.self) {
            _ = try await bridge.create(
                id: "x",
                configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
            )
        }
    }

    @Test("start/kill/wait/logs/events/statistics throw notSupported")
    func writeAndStreamPathsAreUnsupported() async {
        let bridge = BridgeContainerClientRuntime()
        await #expect(throws: RuntimeError.self) { try await bridge.start(id: "x") }
        await #expect(throws: RuntimeError.self) { try await bridge.kill(id: "x", signal: 9) }
        await #expect(throws: RuntimeError.self) { _ = try await bridge.wait(id: "x", timeoutSeconds: 1) }
        await #expect(throws: RuntimeError.self) { _ = try await bridge.logs(id: "x", options: .default) }
        await #expect(throws: RuntimeError.self) { _ = try await bridge.events() }
        await #expect(throws: RuntimeError.self) { _ = try await bridge.statistics(for: "x") }
    }
}
