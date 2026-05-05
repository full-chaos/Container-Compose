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

/// CHAOS-1426 — POST /projects/{name} compose YAML ingestion.
///
/// All cases use a fresh `ProjectRegistry()` per test (overriding the
/// task-local default) so state doesn't leak across the suite.
@Suite("Project ingest route — POST /projects/{name}")
struct ProjectIngestRouteTests {

    private static let validYAML = """
    services:
      web:
        image: nginx:1.27
      db:
        image: postgres:16
    """

    private static let validYAMLDifferent = """
    services:
      web:
        image: nginx:1.28
    """

    private static let yamlWithIncludes = """
    include:
      - common.yml
    services:
      web:
        image: nginx:1.27
    """

    private static let yamlNoServices = """
    services: {}
    """

    private static let malformedYAML = """
    services:
      web:
        image: nginx:1.27
        ports:
          - "not a port: yet
    """

    private static func makeRouter() -> Router<BasicRequestContext> {
        let router = Router()
        ProjectLifecycleRoutes.register(router: router)
        ProjectRoutes.register(router: router)
        return router
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
        let data = Data(String(buffer: response.body).utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    // MARK: - Happy paths

    @Test("first valid YAML upload returns 201 + APIProjectIngestResponse")
    func firstUploadReturns201() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/yaml"],
                    body: ByteBuffer(string: Self.validYAML)
                ) { response in
                    #expect(response.status == .created)
                    let body = try Self.decode(APIProjectIngestResponse.self, from: response)
                    #expect(body.name == "myapp")
                    #expect(body.serviceCount == 2)
                    #expect(body.services == ["db", "web"])
                    #expect(body.outcome == "created")
                }
            }
        }
    }

    @Test("idempotent re-upload of byte-identical YAML returns 200 + outcome=unchanged")
    func idempotentReuploadReturns200() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await app.test(.router) { client in
                _ = try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/yaml"],
                    body: ByteBuffer(string: Self.validYAML)
                ) { _ in }

                try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/yaml"],
                    body: ByteBuffer(string: Self.validYAML)
                ) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode(APIProjectIngestResponse.self, from: response)
                    #expect(body.outcome == "unchanged")
                }
            }
        }
    }

    @Test("re-upload with different content returns 409 conflict")
    func conflictingReuploadReturns409() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await app.test(.router) { client in
                _ = try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/yaml"],
                    body: ByteBuffer(string: Self.validYAML)
                ) { _ in }

                try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/yaml"],
                    body: ByteBuffer(string: Self.validYAMLDifferent)
                ) { response in
                    #expect(response.status == .conflict)
                }
            }
        }
    }

    @Test("YAML containing include: returns 400")
    func includesRejectedWith400() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/yaml"],
                    body: ByteBuffer(string: Self.yamlWithIncludes)
                ) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
    }

    @Test("YAML with empty services map returns 400")
    func emptyServicesRejectedWith400() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/yaml"],
                    body: ByteBuffer(string: Self.yamlNoServices)
                ) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
    }

    @Test("malformed YAML returns 400")
    func malformedYamlReturns400() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/yaml"],
                    body: ByteBuffer(string: Self.malformedYAML)
                ) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
    }

    @Test("empty body returns 400")
    func emptyBodyReturns400() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/yaml"],
                    body: ByteBuffer()
                ) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
    }

    @Test("non-YAML Content-Type returns 415")
    func wrongContentTypeReturns415() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: Self.validYAML)
                ) { response in
                    #expect(response.status == .unsupportedMediaType)
                }
            }
        }
    }

    @Test("YAML body with no Content-Type still accepted (curl --data-binary default)")
    func missingContentTypeAccepted() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    body: ByteBuffer(string: Self.validYAML)
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }
    }

    // MARK: - GET /projects/{name} after ingestion

    @Test("GET /projects/{name} returns ingested detail with source=ingested")
    func getReturnsIngestedDetail() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await app.test(.router) { client in
                _ = try await client.execute(
                    uri: "/projects/myapp",
                    method: .post,
                    headers: [.contentType: "application/yaml"],
                    body: ByteBuffer(string: Self.validYAML)
                ) { _ in }

                try await client.execute(uri: "/projects/myapp", method: .get) { response in
                    #expect(response.status == .ok)
                    let detail = try Self.decode(APIProjectDetail.self, from: response)
                    #expect(detail.name == "myapp")
                    #expect(detail.source == "ingested")
                    #expect(detail.services == ["db", "web"])
                    #expect(detail.serviceCount == 2)
                    #expect(detail.ingestedAt != nil)
                }
            }
        }
    }

    @Test("GET /projects/{name} falls back to synthesized view when not ingested")
    func getFallsBackToSynthesizedView() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()
        let runtime = MockRuntime(containers: [
            RuntimeContainer(
                id: "myapp-web",
                imageReference: "nginx:1",
                status: .running,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                startedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        ])

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await app.test(.router) { client in
                    try await client.execute(uri: "/projects/myapp", method: .get) { response in
                        #expect(response.status == .ok)
                        let detail = try Self.decode(APIProjectDetail.self, from: response)
                        #expect(detail.source == "synthesized")
                        #expect(detail.services == ["web"])
                        #expect(detail.ingestedAt == nil)
                    }
                }
            }
        }
    }

    @Test("GET /projects/{name} returns 404 when neither ingested nor synthesized")
    func getReturns404WhenUnknown() async throws {
        let app = Application(router: Self.makeRouter())
        let registry = ProjectRegistry()
        let runtime = MockRuntime(containers: [])

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await app.test(.router) { client in
                    try await client.execute(uri: "/projects/missing", method: .get) { response in
                        #expect(response.status == .notFound)
                    }
                }
            }
        }
    }
}

