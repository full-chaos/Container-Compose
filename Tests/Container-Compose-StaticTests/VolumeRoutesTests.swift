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

@Suite("Volume routes — GET/POST/DELETE /volumes")
struct VolumeRoutesTests {

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

    // MARK: - GET /volumes

    @Test("GET /volumes returns empty list when no volumes")
    func getVolumesEmpty() async throws {
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/volumes", method: .get) { response in
                    #expect(response.status == .ok)
                    let resp = try Self.decode(APIVolumeListResponse.self, from: response)
                    #expect(resp.volumes.isEmpty)
                }
            }
        }
    }

    @Test("GET /volumes returns all volumes as summaries")
    func getVolumesList() async throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(volumes: [
            RuntimeVolume(name: "data-vol", driver: "local", labels: ["project": "app"], createdAt: createdAt),
            RuntimeVolume(name: "cache-vol", driver: "local", labels: [:], createdAt: nil)
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/volumes", method: .get) { response in
                    #expect(response.status == .ok)
                    let resp = try Self.decode(APIVolumeListResponse.self, from: response)
                    #expect(resp.volumes.count == 2)
                    let names = Set(resp.volumes.map { $0.name })
                    #expect(names == Set(["data-vol", "cache-vol"]))
                    let dataVol = resp.volumes.first { $0.name == "data-vol" }
                    #expect(dataVol?.driver == "local")
                    #expect(dataVol?.labels == ["project": "app"])
                }
            }
        }
    }

    @Test("GET /volumes records listVolumes call")
    func getVolumesRecorded() async throws {
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/volumes", method: .get) { response in
                    #expect(response.status == .ok)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.listVolumes])
    }

    // MARK: - POST /volumes

    @Test("POST /volumes returns 201 with volume summary on success")
    func postVolumeCreates() async throws {
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateVolumeRequest(name: "new-vol", driver: "local"))
                try await client.execute(
                    uri: "/volumes",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                    let vol = try Self.decode(APIVolumeSummary.self, from: response)
                    #expect(vol.name == "new-vol")
                    #expect(vol.driver == "local")
                }
            }
        }

        let volumes = await runtime.volumesSnapshot()
        #expect(volumes.contains(where: { $0.name == "new-vol" }))
    }

    @Test("POST /volumes uses local as default driver")
    func postVolumeDefaultDriver() async throws {
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateVolumeRequest(name: "localvol"))
                try await client.execute(
                    uri: "/volumes",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                    let vol = try Self.decode(APIVolumeSummary.self, from: response)
                    #expect(vol.driver == "local")
                }
            }
        }
    }

    @Test("POST /volumes propagates labels")
    func postVolumeLabels() async throws {
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateVolumeRequest(
                    name: "labeled-vol",
                    labels: ["env": "prod", "tier": "data"]
                ))
                try await client.execute(
                    uri: "/volumes",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }

        let vol = await runtime.volumesSnapshot().first { $0.name == "labeled-vol" }
        #expect(vol?.labels == ["env": "prod", "tier": "data"])
    }

    @Test("POST /volumes returns 409 when volume already exists")
    func postVolumeConflict() async throws {
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(volumes: [
            RuntimeVolume(name: "existing-vol")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateVolumeRequest(name: "existing-vol"))
                try await client.execute(
                    uri: "/volumes",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .conflict)
                    let err = try Self.decode(APIErrorResponse.self, from: response)
                    #expect(err.message.contains("existing-vol"))
                }
            }
        }
    }

    @Test("POST /volumes records createVolume call")
    func postVolumeRecorded() async throws {
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                let body = try Self.encode(APICreateVolumeRequest(name: "rec-vol"))
                try await client.execute(
                    uri: "/volumes",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.createVolume(name: "rec-vol")])
    }

    // MARK: - DELETE /volumes/{name}

    @Test("DELETE /volumes/{name} returns 204 on success")
    func deleteVolumeSuccess() async throws {
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime(volumes: [
            RuntimeVolume(name: "to-delete")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/volumes/to-delete", method: .delete) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        let volumes = await runtime.volumesSnapshot()
        #expect(!volumes.contains(where: { $0.name == "to-delete" }))
    }

    @Test("DELETE /volumes/{name} returns 404 for unknown name")
    func deleteVolumeNotFound() async throws {
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/volumes/ghost-vol", method: .delete) { response in
                    #expect(response.status == .notFound)
                    let err = try Self.decode(APIErrorResponse.self, from: response)
                    #expect(err.message.contains("ghost-vol"))
                }
            }
        }
    }

    @Test("DELETE /volumes/{name} records removeVolume call")
    func deleteVolumeRecorded() async throws {
        let router = Router()
        VolumeRoutes.register(router: router)
        let app = Application(router: router)
        let runtime = RecordingRuntime(stubbedVolumes: [
            RuntimeVolume(name: "recorded-vol")
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/volumes/recorded-vol", method: .delete) { response in
                    #expect(response.status == .noContent)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.removeVolume(name: "recorded-vol")])
    }
}
