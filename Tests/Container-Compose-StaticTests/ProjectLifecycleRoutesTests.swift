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

/// CHAOS-1360 — Phase 7 project lifecycle route tests.
///
/// All tests use `MockRuntime` (stateful actor) so state transitions are
/// verified end-to-end without a real backend. Tests cover the six required
/// routes plus error paths for project-not-found and invalid-body cases.
@Suite("Project lifecycle routes — up/down/restart/build/pull/scale")
struct ProjectLifecycleRoutesTests {

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
        let data = Data(String(buffer: response.body).utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    /// Make a router with only the project lifecycle routes registered.
    private static func makeRouter() -> Router<BasicRequestContext> {
        let router = Router()
        ProjectLifecycleRoutes.register(router: router)
        return router
    }

    // MARK: - Container fixtures

    private static func makeRunningContainer(id: String) -> RuntimeContainer {
        RuntimeContainer(
            id: id,
            imageReference: "alpine:3",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private static func makeCreatedContainer(id: String) -> RuntimeContainer {
        RuntimeContainer(
            id: id,
            imageReference: "alpine:3",
            status: .created,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func makeStoppedContainer(id: String) -> RuntimeContainer {
        RuntimeContainer(
            id: id,
            imageReference: "alpine:3",
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastExitCode: 0
        )
    }

    // MARK: - POST /projects/{name}/up — happy paths

    @Test("POST /projects/myapp/up returns 200 with running container states")
    func upStartsCreatedContainersAndReturns200() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [
            Self.makeCreatedContainer(id: "myapp-web"),
            Self.makeCreatedContainer(id: "myapp-db"),
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/myapp/up", method: .post) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode(APIProjectUpResponse.self, from: response)
                    #expect(body.project == "myapp")
                    #expect(body.services.count == 2)
                    #expect(body.services.allSatisfy { $0.status == "running" })
                }
            }
        }

        // Verify containers are now running in the runtime
        let snapshot = await runtime.snapshot()
        #expect(snapshot["myapp-web"]?.status == .running)
        #expect(snapshot["myapp-db"]?.status == .running)
    }

    @Test("POST /projects/myapp/up with already-running containers returns 200 without error")
    func upAlreadyRunningContainersReturns200() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [
            Self.makeRunningContainer(id: "myapp-web"),
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/myapp/up", method: .post) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode(APIProjectUpResponse.self, from: response)
                    #expect(body.project == "myapp")
                    // Running containers are included in the states
                    #expect(body.services.count >= 1)
                }
            }
        }
    }

    @Test("POST /projects/missing/up returns 404 when project has no containers")
    func upMissingProjectReturns404() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/missing/up", method: .post) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message.contains("missing"))
                }
            }
        }
    }

    // MARK: - POST /projects/{name}/down — happy path

    @Test("POST /projects/myapp/down returns 200 with stopped and removed container IDs")
    func downStopsAndRemovesContainers() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [
            Self.makeRunningContainer(id: "myapp-web"),
            Self.makeRunningContainer(id: "myapp-db"),
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/myapp/down", method: .post) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode(APIProjectDownResponse.self, from: response)
                    #expect(body.project == "myapp")
                    #expect(body.stopped.count == 2)
                    #expect(body.removed.count == 2)
                    #expect(body.stopped.contains("myapp-web"))
                    #expect(body.stopped.contains("myapp-db"))
                }
            }
        }

        // Containers should be gone from the runtime
        let snapshot = await runtime.snapshot()
        #expect(snapshot["myapp-web"] == nil)
        #expect(snapshot["myapp-db"] == nil)
    }

    @Test("POST /projects/missing/down returns 404")
    func downMissingProjectReturns404() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/missing/down", method: .post) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message.contains("missing"))
                }
            }
        }
    }

    // MARK: - POST /projects/{name}/restart — happy paths

    @Test("POST /projects/myapp/restart returns 200 with restarted container IDs")
    func restartProjectContainers() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        // Use RecordingRuntime so stop+start don't fail due to state validation
        let runtime = RecordingRuntime(stubbedContainers: [
            Self.makeRunningContainer(id: "myapp-web"),
            Self.makeRunningContainer(id: "myapp-db"),
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/myapp/restart", method: .post) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode(APIProjectRestartResponse.self, from: response)
                    #expect(body.project == "myapp")
                    #expect(body.restarted.count == 2)
                }
            }
        }

        // Verify both stop and start were dispatched
        let entries = await runtime.entriesSnapshot()
        #expect(entries.contains(.stop(id: "myapp-web")))
        #expect(entries.contains(.stop(id: "myapp-db")))
        #expect(entries.contains(.start(id: "myapp-web")))
        #expect(entries.contains(.start(id: "myapp-db")))
    }

    @Test("POST /projects/myapp/restart with MockRuntime leaves the container running (regression)")
    func restartWithMockRuntimeLeavesContainerRunning() async throws {
        // Regression test for the snapshot-staleness bug where restart() called
        // start() on a container that runtime.stop() had already transitioned to
        // .stopped. MockRuntime enforces the protocol contract (start requires
        // .created), so this test exercises the real state-machine path that
        // RecordingRuntime quietly bypasses.
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [
            Self.makeRunningContainer(id: "myapp-web"),
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/myapp/restart", method: .post) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode(APIProjectRestartResponse.self, from: response)
                    #expect(body.restarted == ["myapp-web"])
                }
            }
        }

        let snapshot = await runtime.snapshot()
        #expect(snapshot["myapp-web"]?.status == .running)
        #expect(snapshot["myapp-web"]?.imageReference == "alpine:3")
    }

    @Test("POST /projects/myapp/restart with services filter only restarts named services")
    func restartFilteredServicesOnly() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = RecordingRuntime(stubbedContainers: [
            Self.makeRunningContainer(id: "myapp-web"),
            Self.makeRunningContainer(id: "myapp-db"),
        ])
        let body = #"{"services":["web"]}"#

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp/restart",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: body)
                ) { response in
                    #expect(response.status == .ok)
                    let decoded = try Self.decode(APIProjectRestartResponse.self, from: response)
                    #expect(decoded.restarted.contains("myapp-web"))
                    // db should NOT be restarted
                    #expect(!decoded.restarted.contains("myapp-db"))
                }
            }
        }
    }

    @Test("POST /projects/missing/restart returns 404")
    func restartMissingProjectReturns404() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/missing/restart", method: .post) { response in
                    #expect(response.status == .notFound)
                }
            }
        }
    }

    // MARK: - POST /projects/{name}/build — NDJSON streaming

    @Test("POST /projects/myapp/build returns 200 with application/x-ndjson content type")
    func buildReturnsNDJSONStream() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [
            Self.makeRunningContainer(id: "myapp-web"),
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/myapp/build", method: .post) { response in
                    #expect(response.status == .ok)
                    let contentType = response.headers[.contentType]
                    #expect(contentType?.contains("ndjson") == true)
                    // Body should contain at least one JSON line
                    let rawBody = String(buffer: response.body)
                    #expect(!rawBody.isEmpty)
                    // Parse first NDJSON line
                    let firstLine = rawBody.split(separator: "\n").first.map(String.init) ?? ""
                    let data = Data(firstLine.utf8)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let frame = try decoder.decode(APIProjectBuildFrame.self, from: data)
                    #expect(!frame.service.isEmpty)
                    #expect(!frame.type.isEmpty)
                }
            }
        }
    }

    @Test("POST /projects/myapp/build emits a done frame as the final line")
    func buildEmitsDoneFrame() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [
            Self.makeRunningContainer(id: "myapp-web"),
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/myapp/build", method: .post) { response in
                    #expect(response.status == .ok)
                    let rawBody = String(buffer: response.body)
                    let lines = rawBody.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    #expect(!lines.isEmpty)
                    // Last frame should be "done" type
                    let lastLine = lines.last ?? ""
                    let data = Data(lastLine.utf8)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let frame = try decoder.decode(APIProjectBuildFrame.self, from: data)
                    #expect(frame.type == "done")
                }
            }
        }
    }

    // MARK: - POST /projects/{name}/pull — NDJSON streaming

    @Test("POST /projects/myapp/pull returns 200 with application/x-ndjson content type")
    func pullReturnsNDJSONStream() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [
            Self.makeRunningContainer(id: "myapp-web"),
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/myapp/pull", method: .post) { response in
                    #expect(response.status == .ok)
                    let contentType = response.headers[.contentType]
                    #expect(contentType?.contains("ndjson") == true)
                    let rawBody = String(buffer: response.body)
                    #expect(!rawBody.isEmpty)
                    // Each line should be a valid APIProjectPullFrame
                    let firstLine = rawBody.split(separator: "\n").first.map(String.init) ?? ""
                    let lineData = Data(firstLine.utf8)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let frame = try decoder.decode(APIProjectPullFrame.self, from: lineData)
                    #expect(!frame.service.isEmpty)
                    #expect(!frame.type.isEmpty)
                }
            }
        }
    }

    @Test("POST /projects/myapp/pull emits a done frame as the final line")
    func pullEmitsDoneFrame() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [
            Self.makeRunningContainer(id: "myapp-web"),
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/myapp/pull", method: .post) { response in
                    #expect(response.status == .ok)
                    let rawBody = String(buffer: response.body)
                    let lines = rawBody.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    #expect(!lines.isEmpty)
                    let lastLine = lines.last ?? ""
                    let data = Data(lastLine.utf8)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let frame = try decoder.decode(APIProjectPullFrame.self, from: data)
                    #expect(frame.type == "done")
                }
            }
        }
    }

    // MARK: - POST /projects/{name}/services/{service}/scale — happy path

    @Test("POST /projects/myapp/services/web/scale to 2 replicas creates the second container")
    func scaleUpCreatesNewReplicas() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        // Start with 1 replica (the base container myapp-web)
        let runtime = MockRuntime(containers: [
            Self.makeCreatedContainer(id: "myapp-web"),
        ])
        // Start the base container first so it's running
        try await runtime.start(id: "myapp-web")

        let body = #"{"replicas":2}"#

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp/services/web/scale",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: body)
                ) { response in
                    #expect(response.status == .ok)
                    let decoded = try Self.decode(APIProjectScaleResponse.self, from: response)
                    #expect(decoded.project == "myapp")
                    #expect(decoded.service == "web")
                    #expect(decoded.replicas == 2)
                    #expect(decoded.containers.count == 2)
                }
            }
        }

        let snapshot = await runtime.snapshot()
        #expect(snapshot.count == 2)
    }

    @Test("POST /projects/myapp/services/web/scale to 0 removes all replicas")
    func scaleDownToZeroRemovesAll() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [
            Self.makeRunningContainer(id: "myapp-web"),
        ])

        let body = #"{"replicas":0}"#

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp/services/web/scale",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: body)
                ) { response in
                    #expect(response.status == .ok)
                    let decoded = try Self.decode(APIProjectScaleResponse.self, from: response)
                    #expect(decoded.replicas == 0)
                    #expect(decoded.containers.isEmpty)
                }
            }
        }
    }

    @Test("POST /projects/{name}/services/{service}/scale with missing body returns 400")
    func scaleWithoutBodyReturns400() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(containers: [
            Self.makeRunningContainer(id: "myapp-web"),
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp/services/web/scale",
                    method: .post
                ) { response in
                    #expect(response.status == .badRequest)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message.contains("replicas"))
                }
            }
        }
    }

    // MARK: - ProjectOrchestrator unit tests

    @Test("ProjectOrchestrator.extractServiceName strips project prefix and replica suffix")
    func extractServiceNameStripsPrefix() {
        #expect(ProjectOrchestrator.extractServiceName(from: "myapp-web", project: "myapp") == "web")
        #expect(ProjectOrchestrator.extractServiceName(from: "myapp-web-1", project: "myapp") == "web")
        #expect(ProjectOrchestrator.extractServiceName(from: "myapp-api-server", project: "myapp") == "api-server")
        #expect(ProjectOrchestrator.extractServiceName(from: "other-web", project: "myapp") == "other-web")
    }

    @Test("ProjectOrchestrator.down throws projectNotFound for empty project")
    func downEmptyProjectThrows() async throws {
        let runtime = MockRuntime(containers: [])
        do {
            _ = try await ProjectOrchestrator.down(project: "nosuchproject", runtime: runtime)
            Issue.record("Expected projectNotFound error")
        } catch ProjectOrchestrator.OrchestratorError.projectNotFound(let name) {
            #expect(name == "nosuchproject")
        }
    }

    @Test("ProjectOrchestrator.scale with negative replicas throws invalidReplicaCount")
    func scaleNegativeReplicasThrows() async throws {
        let runtime = MockRuntime(containers: [])
        do {
            _ = try await ProjectOrchestrator.scale(
                project: "myapp",
                service: "web",
                replicas: -1,
                runtime: runtime
            )
            Issue.record("Expected invalidReplicaCount error")
        } catch ProjectOrchestrator.OrchestratorError.invalidReplicaCount(let count) {
            #expect(count == -1)
        }
    }
}
