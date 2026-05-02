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
import ContainerizationError
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

    @Test("start/kill/wait/statistics throw notSupported")
    func writeAndStreamPathsAreUnsupported() async {
        let bridge = BridgeContainerClientRuntime()
        await #expect(throws: RuntimeError.self) { try await bridge.start(id: "x") }
        await #expect(throws: RuntimeError.self) { try await bridge.kill(id: "x", signal: 9) }
        await #expect(throws: RuntimeError.self) { _ = try await bridge.wait(id: "x", timeoutSeconds: 1) }
    }

    @Test("statistics() maps upstream notFound semantics to RuntimeError.notFound")
    func statisticsMapsNotFound() async throws {
        let upstream = ContainerizationError(.internalError, message: "failed to get statistics", cause: ContainerizationError(.notFound, message: "container ghost not found"))
        let provider = BridgeStatisticsProvider(statsError: upstream)
        let bridge = BridgeContainerClientRuntime()

        await ContainerClientEnvironment.$current.withValue(provider) {
            await #expect(throws: RuntimeError.notFound(id: "ghost")) {
                _ = try await bridge.statistics(for: "ghost")
            }
        }
    }

    @Test("statistics() maps non-notFound upstream failures to RuntimeError.backendFailure")
    func statisticsMapsBackendFailure() async throws {
        let provider = BridgeStatisticsProvider(
            statsError: ContainerizationError(.timeout, message: "daemon request timed out")
        )
        let bridge = BridgeContainerClientRuntime()

        await ContainerClientEnvironment.$current.withValue(provider) {
            await #expect(throws: RuntimeError.backendFailure(message: "stats failed for 'web': daemon request timed out")) {
                _ = try await bridge.statistics(for: "web")
            }
        }
    }

    @Test("logs() routes through provider and emits RuntimeLogFrame lines")
    func logsRouteThroughProvider() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bridge-logs-\(UUID().uuidString).log")
        try Data("one\ntwo\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forReadingFrom: url)
        let recorder = RecordingContainerClientProvider(logHandles: [handle])
        let bridge = BridgeContainerClientRuntime()
        let frames = try await ContainerClientEnvironment.$current.withValue(recorder) {
            let stream = try await bridge.logs(id: "web", options: RuntimeLogOptions(follow: false, tail: 1, since: nil, timestamps: true))
            var result: [RuntimeLogFrame] = []
            for await frame in stream {
                result.append(frame)
            }
            return result
        }

        #expect(frames.map { String(decoding: $0.data, as: UTF8.self) } == ["two"])
        #expect(frames.map(\.source) == [.stdout])
        #expect(await recorder.entriesSnapshot() == [.logs(id: "web")])
    }

    @Test("events() routes through provider and translates ContainerEvent actions")
    func eventsRouteThroughProvider() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)
        let recorder = RecordingContainerClientProvider(containerEvents: [
            ContainerEvent(containerId: "web", action: .start, timestamp: timestamp)
        ])
        let bridge = BridgeContainerClientRuntime()
        let first = try await ContainerClientEnvironment.$current.withValue(recorder) {
            let stream = try await bridge.events()
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        #expect(first == .started(id: "web", at: timestamp))
        #expect(await recorder.entriesSnapshot() == [.events])
    }
}

private actor BridgeStatisticsProvider: ContainerClientProvider {
    let statsError: ContainerizationError

    init(statsError: ContainerizationError) {
        self.statsError = statsError
    }

    func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] { [] }
    func get(id: String) async throws -> ContainerSnapshot {
        throw ContainerizationError(.notFound, message: "container \(id) not found")
    }
    func stop(id: String, opts: ContainerStopOptions) async throws {}
    func delete(id: String, force: Bool) async throws {}
    func logs(id: String) async throws -> [FileHandle] { [] }
    func logs(id: String, options: ContainerLogOptions) async throws -> [FileHandle] { [] }
    func networkGet(id: String) async throws -> NetworkState {
        throw ContainerizationError(.notFound, message: "network \(id) not found")
    }
    func events() async throws -> [ContainerEvent] { [] }
    func imageList() async throws -> [ClientImage] { [] }
    func stats(id: String) async throws -> ContainerStats {
        throw statsError
    }
    func kill(id: String, signal: Int32) async throws {}
    func start(id: String) async throws {}
}
