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

@Suite("Secret routes — GET/POST/DELETE /secrets")
struct SecretRoutesTests {

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

    // MARK: - GET /secrets

    @Test("GET /secrets returns empty list when no secrets")
    func getSecretsEmpty() async throws {
        let router = Router()
        SecretRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/secrets", method: .get) { response in
                    #expect(response.status == .ok)
                    let secrets = try Self.decode([APISecretSummary].self, from: response)
                    #expect(secrets.isEmpty)
                }
            }
        }
    }

    @Test("GET /secrets returns secret metadata but not values")
    func getSecretsList() async throws {
        let router = Router()
        SecretRoutes.register(router: router)
        let app = Application(router: router)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let runtime = MockRuntime(secrets: [
            RuntimeSecret(name: "db-password", labels: ["tier": "db"], createdAt: createdAt),
            RuntimeSecret(name: "api-key", labels: [:], createdAt: nil)
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/secrets", method: .get) { response in
                    #expect(response.status == .ok)
                    let secrets = try Self.decode([APISecretSummary].self, from: response)
                    #expect(secrets.count == 2)
                    let names = Set(secrets.map { $0.name })
                    #expect(names == Set(["db-password", "api-key"]))
                    // Values must NEVER appear in the response schema or payload
                    let rawJson = String(data: Data(buffer: response.body), encoding: .utf8) ?? ""
                    #expect(!rawJson.contains("supersecret"))
                    let dbSecret = secrets.first { $0.name == "db-password" }
                    #expect(dbSecret?.labels == ["tier": "db"])
                }
            }
        }
    }

    @Test("GET /secrets records listSecrets call")
    func getSecretsRecorded() async throws {
        let router = Router()
        SecretRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/secrets", method: .get) { response in
                    #expect(response.status == .ok)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.listSecrets])
    }

    // MARK: - POST /secrets

    @Test("POST /secrets returns 201 with name-only response (value not echoed)")
    func postSecretCreates() async throws {
        let router = Router()
        SecretRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateSecretRequest(
                    name: "db-pass",
                    value: "super-secret-pw"
                ))
                try await client.execute(
                    uri: "/secrets",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                    let resp = try Self.decode(APICreateSecretResponse.self, from: response)
                    #expect(resp.name == "db-pass")
                    // Value must NOT appear in the response body
                    let rawJson = String(data: Data(buffer: response.body), encoding: .utf8) ?? ""
                    #expect(!rawJson.contains("super-secret-pw"))
                }
            }
        }

        let secrets = await runtime.secretsSnapshot()
        #expect(secrets.contains(where: { $0.name == "db-pass" }))
    }

    @Test("POST /secrets propagates labels")
    func postSecretLabels() async throws {
        let router = Router()
        SecretRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateSecretRequest(
                    name: "labeled-secret",
                    value: "v",
                    labels: ["env": "staging"]
                ))
                try await client.execute(
                    uri: "/secrets",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }

        let secret = await runtime.secretsSnapshot().first { $0.name == "labeled-secret" }
        #expect(secret?.labels == ["env": "staging"])
    }

    @Test("POST /secrets returns 409 when secret already exists")
    func postSecretConflict() async throws {
        let router = Router()
        SecretRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(secrets: [
            RuntimeSecret(name: "existing-secret")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateSecretRequest(name: "existing-secret", value: "x"))
                try await client.execute(
                    uri: "/secrets",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .conflict)
                    let err = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(err.message.contains("existing-secret"))
                }
            }
        }
    }

    @Test("POST /secrets records createSecret call")
    func postSecretRecorded() async throws {
        let router = Router()
        SecretRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateSecretRequest(name: "recorded-secret", value: "v"))
                try await client.execute(
                    uri: "/secrets",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.createSecret(name: "recorded-secret")])
    }

    // MARK: - DELETE /secrets/{name}

    @Test("DELETE /secrets/{name} returns 204 on success")
    func deleteSecretSuccess() async throws {
        let router = Router()
        SecretRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(secrets: [
            RuntimeSecret(name: "to-remove")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/secrets/to-remove", method: .delete) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let secrets = await runtime.secretsSnapshot()
        #expect(!secrets.contains(where: { $0.name == "to-remove" }))
    }

    @Test("DELETE /secrets/{name} returns 404 for unknown name")
    func deleteSecretNotFound() async throws {
        let router = Router()
        SecretRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/secrets/ghost-secret", method: .delete) { response in
                    #expect(response.status == .notFound)
                    let err = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(err.message.contains("ghost-secret"))
                }
            }
        }
    }

    @Test("DELETE /secrets/{name} records removeSecret call")
    func deleteSecretRecorded() async throws {
        let router = Router()
        SecretRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime(stubbedSecrets: [
            RuntimeSecret(name: "recorded-del")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/secrets/recorded-del", method: .delete) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.removeSecret(name: "recorded-del")])
    }
}
