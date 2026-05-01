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
import Testing
@testable import ContainerComposeCore

@Suite("ContainerRegistry behavior + persistence")
struct ContainerRegistryTests {

    private static func temporaryStoragePath() -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "container-compose-tests")
            .appending(path: UUID().uuidString)
            .appending(path: "registry.json")
            .path
        return tmp
    }

    @Test("Registry starts empty when storage file is absent")
    func emptyOnFirstLoad() async throws {
        let path = Self.temporaryStoragePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let records = await registry.list()
        #expect(records.isEmpty)
    }

    @Test("Registry round-trips a record across instances")
    func roundTripPersistence() async throws {
        let path = Self.temporaryStoragePath()
        defer {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: dir)
        }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = RuntimeContainerRecord(
            id: "demo-web-1",
            imageReference: "nginx:1",
            createdAt: createdAt,
            state: .created,
            publishedPorts: [
                RuntimePublishedPort(
                    hostAddress: "0.0.0.0",
                    hostPort: 8080,
                    containerPort: 80,
                    proto: .tcp
                )
            ]
        )

        do {
            let registry = try await ContainerRegistry(storagePath: path)
            try await registry.register(record)
        }

        let registry2 = try await ContainerRegistry(storagePath: path)
        let loaded = await registry2.list()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == "demo-web-1")
        #expect(loaded.first?.imageReference == "nginx:1")
        #expect(loaded.first?.publishedPorts.first?.hostPort == 8080)
    }

    @Test("Registry updates state and exit status")
    func stateTransitions() async throws {
        let path = Self.temporaryStoragePath()
        defer {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: dir)
        }
        let registry = try await ContainerRegistry(storagePath: path)
        let createdAt = Date()
        try await registry.register(RuntimeContainerRecord(
            id: "demo-svc-1",
            imageReference: "alpine:3",
            createdAt: createdAt
        ))

        let startedAt = createdAt.addingTimeInterval(1)
        try await registry.updateState(id: "demo-svc-1", state: .running, startedAt: startedAt)
        let running = await registry.get(id: "demo-svc-1")
        #expect(running?.state == .running)
        #expect(running?.startedAt == startedAt)

        let exitedAt = createdAt.addingTimeInterval(2)
        try await registry.recordExit(
            id: "demo-svc-1",
            exitStatus: RuntimeExitStatus(exitCode: 0, exitedAt: exitedAt)
        )
        let exited = await registry.get(id: "demo-svc-1")
        #expect(exited?.state == .exited)
        #expect(exited?.exitStatus?.exitCode == 0)
        #expect(exited?.exitStatus?.exitedAt == exitedAt)
    }

    @Test("Registry remove deletes the record")
    func removeRecord() async throws {
        let path = Self.temporaryStoragePath()
        defer {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: dir)
        }
        let registry = try await ContainerRegistry(storagePath: path)
        try await registry.register(RuntimeContainerRecord(
            id: "demo-svc-1",
            imageReference: "alpine:3",
            createdAt: Date()
        ))
        try await registry.remove(id: "demo-svc-1")
        let records = await registry.list()
        #expect(records.isEmpty)
    }

    @Test("RuntimeContainerRecord.toRuntimeContainer projects exit code")
    func recordProjection() {
        let record = RuntimeContainerRecord(
            id: "demo",
            imageReference: "alpine:3",
            createdAt: Date(),
            state: .exited,
            exitStatus: RuntimeExitStatus(exitCode: 137, exitedAt: Date())
        )
        let projected = record.toRuntimeContainer()
        #expect(projected.lastExitCode == 137)
        #expect(projected.status == .exited)
    }
}
