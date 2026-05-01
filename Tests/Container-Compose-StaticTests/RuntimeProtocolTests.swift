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

@Suite("Runtime protocol surface")
struct RuntimeProtocolTests {

    @Test("RuntimeEnvironment defaults to BridgeContainerClientRuntime")
    func defaultEnvironmentBindsBridge() async {
        let runtime = RuntimeEnvironment.current
        #expect(runtime is BridgeContainerClientRuntime)
    }

    @Test("RecordingRuntime captures list calls")
    func recordingRuntimeCapturesList() async throws {
        let recorder = RecordingRuntime(stubbedContainers: [
            RuntimeContainer(id: "demo-web-1", imageReference: "nginx:1", status: .running)
        ])
        let containers = try await recorder.list(filters: .all)
        #expect(containers.count == 1)
        #expect(containers[0].id == "demo-web-1")
        let entries = await recorder.entriesSnapshot()
        #expect(entries == [.list])
    }

    @Test("RecordingRuntime captures get calls and routes by id")
    func recordingRuntimeCapturesGet() async throws {
        let recorder = RecordingRuntime(stubbedContainers: [
            RuntimeContainer(id: "demo-db-1", imageReference: "postgres:16", status: .running)
        ])
        let hit = try await recorder.get(id: "demo-db-1")
        #expect(hit.imageReference == "postgres:16")
        await #expect(throws: RuntimeError.self) {
            _ = try await recorder.get(id: "missing")
        }
        let entries = await recorder.entriesSnapshot()
        #expect(entries == [.get(id: "demo-db-1"), .get(id: "missing")])
    }

    @Test("MockRuntime satisfies list and get through stateful registry")
    func mockRuntimeListsAndGetsState() async throws {
        let runtime = MockRuntime(containers: [
            RuntimeContainer(id: "demo-web-1", imageReference: "nginx:1", status: .running),
            RuntimeContainer(id: "demo-db-1", imageReference: "postgres:16", status: .stopped)
        ])

        let running = try await runtime.list(filters: RuntimeListFilters(status: [.running]))
        #expect(running.map(\.id) == ["demo-web-1"])

        let db = try await runtime.get(id: "demo-db-1")
        #expect(db.imageReference == "postgres:16")
        await #expect(throws: RuntimeError.self) {
            _ = try await runtime.get(id: "missing")
        }
    }

    @Test("RuntimeError carries actionable diagnostics")
    func runtimeErrorMessages() {
        let notFound = RuntimeError.notFound(id: "x").errorDescription
        #expect(notFound?.contains("'x'") == true)

        let invalid = RuntimeError.invalidState(
            id: "x",
            expected: .running,
            actual: .stopped
        ).errorDescription
        #expect(invalid?.contains("running") == true)
        #expect(invalid?.contains("stopped") == true)

        let notSupported = RuntimeError.notSupported(
            operation: "create",
            conformer: "BridgeContainerClientRuntime"
        ).errorDescription
        #expect(notSupported?.contains("create") == true)
        #expect(notSupported?.contains("Bridge") == true)
    }

    @Test("RuntimeContainer is Codable round-trip")
    func runtimeContainerCodable() throws {
        let port = RuntimePublishedPort(
            hostAddress: "127.0.0.1",
            hostPort: 8080,
            containerPort: 80,
            proto: .tcp
        )
        let container = RuntimeContainer(
            id: "demo-web-1",
            imageReference: "nginx:1",
            status: .running,
            publishedPorts: [port],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_010),
            lastExitCode: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(container)
        let round = try decoder.decode(RuntimeContainer.self, from: data)
        #expect(round == container)
    }

    @Test("RuntimeContainerStatus exposes every upstream case + skeleton states")
    func runtimeContainerStatusCoverage() {
        let raws = Set(RuntimeContainerStatus.allCases.map { $0.rawValue })
        #expect(raws.contains("unknown"))
        #expect(raws.contains("created"))
        #expect(raws.contains("running"))
        #expect(raws.contains("stopping"))
        #expect(raws.contains("stopped"))
        #expect(raws.contains("exited"))
    }
}
