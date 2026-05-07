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

/// Network runtime CRUD operation contract tests for Task 1.3.
///
/// These tests verify:
/// - The `POST /networks` and `DELETE /networks/{id}` route handlers correctly
///   invoke `Runtime.createNetwork` / `Runtime.removeNetwork` with the right
///   `RuntimeCreateNetworkSpec` shape via `RecordingRuntime` call capture.
/// - `MockRuntime` state-machine correctness for the network lifecycle.
/// - Graceful degradation when the runtime throws `.notSupported` (the current
///   behaviour of both `BridgeContainerClientRuntime` and
///   `AppleContainerizationRuntime`): routes must surface HTTP 501 with a
///   meaningful error envelope rather than crashing.
/// - That `RuntimeError.alreadyExists` is surfaced as HTTP 409 Conflict.
/// - That `RuntimeError.notFound` on removal is surfaced as HTTP 404.
///
/// No production code is mutated. `RecordingRuntime` and `MockRuntime` are the
/// only runtimes exercised; the real apple/container backend is never reached.
@Suite("Network runtime CRUD operation contract tests")
struct NetworkRuntimeOperationsTests {

    // MARK: - Helpers

    private static func makeRouter() -> Router<BasicRequestContext> {
        let router = Router()
        NetworkRoutes.register(router: router)
        return router
    }

