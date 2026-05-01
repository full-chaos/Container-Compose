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

@Suite("Container REST routes - GET /events")
struct EventsRoutesTests {
    @Test("GET /events streams RuntimeContainerEvent values as NDJSON APIEventFrame objects")
    func streamsEventsAsNDJSON() async throws {
        let startedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let stoppedAt = Date(timeIntervalSince1970: 1_770_000_010)
        let runtime = RecordingRuntime(stubbedEvents: [
            .started(id: "web", at: startedAt),
            .stopped(id: "web", exitCode: 7, at: stoppedAt)
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                try await client.execute(uri: "/events", method: .get) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType] == "application/x-ndjson")
                    let frames = try Self.decodeNDJSON(APIEventFrame.self, from: response)
                    #expect(frames == [
                        APIEventFrame(type: "started", id: "web", timestamp: startedAt, exitCode: nil, signal: nil),
                        APIEventFrame(type: "stopped", id: "web", timestamp: stoppedAt, exitCode: 7, signal: nil)
                    ])
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.events])
    }

    @Test("GET /events returns 501 when the active runtime does not support events")
    func eventsNotSupportedReturns501() async throws {
        let runtime = RecordingRuntime(eventsError: .notSupported(operation: "events", conformer: "test"))

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                try await client.execute(uri: "/events", method: .get) { response in
                    #expect(response.status == .notImplemented)
                    let body = try Self.decode(APIStatsErrorResponse.self, from: response)
                    #expect(body.error == "Not Implemented")
                    #expect(body.message == "Events backend is not supported by the active runtime")
                    #expect(body.deferralPhase == "Phase 2.B")
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.events])
    }

    private static func app() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        EventsRoutes.register(router: router)
        return Application(router: router)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
        let data = Data(String(buffer: response.body).utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func decodeNDJSON<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> [T] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(buffer: response.body)
            .split(separator: "\n")
            .map { line in
                try decoder.decode(type, from: Data(line.utf8))
            }
    }
}
