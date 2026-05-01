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

@Suite("Container REST routes - GET /projects + services")
struct ProjectRoutesTests {
    @Test("GET /projects returns empty array when no containers")
    func projects_empty() async throws {
        let app = Self.app()

        try await RuntimeEnvironment.$current.withValue(RecordingRuntime()) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects", method: .get) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode([APIProjectSummary].self, from: response)
                    #expect(body.isEmpty)
                }
            }
        }
    }

    @Test("GET /projects groups containers by project prefix")
    func projects_groupsByPrefix() async throws {
        let created = Date(timeIntervalSince1970: 100)
        let earlier = Date(timeIntervalSince1970: 50)
        let runtime = RecordingRuntime(stubbedContainers: [
            Self.container(id: "alpha-web", status: .running, createdAt: created),
            Self.container(id: "alpha-db", status: .stopped, createdAt: earlier),
            Self.container(id: "beta-api", status: .running, createdAt: created)
        ])
        let app = Self.app()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects", method: .get) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode([APIProjectSummary].self, from: response)
                    #expect(body.map(\.name) == ["alpha", "beta"])
                    #expect(body.first { $0.name == "alpha" }?.serviceCount == 2)
                    #expect(body.first { $0.name == "alpha" }?.runningCount == 1)
                    #expect(body.first { $0.name == "alpha" }?.createdAt == earlier)
                    #expect(body.first { $0.name == "beta" }?.serviceCount == 1)
                    #expect(body.first { $0.name == "beta" }?.runningCount == 1)
                }
            }
        }
    }

    @Test("GET /projects deduplicates replicas in serviceCount")
    func projects_deduplicatesReplicas() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            Self.container(id: "myproj-web-1"),
            Self.container(id: "myproj-web-2")
        ])
        let app = Self.app()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects", method: .get) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode([APIProjectSummary].self, from: response)
                    #expect(body.count == 1)
                    #expect(body.first?.name == "myproj")
                    #expect(body.first?.serviceCount == 1)
                }
            }
        }
    }

    @Test("GET /projects/myproj/services returns services for the project")
    func services_returnsProjectServices() async throws {
        let created = Date(timeIntervalSince1970: 100)
        let runtime = RecordingRuntime(stubbedContainers: [
            Self.container(
                id: "myproj-web",
                imageReference: "nginx:latest",
                status: .running,
                createdAt: created,
                ports: [RuntimePublishedPort(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, proto: .tcp)]
            ),
            Self.container(id: "myproj-db", imageReference: "postgres:16", status: .stopped, createdAt: created),
            Self.container(id: "other-api", imageReference: "alpine:3", status: .running, createdAt: created)
        ])
        let app = Self.app()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/myproj/services", method: .get) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode([APIServiceSummary].self, from: response)
                    #expect(body.map(\.name) == ["web", "db"])
                    #expect(body.allSatisfy { $0.project == "myproj" })
                    #expect(body.first?.container.id == "myproj-web")
                    #expect(body.first?.container.image == "nginx:latest")
                    #expect(body.first?.container.ports.first?.privatePort == 80)
                    #expect(body.first?.container.ports.first?.publicPort == 8080)
                    #expect(body.first?.container.ports.first?.proto == "tcp")
                    #expect(body.first?.container.ports.first?.ip == "127.0.0.1")
                }
            }
        }
    }

    @Test("GET /projects/missing/services returns 404 APIErrorResponse")
    func services_missingProject404() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            Self.container(id: "myproj-web")
        ])
        let app = Self.app()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects/missing/services", method: .get) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorEnvelope.self, from: response)
                    #expect(body.message == "No such project: missing")
                }
            }
        }
    }

    @Test("GET /projects excludes containers without a \"-\" in their id")
    func projects_excludesContainersWithoutDash() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            Self.container(id: "standalone"),
            Self.container(id: "myproj-web")
        ])
        let app = Self.app()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/projects", method: .get) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode([APIProjectSummary].self, from: response)
                    #expect(body.map(\.name) == ["myproj"])
                }
            }
        }
    }

    private static func app() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        ProjectRoutes.register(router: router)
        return Application(router: router)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from response: TestResponse
    ) throws -> T {
        let data = Data(String(buffer: response.body).utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func container(
        id: String,
        imageReference: String = "alpine:3",
        status: RuntimeContainerStatus = .running,
        createdAt: Date? = Date(timeIntervalSince1970: 100),
        ports: [RuntimePublishedPort] = []
    ) -> RuntimeContainer {
        RuntimeContainer(
            id: id,
            imageReference: imageReference,
            status: status,
            publishedPorts: ports,
            createdAt: createdAt
        )
    }
}
