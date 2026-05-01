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

@Suite("Network write routes — POST /networks, DELETE /networks/{id}")
struct NetworkWriteRoutesTests {

    // MARK: - Helpers

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

    // MARK: - POST /networks

    @Test("POST /networks returns 201 with id and name on success")
    func postNetworkCreates() async throws {
        let router = Router()
        NetworkRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(name: "mynet", driver: "bridge"))
                try await client.execute(
                    uri: "/networks",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                    let resp = try Self.decode(APICreateNetworkResponse.self, from: response)
                    #expect(resp.name == "mynet")
                    #expect(!resp.id.isEmpty)
                }
            }
        }

        let networks = await runtime.networksSnapshot()
        #expect(networks.contains(where: { $0.name == "mynet" }))
    }

    @Test("POST /networks uses bridge as default driver")
    func postNetworkDefaultDriver() async throws {
        let router = Router()
        NetworkRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(name: "defaultnet"))
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

        let network = await runtime.networksSnapshot().first { $0.name == "defaultnet" }
        #expect(network?.driver == "bridge")
    }

    @Test("POST /networks propagates labels")
    func postNetworkLabels() async throws {
        let router = Router()
        NetworkRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(
                    name: "labelnet",
                    driver: "bridge",
                    labels: ["project": "compose", "env": "test"]
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

        let network = await runtime.networksSnapshot().first { $0.name == "labelnet" }
        #expect(network?.labels == ["project": "compose", "env": "test"])
    }

    @Test("POST /networks returns 409 when network already exists")
    func postNetworkConflict() async throws {
        let router = Router()
        NetworkRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(networks: [
            RuntimeNetwork(id: "existing-id", name: "mynet", driver: "bridge")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(name: "mynet"))
                try await client.execute(
                    uri: "/networks",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .conflict)
                    let err = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(err.message.contains("mynet"))
                }
            }
        }
    }

    @Test("POST /networks records createNetwork call")
    func postNetworkRecorded() async throws {
        let router = Router()
        NetworkRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateNetworkRequest(name: "rec-net"))
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

        #expect(await runtime.entriesSnapshot() == [.createNetwork(name: "rec-net")])
    }

    // MARK: - DELETE /networks/{id}

    @Test("DELETE /networks/{id} returns 204 on success")
    func deleteNetworkSuccess() async throws {
        let router = Router()
        NetworkRoutes.register(router: router)
        let app = Application(router: router)
        let existingId = "net-to-delete"
        let runtime = MockRuntime(networks: [
            RuntimeNetwork(id: existingId, name: "deleteme", driver: "bridge")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/networks/\(existingId)",
                    method: .delete
                ) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let networks = await runtime.networksSnapshot()
        #expect(!networks.contains(where: { $0.id == existingId }))
    }

    @Test("DELETE /networks/{id} returns 404 for unknown id")
    func deleteNetworkNotFound() async throws {
        let router = Router()
        NetworkRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/networks/ghost-id", method: .delete) { response in
                    #expect(response.status == .notFound)
                    let err = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(err.message.contains("ghost-id"))
                }
            }
        }
    }

    @Test("DELETE /networks/{id} records removeNetwork call")
    func deleteNetworkRecorded() async throws {
        let router = Router()
        NetworkRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime(stubbedNetworks: [
            RuntimeNetwork(id: "known-id", name: "known", driver: "bridge")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/networks/known-id", method: .delete) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.removeNetwork(id: "known-id")])
    }
}
