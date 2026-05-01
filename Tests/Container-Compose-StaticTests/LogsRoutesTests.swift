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

@Suite("Container REST routes - GET /containers/{id}/logs")
struct LogsRoutesTests {
    @Test("GET /containers/{id}/logs streams RuntimeLogFrame values as NDJSON APILogFrame objects")
    func streamsLogsAsNDJSON() async throws {
        let now = Date(timeIntervalSince1970: 1_770_000_100)
        let runtime = RecordingRuntime(stubbedLogFrames: [
            RuntimeLogFrame(timestamp: now, source: .stdout, data: Data("hello".utf8)),
            RuntimeLogFrame(timestamp: now.addingTimeInterval(1), source: .stderr, data: Data("boom".utf8))
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                try await client.execute(uri: "/containers/web/logs", method: .get) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType] == "application/x-ndjson")
                    let frames = try Self.decodeNDJSON(APILogFrame.self, from: response)
                    #expect(frames == [
                        APILogFrame(stream: "stdout", timestamp: now, line: "hello"),
                        APILogFrame(stream: "stderr", timestamp: now.addingTimeInterval(1), line: "boom")
                    ])
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [
            .logs(id: "web", options: RuntimeLogOptions(follow: false, tail: nil, since: nil, timestamps: true))
        ])
    }

    @Test("GET /containers/{id}/logs returns 404 for an unknown container")
    func unknownContainerReturns404() async throws {
        let runtime = RecordingRuntime(logsError: .notFound(id: "missing"))

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                try await client.execute(uri: "/containers/missing/logs", method: .get) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message == "No such container: missing")
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [
            .logs(id: "missing", options: RuntimeLogOptions(follow: false, tail: nil, since: nil, timestamps: true))
        ])
    }

    @Test("GET /containers/{id}/logs parses follow, tail, since, and timestamps query parameters")
    func parsesQueryParameters() async throws {
        let since = try #require(ISO8601DateFormatter().date(from: "2026-05-01T12:34:56Z"))
        let runtime = RecordingRuntime(stubbedLogFrames: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await Self.app().test(.router) { client in
                try await client.execute(
                    uri: "/containers/web/logs?follow=true&tail=25&since=2026-05-01T12:34:56Z&timestamps=false",
                    method: .get
                ) { response in
                    #expect(response.status == .ok)
                    #expect(String(buffer: response.body).isEmpty)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [
            .logs(id: "web", options: RuntimeLogOptions(follow: true, tail: 25, since: since, timestamps: false))
        ])
    }

    private static func app() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        LogsRoutes.register(router: router)
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
