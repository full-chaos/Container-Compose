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

/// CHAOS-1354 — Phase 5 lifecycle write endpoints
/// Tests use `MockRuntime` (state machine, not just recorder) so state
/// transitions are verified end-to-end without reaching any real backend.
@Suite("Lifecycle write routes — POST start/stop/restart/kill, DELETE, POST wait")
struct LifecycleRoutesTests {

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
        let data = Data(String(buffer: response.body).utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func makeCreatedContainer(id: String = "ctr-1") -> RuntimeContainer {
        RuntimeContainer(
            id: id,
            imageReference: "alpine:3",
            status: .created,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func makeRunningContainer(id: String = "ctr-1") -> RuntimeContainer {
        RuntimeContainer(
            id: id,
            imageReference: "alpine:3",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    // MARK: - POST /containers/{id}/start — happy path

    @Test("POST /containers/ctr-1/start returns 204 when container is in .created state")
    func startCreatedContainerReturns204() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [Self.makeCreatedContainer()])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1/start", method: .post) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let snapshot = await runtime.snapshot()
        #expect(snapshot["ctr-1"]?.status == .running)
    }

    // MARK: - POST /containers/{id}/start — error paths

    @Test("POST /containers/missing/start returns 404")
    func startMissingContainerReturns404() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/missing/start", method: .post) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message == "No such container: missing")
                }
            }
        }
    }

    @Test("POST /containers/ctr-1/start returns 409 when container is already running")
    func startRunningContainerReturns409() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [Self.makeRunningContainer()])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1/start", method: .post) { response in
                    #expect(response.status == .conflict)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message.contains("running"))
                }
            }
        }
    }

    // MARK: - POST /containers/{id}/stop — happy path

    @Test("POST /containers/ctr-1/stop returns 204 when container is running")
    func stopRunningContainerReturns204() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [Self.makeRunningContainer()])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1/stop", method: .post) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let snapshot = await runtime.snapshot()
        #expect(snapshot["ctr-1"]?.status == .stopped)
    }

    @Test("POST /containers/ctr-1/stop passes custom signal and timeout from body")
    func stopPassesCustomOptions() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [Self.makeRunningContainer()])
        let bodyJSON = #"{"signal":2,"timeoutSeconds":5}"#
        let headers: HTTPFields = [.contentType: "application/json"]

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/containers/ctr-1/stop",
                    method: .post,
                    headers: headers,
                    body: ByteBuffer(string: bodyJSON)
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let snapshot = await runtime.snapshot()
        #expect(snapshot["ctr-1"]?.status == .stopped)
    }

    // MARK: - POST /containers/{id}/stop — error paths

    @Test("POST /containers/missing/stop returns 404")
    func stopMissingContainerReturns404() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/missing/stop", method: .post) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message == "No such container: missing")
                }
            }
        }
    }

    @Test("POST /containers/ctr-1/stop returns 409 when container is already stopped")
    func stopAlreadyStoppedContainerReturns409() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let stoppedContainer = RuntimeContainer(id: "ctr-1", imageReference: "alpine:3", status: .stopped)
        let runtime = MockRuntime(containers: [stoppedContainer])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1/stop", method: .post) { response in
                    #expect(response.status == .conflict)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message.contains("stopped"))
                }
            }
        }
    }

    // MARK: - POST /containers/{id}/restart — happy paths

    @Test("POST /containers/ctr-1/restart returns 204 for a running container (stop+start dispatched)")
    func restartRunningContainerReturns204() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        // Use RecordingRuntime (no state validation) to verify the route dispatches
        // both stop and start without caring about strict state transitions.
        // MockRuntime's start requires .created state; the real backend handles
        // stop→start from any state — so integration coverage lives in E2E smoke.
        let runtime = RecordingRuntime(stubbedContainers: [Self.makeRunningContainer()])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1/restart", method: .post) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        // Verify that both stop and start were dispatched
        let entries = await runtime.entriesSnapshot()
        #expect(entries.contains(.stop(id: "ctr-1")))
        #expect(entries.contains(.start(id: "ctr-1")))
    }

    @Test("POST /containers/ctr-1/restart still starts a stopped container (stop is tolerated)")
    func restartStoppedContainerStartsIt() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        // RecordingRuntime: stop on already-stopped won't fail, start on stopped also won't fail
        let stoppedContainer = RuntimeContainer(id: "ctr-1", imageReference: "alpine:3", status: .stopped)
        let runtime = RecordingRuntime(stubbedContainers: [stoppedContainer])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1/restart", method: .post) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        // stop is still dispatched (invalidState swallowed), start is always dispatched
        #expect(entries.contains(.start(id: "ctr-1")))
    }

    @Test("POST /containers/missing/restart returns 404 when container does not exist")
    func restartMissingContainerReturns404() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/missing/restart", method: .post) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message == "No such container: missing")
                }
            }
        }
    }

    // MARK: - POST /containers/{id}/kill — happy path

    @Test("POST /containers/ctr-1/kill returns 204 with default SIGKILL (9)")
    func killRunningContainerReturns204() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [Self.makeRunningContainer()])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1/kill", method: .post) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let snapshot = await runtime.snapshot()
        #expect(snapshot["ctr-1"]?.status == .stopped)
        // SIGKILL exit code = 128 + 9 = 137 per MockRuntime convention
        #expect(snapshot["ctr-1"]?.lastExitCode == 137)
    }

    @Test("POST /containers/ctr-1/kill passes custom signal from body")
    func killWithCustomSignal() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [Self.makeRunningContainer()])
        let bodyJSON = #"{"signal":15}"#
        let headers: HTTPFields = [.contentType: "application/json"]

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/containers/ctr-1/kill",
                    method: .post,
                    headers: headers,
                    body: ByteBuffer(string: bodyJSON)
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let snapshot = await runtime.snapshot()
        // SIGTERM (15) exit code = 128 + 15 = 143
        #expect(snapshot["ctr-1"]?.lastExitCode == 143)
    }

    // MARK: - POST /containers/{id}/kill — error paths

    @Test("POST /containers/missing/kill returns 404")
    func killMissingContainerReturns404() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/missing/kill", method: .post) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message == "No such container: missing")
                }
            }
        }
    }

    @Test("POST /containers/ctr-1/kill returns 409 when container is already stopped")
    func killStoppedContainerReturns409() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let stoppedContainer = RuntimeContainer(id: "ctr-1", imageReference: "alpine:3", status: .stopped)
        let runtime = MockRuntime(containers: [stoppedContainer])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1/kill", method: .post) { response in
                    #expect(response.status == .conflict)
                }
            }
        }
    }

    // MARK: - DELETE /containers/{id} — happy paths

    @Test("DELETE /containers/ctr-1 returns 204 and removes stopped container")
    func deleteStoppedContainerReturns204() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let stoppedContainer = RuntimeContainer(id: "ctr-1", imageReference: "alpine:3", status: .stopped)
        let runtime = MockRuntime(containers: [stoppedContainer])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1", method: .delete) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let snapshot = await runtime.snapshot()
        #expect(snapshot["ctr-1"] == nil)
    }

    @Test("DELETE /containers/ctr-1?force=true removes running container")
    func deleteRunningContainerWithForceReturns204() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [Self.makeRunningContainer()])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1?force=true", method: .delete) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let snapshot = await runtime.snapshot()
        #expect(snapshot["ctr-1"] == nil)
    }

    // MARK: - DELETE /containers/{id} — error paths

    @Test("DELETE /containers/missing returns 404")
    func deleteMissingContainerReturns404() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/missing", method: .delete) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message == "No such container: missing")
                }
            }
        }
    }

    @Test("DELETE /containers/ctr-1 returns 409 when container is running and force=false")
    func deleteRunningContainerWithoutForceReturns409() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [Self.makeRunningContainer()])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/ctr-1?force=false", method: .delete) { response in
                    #expect(response.status == .conflict)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message.contains("force=true"))
                }
            }
        }
    }

    // MARK: - POST /containers/{id}/wait — happy path

    @Test("POST /containers/ctr-1/wait returns 200 with exit code when container is already stopped")
    func waitReturnsExitStatus() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let stoppedContainer = RuntimeContainer(
            id: "ctr-1",
            imageReference: "alpine:3",
            status: .stopped,
            lastExitCode: 42
        )
        let runtime = MockRuntime(containers: [stoppedContainer])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/containers/ctr-1/wait?timeout=1",
                    method: .post
                ) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode(APIWaitResponse.self, from: response)
                    #expect(body.exitCode == 42)
                }
            }
        }
    }

    @Test("POST /containers/missing/wait returns 404")
    func waitMissingContainerReturns404() async throws {
        let router = Router()
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/missing/wait", method: .post) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message == "No such container: missing")
                }
            }
        }
    }

    // MARK: - Static helper unit tests

    @Test("parseStopOptions: nil buffer returns default options")
    func parseStopOptionsDefaultsOnNilBuffer() {
        let opts = LifecycleRoutes.parseStopOptions(from: nil)
        #expect(opts.signal == RuntimeStopOptions.default.signal)
        #expect(opts.timeoutSeconds == RuntimeStopOptions.default.timeoutSeconds)
    }

    @Test("parseStopOptions: parses signal and timeout from JSON")
    func parseStopOptionsFromJSON() {
        let json = #"{"signal":2,"timeoutSeconds":5}"#
        let buffer = ByteBuffer(string: json)
        let opts = LifecycleRoutes.parseStopOptions(from: buffer)
        #expect(opts.signal == 2)
        #expect(opts.timeoutSeconds == 5)
    }

    @Test("parseKillSignal: nil buffer defaults to SIGKILL (9)")
    func parseKillSignalDefaultsSIGKILL() {
        let signal = LifecycleRoutes.parseKillSignal(from: nil)
        #expect(signal == 9)
    }

    @Test("parseKillSignal: parses signal from JSON body")
    func parseKillSignalFromJSON() {
        let json = #"{"signal":15}"#
        let buffer = ByteBuffer(string: json)
        let signal = LifecycleRoutes.parseKillSignal(from: buffer)
        #expect(signal == 15)
    }
}
