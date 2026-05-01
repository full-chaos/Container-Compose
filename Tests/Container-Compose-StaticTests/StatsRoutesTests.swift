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
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite("Container REST routes - GET /containers/{id}/stats")
struct StatsRoutesTests {

    // MARK: - One-shot mode (?stream=false)

    @Test("GET /containers/{id}/stats?stream=false returns a single APIStatsFrame as JSON")
    func oneShot_returnsSingleFrame() async throws {
        let sampledAt = Date(timeIntervalSince1970: 1_770_000_100)
        let runtime = RecordingRuntime(stubbedStatistics: RuntimeStatistics(
            id: "web",
            cpuUsageUsec: 123_456,
            memoryUsageBytes: 52_428_800,
            memoryLimitBytes: 268_435_456,
            oomKillCount: 0,
            networks: [RuntimeStatistics.Network(interface: "eth0", receivedBytes: 1024, transmittedBytes: 2048)],
            sampledAt: sampledAt
        ))

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                try await client.execute(uri: "/containers/web/stats?stream=false", method: .get) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType] == "application/json")
                    let frame = try Self.decodeJSON(APIStatsFrame.self, from: response)
                    #expect(frame.id == "web")
                    #expect(frame.cpuUsageMicroseconds == 123_456)
                    #expect(frame.memoryUsageBytes == 52_428_800)
                    #expect(frame.memoryLimitBytes == 268_435_456)
                    #expect(frame.oomKillCount == 0)
                    #expect(frame.networks.count == 1)
                    #expect(frame.networks.first?.interface == "eth0")
                    #expect(frame.networks.first?.receivedBytes == 1024)
                    #expect(frame.networks.first?.transmittedBytes == 2048)
                    #expect(frame.sampledAt == sampledAt)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.statistics(id: "web")])
    }

    @Test("GET /containers/{id}/stats?stream=false returns 404 for unknown container")
    func oneShot_unknownContainerReturns404() async throws {
        let runtime = RecordingRuntime(statisticsError: .notFound(id: "missing"))

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                try await client.execute(uri: "/containers/missing/stats?stream=false", method: .get) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decodeJSON(APIErrorResponse.self, from: response)
                    #expect(body.message == "No such container: missing")
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.statistics(id: "missing")])
    }

    @Test("GET /containers/{id}/stats?stream=false returns 501 when runtime does not support statistics")
    func oneShot_notSupportedReturns501() async throws {
        let runtime = RecordingRuntime(statisticsError: .notSupported(operation: "statistics", conformer: "test"))

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                try await client.execute(uri: "/containers/web/stats?stream=false", method: .get) { response in
                    #expect(response.status == .notImplemented)
                    let body = try Self.decodeJSON(APIStatsErrorResponse.self, from: response)
                    #expect(body.error == "Not Implemented")
                }
            }
        }
    }

    // MARK: - Streaming mode (default)

    /// Streaming with a single-snapshot sequence: the route emits the first frame immediately
    /// (no interval sleep), then on the next poll the runtime throws notFound (sequence
    /// exhausted), ending the stream. Use interval=0.5s to keep wall-clock time short.
    @Test("GET /containers/{id}/stats streams NDJSON frames until container gone")
    func streaming_emitsFramesUntilContainerGone() async throws {
        let t1 = Date(timeIntervalSince1970: 1_770_000_100)
        let snapshots: [RuntimeStatistics] = [
            RuntimeStatistics(id: "web", cpuUsageUsec: 100, memoryUsageBytes: 1024, sampledAt: t1)
        ]
        let runtime = RecordingRuntime(stubbedStatisticsSequence: snapshots)

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                // Use minimum interval (0.5s) to keep the test fast
                try await client.execute(uri: "/containers/web/stats?interval=0.5s", method: .get) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType] == "application/x-ndjson")
                    let frames = try Self.decodeNDJSON(APIStatsFrame.self, from: response)
                    // At least the first frame is present; notFound terminates the loop
                    #expect(frames.isEmpty == false)
                    #expect(frames[0].cpuUsageMicroseconds == 100)
                    #expect(frames[0].memoryUsageBytes == 1024)
                }
            }
        }
    }

    @Test("GET /containers/{id}/stats returns 404 when container not found during streaming")
    func streaming_unknownContainerReturns404() async throws {
        let runtime = RecordingRuntime(statisticsError: .notFound(id: "ghost"))

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                try await client.execute(uri: "/containers/ghost/stats", method: .get) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decodeJSON(APIErrorResponse.self, from: response)
                    #expect(body.message == "No such container: ghost")
                }
            }
        }
    }

    @Test("GET /containers/{id}/stats returns 501 when runtime does not support statistics")
    func streaming_notSupportedReturns501() async throws {
        let runtime = RecordingRuntime(statisticsError: .notSupported(operation: "statistics", conformer: "test"))

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                try await client.execute(uri: "/containers/web/stats", method: .get) { response in
                    #expect(response.status == .notImplemented)
                    let body = try Self.decodeJSON(APIStatsErrorResponse.self, from: response)
                    #expect(body.error == "Not Implemented")
                }
            }
        }
    }

    // MARK: - Interval query parameter parsing (unit tests via parseIntervalValue)

    @Test("parseIntervalValue returns default 1s when no interval param")
    func interval_defaultValue() {
        #expect(StatsRoutes.parseIntervalValue(nil) == 1.0)
    }

    @Test("parseIntervalValue accepts '2s' and returns 2.0")
    func interval_validValueParsed() {
        #expect(StatsRoutes.parseIntervalValue("2s") == 2.0)
    }

    @Test("parseIntervalValue clamps '0.1s' below minimum to 0.5s")
    func interval_belowMinimumIsClamped() {
        #expect(StatsRoutes.parseIntervalValue("0.1s") == StatsRoutes.minimumInterval)
    }

    @Test("parseIntervalValue clamps '120s' above maximum to 60s")
    func interval_aboveMaximumIsClamped() {
        #expect(StatsRoutes.parseIntervalValue("120s") == StatsRoutes.maximumInterval)
    }

    @Test("parseIntervalValue accepts value without 's' suffix (e.g. '5')")
    func interval_noSuffixParsed() {
        #expect(StatsRoutes.parseIntervalValue("5") == 5.0)
    }

    // MARK: - toFrame helper

    @Test("StatsRoutes.toFrame converts RuntimeStatistics to APIStatsFrame correctly")
    func toFrame_convertsShape() {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let stats = RuntimeStatistics(
            id: "db",
            cpuUsageUsec: 999,
            memoryUsageBytes: 8192,
            memoryLimitBytes: 1_073_741_824,
            oomKillCount: 3,
            networks: [
                RuntimeStatistics.Network(interface: "lo0", receivedBytes: 100, transmittedBytes: 200)
            ],
            sampledAt: sampledAt
        )
        let frame = StatsRoutes.toFrame(stats)
        #expect(frame.id == "db")
        #expect(frame.cpuUsageMicroseconds == 999)
        #expect(frame.memoryUsageBytes == 8192)
        #expect(frame.memoryLimitBytes == 1_073_741_824)
        #expect(frame.oomKillCount == 3)
        #expect(frame.networks.count == 1)
        #expect(frame.networks.first?.interface == "lo0")
        #expect(frame.networks.first?.receivedBytes == 100)
        #expect(frame.networks.first?.transmittedBytes == 200)
        #expect(frame.sampledAt == sampledAt)
    }

    // MARK: - Helpers

    private static func app() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        StatsRoutes.register(router: router)
        return Application(router: router)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
        let data = Data(String(buffer: response.body).utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func decodeNDJSON<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> [T] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(buffer: response.body)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try decoder.decode(type, from: Data(line.utf8))
            }
    }
}