// MARK: - Direct orchestrator tests

@Suite("ProjectOrchestrator.ingest — unit tests")
struct ProjectIngestOrchestratorTests {

    @Test("ingest returns created outcome on first call")
    func firstIngestIsCreated() async throws {
        let registry = ProjectRegistry()
        let yaml = """
        services:
          web:
            image: nginx:1.27
        """
        let (response, outcome) = try await ProjectOrchestrator.ingest(
            projectName: "demo",
            yaml: Data(yaml.utf8),
            registry: registry
        )
        #expect(outcome == .created)
        #expect(response.name == "demo")
        #expect(response.outcome == "created")
        #expect(response.services == ["web"])
    }

    @Test("ingest of identical content returns unchanged")
    func reingestIdenticalIsUnchanged() async throws {
        let registry = ProjectRegistry()
        let yaml = "services:\n  web:\n    image: nginx:1\n"
        _ = try await ProjectOrchestrator.ingest(projectName: "demo", yaml: Data(yaml.utf8), registry: registry)
        let (_, outcome) = try await ProjectOrchestrator.ingest(projectName: "demo", yaml: Data(yaml.utf8), registry: registry)
        #expect(outcome == .unchanged)
    }

    @Test("ingest of different content throws projectAlreadyIngested")
    func reingestDifferentThrows() async throws {
        let registry = ProjectRegistry()
        let first = "services:\n  web:\n    image: nginx:1\n"
        let second = "services:\n  web:\n    image: nginx:2\n"
        _ = try await ProjectOrchestrator.ingest(projectName: "demo", yaml: Data(first.utf8), registry: registry)
        await #expect(throws: ProjectOrchestrator.OrchestratorError.self) {
            _ = try await ProjectOrchestrator.ingest(projectName: "demo", yaml: Data(second.utf8), registry: registry)
        }
    }

    @Test("ingest rejects YAML containing include directives")
    func includesRejected() async throws {
        let registry = ProjectRegistry()
        let yaml = "include:\n  - common.yml\nservices:\n  web:\n    image: nginx:1\n"
        await #expect(throws: ProjectOrchestrator.OrchestratorError.self) {
            _ = try await ProjectOrchestrator.ingest(projectName: "demo", yaml: Data(yaml.utf8), registry: registry)
        }
    }

    @Test("ingest rejects empty service map")
    func emptyServicesRejected() async throws {
        let registry = ProjectRegistry()
        let yaml = "services: {}\n"
        await #expect(throws: ProjectOrchestrator.OrchestratorError.self) {
            _ = try await ProjectOrchestrator.ingest(projectName: "demo", yaml: Data(yaml.utf8), registry: registry)
        }
    }

    @Test("ingest rejects malformed YAML")
    func malformedRejected() async throws {
        let registry = ProjectRegistry()
        let yaml = "services:\n  web:\n    image: nginx:1\n    ports:\n      - \"not a port: yet\n"
        await #expect(throws: ProjectOrchestrator.OrchestratorError.self) {
            _ = try await ProjectOrchestrator.ingest(projectName: "demo", yaml: Data(yaml.utf8), registry: registry)
        }
    }
}
