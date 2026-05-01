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
import Testing
@testable import ContainerComposeCore
import TestHelpers

/// CHAOS-1357 — golden wire-shape tests for `APIErrorEnvelope` and
/// the middleware pair `RequestIDHeaderMiddleware` + `ErrorMappingMiddleware`.
@Suite("APIErrorEnvelope + middleware (CHAOS-1357)")
struct ErrorEnvelopeTests {

    // MARK: - Helpers

    private static func decode(_ response: TestResponse) throws -> APIErrorEnvelope {
        let data = Data(String(buffer: response.body).utf8)
        return try JSONDecoder().decode(APIErrorEnvelope.self, from: data)
    }

    // MARK: - APIErrorEnvelope.legacy round-trip

    @Test("legacy(404) produces not_found key and E_404 code")
    func legacy404() {
        let env = APIErrorEnvelope.legacy(.notFound, message: "No such item", requestId: "req-1")
        #expect(env.error == "not_found")
        #expect(env.code == "E_404")
        #expect(env.message == "No such item")
        #expect(env.requestId == "req-1")
    }

    @Test("legacy(409) produces conflict key and E_409 code")
    func legacy409() {
        let env = APIErrorEnvelope.legacy(.conflict, message: "Already exists", requestId: "req-2")
        #expect(env.error == "conflict")
        #expect(env.code == "E_409")
    }

    @Test("legacy(501) produces not_supported key and E_501 code")
    func legacy501() {
        let env = APIErrorEnvelope.legacy(.notImplemented, message: "Not supported", requestId: "req-3")
        #expect(env.error == "not_supported")
        #expect(env.code == "E_501")
    }

    @Test("legacy(500) produces internal_error key and E_500 code")
    func legacy500() {
        let env = APIErrorEnvelope.legacy(.internalServerError, message: "Oops", requestId: "req-4")
        #expect(env.error == "internal_error")
        #expect(env.code == "E_500")
    }

    @Test("custom code overrides E_NNN default")
    func legacyCustomCode() {
        let env = APIErrorEnvelope.legacy(.notFound, message: "Gone", code: "CUSTOM_CODE", requestId: "r")
        #expect(env.code == "CUSTOM_CODE")
    }

    @Test("APIErrorEnvelope JSON round-trip preserves all fields")
    func jsonRoundTrip() throws {
        let original = APIErrorEnvelope(
            error: "not_found",
            message: "No such container: foo",
            code: "E_404",
            requestId: "abc-123"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(APIErrorEnvelope.self, from: data)
        #expect(decoded.error == "not_found")
        #expect(decoded.message == "No such container: foo")
        #expect(decoded.code == "E_404")
        #expect(decoded.requestId == "abc-123")
    }

    // MARK: - RequestIDHeaderMiddleware

    @Test("X-Request-Id header is non-empty on success response")
    func requestIdHeaderOnSuccess() async throws {
        let router = Router()
        router.add(middleware: RequestIDHeaderMiddleware())
        router.get("/test") { _, _ in "ok" }
        let app = Application(router: router)

        try await app.test(.router) { client in
            try await client.execute(uri: "/test", method: .get) { response in
                let header = response.headers[HTTPField.Name.xRequestId]
                #expect(header != nil)
                #expect(!(header ?? "").isEmpty)
            }
        }
    }

    @Test("X-Request-Id is non-empty on three consecutive requests")
    func requestIdHeaderConsistentAcrossRequests() async throws {
        let router = Router()
        router.add(middleware: RequestIDHeaderMiddleware())
        router.get("/test") { _, _ in "ok" }
        let app = Application(router: router)

        try await app.test(.router) { client in
            for _ in 0..<3 {
                try await client.execute(uri: "/test", method: .get) { response in
                    let id = response.headers[HTTPField.Name.xRequestId]
                    #expect(id != nil)
                    #expect(!(id ?? "").isEmpty)
                }
            }
        }
    }

    // MARK: - ErrorMappingMiddleware

    private func makeErrorApp(throwing error: RuntimeError) async throws {
        let router = Router()
        router.add(middleware: RequestIDHeaderMiddleware())
        router.add(middleware: ErrorMappingMiddleware())
        let thrownError = error
        router.get("/probe") { _, _ -> String in
            throw thrownError
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            try await client.execute(uri: "/probe", method: .get) { response in
                let env = try Self.decode(response)
                switch thrownError {
                case .notFound:
                    #expect(response.status == .notFound)
                    #expect(env.error == "not_found")
                    #expect(env.code == "E_404")
                    #expect(!env.requestId.isEmpty)
                    // Header and body requestId must match
                    let headerId = response.headers[HTTPField.Name.xRequestId] ?? ""
                    #expect(env.requestId == headerId)
                case .alreadyExists:
                    #expect(response.status == .conflict)
                    #expect(env.error == "conflict")
                    #expect(env.code == "E_409")
                case .notSupported:
                    #expect(response.status == .notImplemented)
                    #expect(env.error == "not_supported")
                    #expect(env.code == "E_501")
                case .invalidState:
                    #expect(response.status == .conflict)
                    #expect(env.error == "invalid_state")
                    #expect(env.code == "E_409")
                case .backendFailure(let msg):
                    #expect(response.status == .internalServerError)
                    #expect(env.error == "internal_error")
                    #expect(env.code == "E_500")
                    // Must NOT leak backend internals
                    #expect(!env.message.contains(msg))
                default:
                    #expect(response.status == .internalServerError)
                }
            }
        }
    }

    @Test("ErrorMappingMiddleware converts .notFound to 404 envelope")
    func mappingNotFound() async throws {
        try await makeErrorApp(throwing: RuntimeError.notFound(id: "abc"))
    }

    @Test("ErrorMappingMiddleware converts .alreadyExists to 409 conflict envelope")
    func mappingAlreadyExists() async throws {
        try await makeErrorApp(throwing: RuntimeError.alreadyExists(id: "dup"))
    }

    @Test("ErrorMappingMiddleware converts .notSupported to 501 envelope")
    func mappingNotSupported() async throws {
        try await makeErrorApp(throwing: RuntimeError.notSupported(operation: "foo", conformer: "bar"))
    }

    @Test("ErrorMappingMiddleware converts .invalidState to 409 invalid_state envelope")
    func mappingInvalidState() async throws {
        try await makeErrorApp(
            throwing: RuntimeError.invalidState(id: "c1", expected: .created, actual: .running)
        )
    }

    @Test("ErrorMappingMiddleware converts .backendFailure to 500 without leaking message")
    func mappingBackendFailure() async throws {
        try await makeErrorApp(throwing: RuntimeError.backendFailure(message: "XPC connection died"))
    }

    @Test("X-Request-Id in header matches requestId field in error envelope body")
    func requestIdMatchesEnvelopeField() async throws {
        try await makeErrorApp(throwing: RuntimeError.notFound(id: "x"))
    }
}
