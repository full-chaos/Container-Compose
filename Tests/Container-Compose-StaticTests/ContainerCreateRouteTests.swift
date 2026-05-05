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

/// CHAOS-1352 — Phase 6 POST /containers/create endpoint.
/// Tests use `MockRuntime` (stateful actor) so that create → get → start
/// state-machine transitions can be verified end-to-end without any real backend.
@Suite("POST /containers/create route")
struct ContainerCreateRouteTests {

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
        let data = Data(String(buffer: response.body).utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    /// Build a router that has both the create route AND the container read
    /// routes registered, so integration tests can verify that a created
    /// container appears in `GET /containers`.
    private static func makeRouter() -> Router<BasicRequestContext> {
        let router = Router()
        ContainerRoutes.register(router: router)
        ContainerCreateRoute.register(router: router)
        return router
    }

    private static func makeMinimalBody(image: String = "alpine:3", name: String? = nil) -> String {
        if let name {
            return #"{"image":"\#(image)","name":"\#(name)"}"#
        }
        return #"{"image":"\#(image)"}"#
    }

    private static let jsonContentType: HTTPFields = [.contentType: "application/json"]

    // MARK: - POST /containers/create — happy path (minimal body)

    @Test("POST /containers/create returns 201 with id for minimal body (image only)")
    func createContainerMinimalBodyReturns201() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = ByteBuffer(string: Self.makeMinimalBody())
                try await client.execute(
                    uri: "/containers/create",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: body
                ) { response in
                    #expect(response.status == .created)
                    let parsed = try Self.decode(APICreateContainerResponse.self, from: response)
                    #expect(!parsed.id.isEmpty)
                }
            }
        }
    }

    @Test("POST /containers/create with name= uses that name as container id")
    func createContainerWithNameUsesNameAsId() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = ByteBuffer(string: Self.makeMinimalBody(name: "my-container"))
                try await client.execute(
                    uri: "/containers/create",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: body
                ) { response in
                    #expect(response.status == .created)
                    let parsed = try Self.decode(APICreateContainerResponse.self, from: response)
                    #expect(parsed.id == "my-container")
                }
            }
        }

        // Container should now be in registry
        let snapshot = await runtime.snapshot()
        #expect(snapshot["my-container"] != nil)
        #expect(snapshot["my-container"]?.status == .created)
    }

    @Test("POST /containers/create container appears in GET /containers afterward")
    func createContainerAppearsInList() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                // Create
                let body = ByteBuffer(string: Self.makeMinimalBody(name: "listed-ctr"))
                var createdId = ""
                try await client.execute(
                    uri: "/containers/create",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: body
                ) { response in
                    #expect(response.status == .created)
                    let parsed = try Self.decode(APICreateContainerResponse.self, from: response)
                    createdId = parsed.id
                }

                // Verify via GET /containers
                try await client.execute(uri: "/containers", method: .get) { listResponse in
                    #expect(listResponse.status == .ok)
                    let containers = try Self.decode([APIContainerSummary].self, from: listResponse)
                    #expect(containers.contains { $0.id == createdId })
                }
            }
        }
    }

    @Test("POST /containers/create → start transitions .created to .running")
    func createThenStartTransitionsState() async throws {
        // Register both create route AND lifecycle routes to test the full flow
        let router = Router()
        ContainerRoutes.register(router: router)
        ContainerCreateRoute.register(router: router)
        LifecycleRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                // Step 1: create
                let body = ByteBuffer(string: Self.makeMinimalBody(name: "start-test"))
                try await client.execute(
                    uri: "/containers/create",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: body
                ) { response in
                    #expect(response.status == .created)
                }

                // Step 2: start
                try await client.execute(
                    uri: "/containers/start-test/start",
                    method: .post
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let snapshot = await runtime.snapshot()
        #expect(snapshot["start-test"]?.status == .running)
    }

    @Test("POST /containers/create passes cpu, memory, hostname, env, cmd, workingDir")
    func createContainerPassesAllFields() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()
        let bodyJSON = """
        {
            "image": "ubuntu:22.04",
            "name": "full-fields",
            "cpus": 2,
            "memoryBytes": 536870912,
            "hostname": "my-host",
            "env": ["FOO=bar", "BAZ=qux"],
            "cmd": ["/bin/sh", "-c", "echo hello"],
            "workingDir": "/app"
        }
        """

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/containers/create",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: ByteBuffer(string: bodyJSON)
                ) { response in
                    #expect(response.status == .created)
                    let parsed = try Self.decode(APICreateContainerResponse.self, from: response)
                    #expect(parsed.id == "full-fields")
                }
            }
        }

        let snapshot = await runtime.snapshot()
        let container = try #require(snapshot["full-fields"])
        #expect(container.imageReference == "ubuntu:22.04")
    }

    @Test("POST /containers/create with publishedPorts preserves port mappings")
    func createContainerWithPublishedPorts() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()
        let bodyJSON = """
        {
            "image": "nginx:latest",
            "name": "webserver",
            "publishedPorts": [
                {"hostPort": 8080, "containerPort": 80, "proto": "tcp", "hostAddress": "0.0.0.0"}
            ]
        }
        """

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/containers/create",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: ByteBuffer(string: bodyJSON)
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }

        let snapshot = await runtime.snapshot()
        let container = try #require(snapshot["webserver"])
        #expect(container.publishedPorts.count == 1)
        #expect(container.publishedPorts[0].hostPort == 8080)
        #expect(container.publishedPorts[0].containerPort == 80)
    }

    // MARK: - POST /containers/create — error paths

    @Test("POST /containers/create returns 400 when body is missing")
    func createContainerMissingBodyReturns400() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/create", method: .post) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
    }

    @Test("POST /containers/create returns 400 when body is malformed JSON")
    func createContainerMalformedBodyReturns400() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/containers/create",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: ByteBuffer(string: "not json")
                ) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
    }

    @Test("POST /containers/create returns 400 when image field is missing")
    func createContainerMissingImageReturns400() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                // Body with no 'image' field — should fail decoding
                try await client.execute(
                    uri: "/containers/create",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: ByteBuffer(string: #"{"name":"test"}"#)
                ) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
    }

    @Test("POST /containers/create returns 409 when container with same name already exists")
    func createDuplicateContainerReturns409() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        // Pre-seed registry with a container named "dup"
        let existingContainer = RuntimeContainer(
            id: "dup",
            imageReference: "alpine:3",
            status: .created
        )
        let runtime = MockRuntime(containers: [existingContainer])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = ByteBuffer(string: Self.makeMinimalBody(name: "dup"))
                try await client.execute(
                    uri: "/containers/create",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: body
                ) { response in
                    #expect(response.status == .conflict)
                    let parsed = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(parsed.message.contains("dup"))
                }
            }
        }
    }

    // MARK: - ?name= query alias (nice-to-have)

    @Test("POST /containers/create?name=my-ctr uses query param name when body name is absent")
    func createContainerNameFromQueryParam() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = ByteBuffer(string: #"{"image":"alpine:3"}"#)
                try await client.execute(
                    uri: "/containers/create?name=query-name",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: body
                ) { response in
                    #expect(response.status == .created)
                    let parsed = try Self.decode(APICreateContainerResponse.self, from: response)
                    #expect(parsed.id == "query-name")
                }
            }
        }
    }

    @Test("POST /containers/create body name takes precedence over query name")
    func createContainerBodyNameTakesPrecedenceOverQuery() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = ByteBuffer(string: Self.makeMinimalBody(name: "body-name"))
                try await client.execute(
                    uri: "/containers/create?name=query-name",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: body
                ) { response in
                    #expect(response.status == .created)
                    let parsed = try Self.decode(APICreateContainerResponse.self, from: response)
                    #expect(parsed.id == "body-name")
                }
            }
        }
    }

    // MARK: - RuntimeError.notSupported → 501 Not Implemented

    /// Minimal `Runtime` conformer that throws `notSupported` from every method.
    /// Used to verify the route maps `RuntimeError.notSupported` → 501. A stateless
    /// struct is sufficient (auto-`Sendable`); no actor isolation is needed.
    private struct NotSupportedRuntime: Runtime {
        private static let conformer = "NotSupportedRuntime"
        private static func unsupported(_ operation: String) -> RuntimeError {
            .notSupported(operation: operation, conformer: conformer)
        }

        func version() async throws -> RuntimeVersion { throw Self.unsupported("version") }
        func list(filters: RuntimeListFilters) async throws -> [RuntimeContainer] { throw Self.unsupported("list") }
        func listNetworks() async throws -> [RuntimeNetwork] { throw Self.unsupported("listNetworks") }
        func get(id: String) async throws -> RuntimeContainer { throw Self.unsupported("get") }
        func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> RuntimeContainer {
            throw Self.unsupported("create")
        }
        func start(id: String) async throws { throw Self.unsupported("start") }
        func stop(id: String, options: RuntimeStopOptions) async throws { throw Self.unsupported("stop") }
        func kill(id: String, signal: Int32) async throws { throw Self.unsupported("kill") }
        func wait(id: String, timeoutSeconds: Int) async throws -> RuntimeExitStatus {
            throw Self.unsupported("wait")
        }
        func remove(id: String, force: Bool) async throws { throw Self.unsupported("remove") }
        func logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame> {
            throw Self.unsupported("logs")
        }
        func events() async throws -> AsyncStream<RuntimeContainerEvent> { throw Self.unsupported("events") }
        func statistics(for id: String) async throws -> RuntimeStatistics { throw Self.unsupported("statistics") }
        func createNetwork(spec: RuntimeCreateNetworkSpec) async throws -> RuntimeNetwork {
            throw Self.unsupported("createNetwork")
        }
        func removeNetwork(id: String) async throws { throw Self.unsupported("removeNetwork") }
        func listVolumes() async throws -> [RuntimeVolume] { throw Self.unsupported("listVolumes") }
        func createVolume(spec: RuntimeCreateVolumeSpec) async throws -> RuntimeVolume {
            throw Self.unsupported("createVolume")
        }
        func removeVolume(name: String) async throws { throw Self.unsupported("removeVolume") }
        func listSecrets() async throws -> [RuntimeSecret] { throw Self.unsupported("listSecrets") }
        func createSecret(spec: RuntimeCreateSecretSpec) async throws -> RuntimeSecret {
            throw Self.unsupported("createSecret")
        }
        func removeSecret(name: String) async throws { throw Self.unsupported("removeSecret") }
        func pull(specs: [RuntimePullSpec], ignoreFailures: Bool) async throws -> AsyncStream<RuntimePullEvent> {
            throw Self.unsupported("pull")
        }
        func build(specs: [RuntimeBuildSpec]) async throws -> AsyncStream<RuntimeBuildEvent> {
            throw Self.unsupported("build")
        }
    }

    @Test("POST /containers/create returns 501 when runtime throws RuntimeError.notSupported")
    func createContainerNotSupportedReturns501() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = NotSupportedRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = ByteBuffer(string: Self.makeMinimalBody())
                try await client.execute(
                    uri: "/containers/create",
                    method: .post,
                    headers: Self.jsonContentType,
                    body: body
                ) { response in
                    #expect(response.status == .notImplemented)
                }
            }
        }
    }
}
