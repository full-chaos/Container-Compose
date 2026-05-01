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
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import Testing
@testable import ContainerComposeCore

actor MockAuthStore: AuthStore {
    private var keys: [StoredKey] = []

    func find(hashHex: String) async -> StoredKey? {
        keys.first { $0.hash == hashHex }
    }

    func insert(_ key: StoredKey) async throws {
        keys.append(key)
    }

    func remove(name: String) async throws -> Bool {
        let count = keys.count
        keys.removeAll { $0.name == name }
        return count != keys.count
    }

    func list() async -> [StoredKey] {
        keys
    }
}

@Suite
struct AuthMiddlewareTests {

    // MARK: - Helpers

    private func makeApp<Store: AuthStore>(
        store: Store,
        mtlsTrustEstablished: (@Sendable () -> Bool)? = nil
    ) -> some ApplicationProtocol {
        let router = Router()
        router.add(middleware: RequestIDHeaderMiddleware())
        router.add(middleware: ErrorMappingMiddleware())
        router.add(middleware: MetricsMiddleware())
        router.add(middleware: AuthMiddleware<Store, BasicRequestContext>(
            store: store,
            logger: Logger(label: "container-compose.auth.tests"),
            mtlsTrustEstablished: mtlsTrustEstablished
        ))
        router.get("/test") { _, _ in "ok" }
        return Application(router: router)
    }

    private static func decode(_ response: TestResponse) throws -> APIErrorEnvelope {
        let data = Data(String(buffer: response.body).utf8)
        return try JSONDecoder().decode(APIErrorEnvelope.self, from: data)
    }

    private static func bearerHeaders(rawToken: String) -> HTTPFields {
        [.authorization: "Bearer \(rawToken)"]
    }

    // MARK: - Tests

    @Test
    func missingAuthReturns401WithEnvelope() async throws {
        let app = makeApp(store: MockAuthStore())

        try await app.test(.router) { client in
            try await client.execute(uri: "/test", method: .get) { response in
                let envelope = try Self.decode(response)
                #expect(response.status == .unauthorized)
                #expect(envelope.error == "unauthorized")
                #expect(envelope.message == "missing credentials")
                #expect(envelope.code == "E_401")
            }
        }
    }

    @Test
    func malformedAuthHeaderReturns401() async throws {
        let app = makeApp(store: MockAuthStore())
        let headers: HTTPFields = [.authorization: "Basic abc123"]

        try await app.test(.router) { client in
            try await client.execute(uri: "/test", method: .get, headers: headers) { response in
                let envelope = try Self.decode(response)
                #expect(response.status == .unauthorized)
                #expect(envelope.error == "unauthorized")
                #expect(envelope.message == "malformed authorization header")
                #expect(envelope.code == "E_401")
            }
        }
    }

    @Test
    func invalidBearerReturns403WithEnvelope() async throws {
        let app = makeApp(store: MockAuthStore())
        let headers = Self.bearerHeaders(rawToken: "cc_v1_invalid")

        try await app.test(.router) { client in
            try await client.execute(uri: "/test", method: .get, headers: headers) { response in
                let envelope = try Self.decode(response)
                #expect(response.status == .forbidden)
                #expect(envelope.error == "forbidden")
                #expect(envelope.message == "invalid credentials")
                #expect(envelope.code == "E_403")
            }
        }
    }

    @Test
    func validBearerReturns200() async throws {
        let store = MockAuthStore()
        let (rawToken, hashHex) = APIKeyGenerator.generate()
        try await store.insert(StoredKey(name: "local", hash: hashHex, createdAt: Date()))
        let app = makeApp(store: store)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/test",
                method: .get,
                headers: Self.bearerHeaders(rawToken: rawToken)
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "ok")
            }
        }
    }

    @Test
    func mtlsTrustedAllowsMissingBearer() async throws {
        let app = makeApp(store: MockAuthStore(), mtlsTrustEstablished: { true })

        try await app.test(.router) { client in
            try await client.execute(uri: "/test", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "ok")
            }
        }
    }

    @Test
    func mtlsTrustedAllowsInvalidBearer() async throws {
        let app = makeApp(store: MockAuthStore(), mtlsTrustEstablished: { true })
        let headers = Self.bearerHeaders(rawToken: "cc_v1_invalid")

        try await app.test(.router) { client in
            try await client.execute(uri: "/test", method: .get, headers: headers) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "ok")
            }
        }
    }

    @Test
    func envelopeContainsRequestIdMatchingHeader() async throws {
        let app = makeApp(store: MockAuthStore())

        try await app.test(.router) { client in
            try await client.execute(uri: "/test", method: .get) { response in
                let envelope = try Self.decode(response)
                let headerId = response.headers[HTTPField.Name.xRequestId] ?? ""
                #expect(response.status == .unauthorized)
                #expect(!headerId.isEmpty)
                #expect(envelope.requestId == headerId)
            }
        }
    }
}
