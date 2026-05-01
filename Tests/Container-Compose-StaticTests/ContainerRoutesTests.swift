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

@Suite("Container REST routes - GET /containers + inspect")
struct ContainerRoutesTests {

    @Test("GET /containers returns empty array when registry empty")
    func containersReturnsEmptyArray() async throws {
        let router = Router()
        ContainerRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime(stubbedContainers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers", method: .get) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode([APIContainerSummary].self, from: response)
                    #expect(body.isEmpty)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.list])
    }

    @Test("GET /containers maps RuntimeContainer to APIContainerSummary")
    func containersMapsRuntimeContainerToSummary() async throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let container = RuntimeContainer(
            id: "abc",
            imageReference: "nginx:1.25",
            status: .running,
            publishedPorts: [
                RuntimePublishedPort(
                    hostAddress: "127.0.0.1",
                    hostPort: 8080,
                    containerPort: 80,
                    proto: .tcp
                )
            ],
            createdAt: createdAt,
            startedAt: startedAt,
            lastExitCode: nil
        )
        let response = try await Self.getContainerSummaries(uri: "/containers", containers: [container])

        #expect(response.count == 1)
        #expect(response[0].id == "abc")
        #expect(response[0].names == ["/abc"])
        #expect(response[0].image == "nginx:1.25")
        #expect(response[0].state == "running")
        #expect(response[0].status.hasPrefix("Up "))
        #expect(response[0].createdAt == createdAt)
        #expect(response[0].startedAt == startedAt)
        #expect(response[0].ports == [
            APIPortMapping(privatePort: 80, publicPort: 8080, proto: "tcp", ip: "127.0.0.1")
        ])
        #expect(response[0].labels.isEmpty)
    }

    @Test("GET /containers?status=running filters by status")
    func containersFiltersByStatus() async throws {
        let response = try await Self.getContainerSummaries(
            uri: "/containers?status=running",
            containers: [
                RuntimeContainer(id: "running-one", imageReference: "alpine", status: .running),
                RuntimeContainer(id: "exited-one", imageReference: "alpine", status: .exited)
            ]
        )

        #expect(response.map { $0.id } == ["running-one"])
    }

    @Test("GET /containers?name=foo filters by name prefix")
    func containersFiltersByNamePrefix() async throws {
        let response = try await Self.getContainerSummaries(
            uri: "/containers?name=foo",
            containers: [
                RuntimeContainer(id: "foo-web", imageReference: "nginx", status: .running),
                RuntimeContainer(id: "bar-web", imageReference: "nginx", status: .running)
            ]
        )

        #expect(response.map { $0.id } == ["foo-web"])
    }

    @Test("GET /containers?status=running&name=foo applies AND semantics")
    func containersFiltersByStatusAndNamePrefix() async throws {
        let response = try await Self.getContainerSummaries(
            uri: "/containers?status=running&name=foo",
            containers: [
                RuntimeContainer(id: "foo-running", imageReference: "nginx", status: .running),
                RuntimeContainer(id: "foo-exited", imageReference: "nginx", status: .exited),
                RuntimeContainer(id: "bar-running", imageReference: "nginx", status: .running)
            ]
        )

        #expect(response.map { $0.id } == ["foo-running"])
    }

    @Test("GET /containers/abc returns 200 with APIContainerInspect when present")
    func inspectReturnsPresentContainer() async throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_001)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_101)
        let container = RuntimeContainer(
            id: "abc",
            imageReference: "redis:7",
            status: .running,
            publishedPorts: [
                RuntimePublishedPort(
                    hostAddress: "0.0.0.0",
                    hostPort: 6379,
                    containerPort: 6379,
                    proto: .tcp
                )
            ],
            createdAt: createdAt,
            startedAt: startedAt,
            lastExitCode: nil
        )
        let router = Router()
        ContainerRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime(stubbedContainers: [container])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/abc", method: .get) { response in
                    #expect(response.status == .ok)
                    let body = try Self.decode(APIContainerInspect.self, from: response)
                    #expect(body.id == "abc")
                    #expect(body.created == createdAt)
                    #expect(body.name == "abc")
                    #expect(body.image == "redis:7")
                    #expect(body.state.status == "running")
                    #expect(body.state.running)
                    #expect(body.state.exitCode == nil)
                    #expect(body.state.startedAt == startedAt)
                    #expect(body.state.finishedAt == nil)
                    #expect(body.state.health == nil)
                    #expect(body.config.hostname.isEmpty)
                    #expect(body.config.env.isEmpty)
                    #expect(body.config.cmd.isEmpty)
                    #expect(body.config.workingDir.isEmpty)
                    #expect(body.config.labels.isEmpty)
                    #expect(body.networkSettings.ipAddress == nil)
                    #expect(body.networkSettings.ports == [
                        APIPortMapping(privatePort: 6379, publicPort: 6379, proto: "tcp", ip: "0.0.0.0")
                    ])
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.get(id: "abc")])
    }

    @Test("GET /containers/missing returns 404 with APIErrorResponse {\"message\": \"No such container: missing\"}")
    func inspectMissingReturns404() async throws {
        let router = Router()
        ContainerRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime(stubbedContainers: [])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/containers/missing", method: .get) { response in
                    #expect(response.status == .notFound)
                    let body = try Self.decode(APIErrorResponse.self, from: response)
                    #expect(body.message == "No such container: missing")
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.get(id: "missing")])
    }

    private static func getContainerSummaries(
        uri: String,
        containers: [RuntimeContainer]
    ) async throws -> [APIContainerSummary] {
        let router = Router()
        ContainerRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime(stubbedContainers: containers)

        return try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: uri, method: .get) { response in
                    #expect(response.status == .ok)
                    return try Self.decode([APIContainerSummary].self, from: response)
                }
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
        let data = Data(String(buffer: response.body).utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