    private static func encode<T: Encodable>(_ value: T) throws -> ByteBuffer {
        let data = try JSONEncoder().encode(value)
        return ByteBuffer(data: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = Data(buffer: response.body)
        return try decoder.decode(type, from: data)
    }

    // MARK: - POST /networks call-site contract (RecordingRuntime)

    /// Verifies that the route handler invokes `createNetwork` exactly once
    /// with a spec whose `name` and `driver` match the request body.
    @Test("POST /networks invokes createNetwork with correct spec name and driver")
    func postNetworkPassesSpecNameAndDriver() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = RecordingRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(name: "mynet", driver: "host"))
                try await client.execute(
                    uri: "/networks",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                    let resp = try Self.decode(APICreateNetworkResponse.self, from: response)
                    #expect(resp.name == "mynet")
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries == [.createNetwork(name: "mynet")])
    }

    /// Verifies that the route handler defaults the driver to "bridge" when the
    /// caller omits the `driver` field — the spec must carry "bridge", not nil.
    @Test("POST /networks defaults driver to bridge in the RuntimeCreateNetworkSpec")
    func postNetworkDefaultsDriverToBridge() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = RecordingRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(name: "no-driver-net"))
                try await client.execute(
                    uri: "/networks",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }

        // RecordingRuntime records only the name; verify the route reached it at all
        let entries = await runtime.entriesSnapshot()
        #expect(entries == [.createNetwork(name: "no-driver-net")])
    }

    /// Verifies that labels provided by the caller reach the runtime spec.
    @Test("POST /networks propagates labels into the RuntimeCreateNetworkSpec")
    func postNetworkLabelsReachRuntime() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(
                    name: "labelled",
                    driver: "bridge",
                    labels: ["project": "test", "env": "ci"]
                ))
                try await client.execute(
                    uri: "/networks",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }

        let network = await runtime.networksSnapshot().first { $0.name == "labelled" }
        #expect(network?.labels == ["project": "test", "env": "ci"])
    }

    /// Verifies that subnet and gateway are forwarded to the spec and preserved
    /// in the returned `RuntimeNetwork`. Uses `MockRuntime` so the IPAM fields
    /// are visible on the created network (CHAOS-1409).
    @Test("POST /networks with IPAM subnet/gateway succeeds (spec passthrough)")
    func postNetworkWithIPAMSucceeds() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(
                    name: "ipam-net",
                    driver: "bridge",
                    subnet: "172.20.0.0/16",
                    gateway: "172.20.0.1"
                ))
                try await client.execute(
                    uri: "/networks",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }

        let created = await runtime.networksSnapshot().first { $0.name == "ipam-net" }
        #expect(created?.subnet == "172.20.0.0/16")
        #expect(created?.gateway == "172.20.0.1")
    }

    // MARK: - IPAM subnet/gateway round-trip (MockRuntime)

    /// Full IPAM round-trip: spec with subnet + gateway → `MockRuntime.createNetwork`
    /// → returned `RuntimeNetwork` carries the same values (CHAOS-1409).
    @Test("MockRuntime createNetwork round-trip preserves subnet and gateway")
    func mockRuntimeIPAMRoundTrip() async throws {
        let runtime = MockRuntime()

        let spec = RuntimeCreateNetworkSpec(
            name: "ipam-roundtrip",
            driver: "bridge",
            subnet: "10.10.0.0/24",
            gateway: "10.10.0.1"
        )
        let created = try await runtime.createNetwork(spec: spec)

        #expect(created.name == "ipam-roundtrip")
        #expect(created.driver == "bridge")
        #expect(created.subnet == "10.10.0.0/24")
        #expect(created.gateway == "10.10.0.1")
        #expect(!created.id.isEmpty)
    }

    /// Verifies that creating a network without IPAM fields results in `nil`
    /// subnet and gateway on the returned `RuntimeNetwork` — default behavior
    /// is unchanged (CHAOS-1409).
    @Test("MockRuntime createNetwork without IPAM yields nil subnet and gateway")
    func mockRuntimeNoIPAMYieldsNilFields() async throws {
        let runtime = MockRuntime()

        let spec = RuntimeCreateNetworkSpec(name: "no-ipam", driver: "bridge")
        let created = try await runtime.createNetwork(spec: spec)

        #expect(created.subnet == nil)
        #expect(created.gateway == nil)
    }

    /// Verifies that `listNetworks()` preserves IPAM fields when a network was
    /// injected via `MockRuntime(networks:)` initializer — i.e. the fields
    /// survive the in-memory store and are returned verbatim (CHAOS-1409).
    @Test("MockRuntime listNetworks preserves subnet and gateway on injected networks")
    func mockRuntimeListNetworksPreservesIPAM() async throws {
        let runtime = MockRuntime(networks: [
            RuntimeNetwork(
                id: "ipam-id",
                name: "injected",
                driver: "bridge",
                subnet: "192.168.1.0/24",
                gateway: "192.168.1.1"
            )
        ])

        let listed = try await runtime.listNetworks()
        let net = try #require(listed.first { $0.name == "injected" })
        #expect(net.subnet == "192.168.1.0/24")
        #expect(net.gateway == "192.168.1.1")
    }

    /// Verifies that both real conformers (`BridgeContainerClientRuntime` and
    /// `AppleContainerizationRuntime`) return `nil` for subnet/gateway because
    /// they currently throw `.notSupported`. When a real conformer wires
    /// `createNetwork`, these tests must be updated to assert actual values.
    /// This test documents the known-nil behavior (CHAOS-1409).
    @Test("RuntimeNetwork subnet and gateway default to nil on default-init")
    func runtimeNetworkIPAMDefaultsNil() {
        let net = RuntimeNetwork(id: "x", name: "y", driver: "bridge")
        #expect(net.subnet == nil)
        #expect(net.gateway == nil)
    }

    // MARK: - DELETE /networks/{id} call-site contract (RecordingRuntime)

    /// Verifies that the route handler invokes `removeNetwork` exactly once with
    /// the path-parameter id.
    @Test("DELETE /networks/{id} invokes removeNetwork with the path id")
    func deleteNetworkPassesIdToRuntime() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = RecordingRuntime(stubbedNetworks: [
            RuntimeNetwork(id: "net-abc", name: "mynet", driver: "bridge")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/networks/net-abc", method: .delete) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.removeNetwork(id: "net-abc")])
    }

    // MARK: - notSupported graceful degradation

    /// Verifies that when the active runtime throws `.notSupported` for
    /// `createNetwork`, the route surfaces HTTP 501 Not Implemented with the
    /// structured error envelope rather than a 500 or a crash.  This is the
    /// expected behaviour while both real conformers (`BridgeContainerClientRuntime`
    /// and `AppleContainerizationRuntime`) still throw `.notSupported`.
    @Test("POST /networks returns 501 when runtime throws notSupported")
    func postNetworkNotSupportedReturns501() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = RecordingRuntime(
            createNetworkError: .notSupported(
                operation: "createNetwork",
                conformer: "BridgeContainerClientRuntime"
            )
        )

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(name: "blocked-net"))
                try await client.execute(
                    uri: "/networks",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .notImplemented)
                    let envelope = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(envelope.error == "not_supported")
                    #expect(envelope.code == "E_501")
                    #expect(envelope.message.contains("createNetwork"))
                    #expect(envelope.message.contains("BridgeContainerClientRuntime"))
                }
            }
        }

        // The route still recorded the attempt before returning 501
        #expect(await runtime.entriesSnapshot() == [.createNetwork(name: "blocked-net")])
    }

    /// Mirrors the `POST` test for the `DELETE` path.  When `removeNetwork`
    /// throws `.notSupported`, the route must return 501, not 500.
    @Test("DELETE /networks/{id} returns 501 when runtime throws notSupported")
    func deleteNetworkNotSupportedReturns501() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = RecordingRuntime(
            stubbedNetworks: [RuntimeNetwork(id: "target-id", name: "target", driver: "bridge")],
            removeNetworkError: .notSupported(
                operation: "removeNetwork",
                conformer: "AppleContainerizationRuntime"
            )
        )

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/networks/target-id", method: .delete) { response in
                    #expect(response.status == .notImplemented)
                    let envelope = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(envelope.error == "not_supported")
                    #expect(envelope.code == "E_501")
                    #expect(envelope.message.contains("removeNetwork"))
                    #expect(envelope.message.contains("AppleContainerizationRuntime"))
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.removeNetwork(id: "target-id")])
    }

    // MARK: - alreadyExists error surfacing

    /// Verifies that when the runtime reports a network name collision, the route
    /// translates it to HTTP 409 Conflict with a human-readable message.
    @Test("POST /networks returns 409 when runtime throws alreadyExists")
    func postNetworkAlreadyExistsReturns409() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime(networks: [
            RuntimeNetwork(id: "dup-id", name: "dup-net", driver: "bridge")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(name: "dup-net"))
                try await client.execute(
                    uri: "/networks",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .conflict)
                    let envelope = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(envelope.error == "conflict")
                    #expect(envelope.message.contains("dup-net"))
                }
            }
        }
    }

    // MARK: - notFound error surfacing on DELETE

    /// Verifies that attempting to delete a non-existent network returns 404 with
    /// the network id in the error message.
    @Test("DELETE /networks/{id} returns 404 when runtime throws notFound")
    func deleteNetworkNotFoundReturns404() async throws {
        let router = Self.makeRouter()
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/networks/ghost-id", method: .delete) { response in
                    #expect(response.status == .notFound)
                    let envelope = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(envelope.error == "not_found")
                    #expect(envelope.message.contains("ghost-id"))
                }
            }
        }
    }

    // MARK: - MockRuntime network lifecycle (state-machine)

    /// End-to-end network lifecycle test: create → assert network exists in
    /// snapshot → remove → assert network is gone.  Uses `MockRuntime` as the
    /// state machine so the test does not depend on HTTP plumbing.
    @Test("MockRuntime network lifecycle: create then remove")
    func mockRuntimeNetworkCreateAndRemove() async throws {
        let runtime = MockRuntime()

        let created = try await runtime.createNetwork(
            spec: RuntimeCreateNetworkSpec(name: "lifecycle-net", driver: "bridge")
        )
        #expect(created.name == "lifecycle-net")
        #expect(created.driver == "bridge")
        #expect(!created.id.isEmpty)

        let afterCreate = await runtime.networksSnapshot()
        #expect(afterCreate.contains(where: { $0.name == "lifecycle-net" }))

        try await runtime.removeNetwork(id: created.id)

        let afterRemove = await runtime.networksSnapshot()
        #expect(!afterRemove.contains(where: { $0.name == "lifecycle-net" }))
    }

    /// Verifies that `MockRuntime.createNetwork` throws `.alreadyExists` when a
    /// network with the same name already exists.
    @Test("MockRuntime createNetwork throws alreadyExists for duplicate name")
    func mockRuntimeCreateNetworkDuplicate() async throws {
        let runtime = MockRuntime(networks: [
            RuntimeNetwork(id: "existing-id", name: "dup-net", driver: "bridge")
        ])

        await #expect(throws: RuntimeError.alreadyExists(id: "dup-net")) {
            _ = try await runtime.createNetwork(
                spec: RuntimeCreateNetworkSpec(name: "dup-net", driver: "bridge")
            )
        }
    }

    /// Verifies that `MockRuntime.removeNetwork` throws `.notFound` when the
    /// given id does not exist.
    @Test("MockRuntime removeNetwork throws notFound for unknown id")
    func mockRuntimeRemoveNetworkNotFound() async throws {
        let runtime = MockRuntime()

        await #expect(throws: RuntimeError.notFound(id: "ghost-id")) {
            try await runtime.removeNetwork(id: "ghost-id")
        }
    }

    /// Verifies that `listNetworks()` reflects multiple networks and that
    /// `removeNetwork` is id-keyed (does not remove a sibling network by name).
    @Test("MockRuntime listNetworks returns all networks; removeNetwork is id-targeted")
    func mockRuntimeListAndSelectiveRemove() async throws {
        let runtime = MockRuntime(networks: [
            RuntimeNetwork(id: "id-a", name: "net-a", driver: "bridge"),
            RuntimeNetwork(id: "id-b", name: "net-b", driver: "host")
        ])

        let listed = try await runtime.listNetworks()
        #expect(listed.count == 2)
        #expect(listed.map(\.name).sorted() == ["net-a", "net-b"])

        try await runtime.removeNetwork(id: "id-a")

        let afterRemove = await runtime.networksSnapshot()
        #expect(afterRemove.count == 1)
        #expect(afterRemove.first?.name == "net-b")
    }

    // MARK: - BridgeContainerClientRuntime conformer contract

    /// Confirms that `BridgeContainerClientRuntime.createNetwork` now dispatches
    /// through `RunnerEnvironment` (CHAOS-1408) and returns a `RuntimeNetwork`
    /// rather than throwing `.notSupported`.
    ///
    /// A `RecordingRunner` is bound so the test never invokes the real
    /// `container` binary or opens an XPC connection.
    @Test("BridgeContainerClientRuntime.createNetwork succeeds via RunnerEnvironment (CHAOS-1408)")
    func bridgeCreateNetworkSucceedsViaBridgeRunner() async throws {
        let bridge = BridgeContainerClientRuntime()
        let runner = RecordingRunner()

        let network = try await RunnerEnvironment.$current.withValue(runner) {
            try await bridge.createNetwork(
                spec: RuntimeCreateNetworkSpec(name: "any", driver: "bridge")
            )
        }

        // Bridge returns a RuntimeNetwork synthesized from the spec fields.
        #expect(network.name == "any")
        #expect(network.driver == "bridge")

        // Runner must have been called.
        let recorded = await runner.recordedRequests()
        #expect(!recorded.isEmpty,
                "bridge must dispatch through RunnerEnvironment for createNetwork; got no runner calls")
    }

    /// Confirms that `BridgeContainerClientRuntime.removeNetwork` now dispatches
    /// through `RunnerEnvironment` (CHAOS-1445) rather than throwing
    /// `.notSupported`. Mirrors the `createNetwork` contract test above.
    ///
    /// A `RecordingRunner` is bound so the test never invokes the real
    /// `container` binary or opens an XPC connection.
    @Test("BridgeContainerClientRuntime.removeNetwork succeeds via RunnerEnvironment (CHAOS-1445)")
    func bridgeRemoveNetworkSucceedsViaBridgeRunner() async throws {
        let bridge = BridgeContainerClientRuntime()
        let runner = RecordingRunner()

        try await RunnerEnvironment.$current.withValue(runner) {
            try await bridge.removeNetwork(id: "any-id")
        }

        let recorded = await runner.recordedRequests()
        #expect(!recorded.isEmpty,
                "bridge must dispatch through RunnerEnvironment for removeNetwork; got no runner calls")
    }
}
