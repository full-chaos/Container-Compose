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

#if os(macOS)

import Foundation
import Testing
@testable import ContainerComposeCore

@Suite("AppleContainerizationRuntime skeleton lifecycle")
struct AppleContainerizationRuntimeTests {

    private static func temporaryStoragePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "container-compose-tests")
            .appending(path: UUID().uuidString)
            .appending(path: "registry.json")
            .path
    }

    private static func cleanup(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("create() registers in registry and emits .created event")
    func createEmitsEvent() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        let stream = try await runtime.events()
        async let firstEvent: RuntimeContainerEvent? = {
            for await event in stream {
                return event
            }
            return nil
        }()

        let container = try await runtime.create(
            id: "demo-svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )
        #expect(container.id == "demo-svc-1")
        #expect(container.status == .created)

        let listed = try await runtime.list(filters: .all)
        #expect(listed.count == 1)
        #expect(listed.first?.id == "demo-svc-1")

        let event = await firstEvent
        guard case .created(let id, _) = event else {
            Issue.record("expected .created event, got \(String(describing: event))")
            return
        }
        #expect(id == "demo-svc-1")
    }

    @Test("create() rejects duplicate id")
    func duplicateCreate() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        _ = try await runtime.create(
            id: "demo-svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )

        await #expect(throws: RuntimeError.self) {
            _ = try await runtime.create(
                id: "demo-svc-1",
                configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
            )
        }
    }

    @Test("start → stop transitions registry state and emits events")
    func startStopLifecycle() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        let id = "demo-svc-1"
        _ = try await runtime.create(
            id: id,
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )

        try await runtime.start(id: id)
        let running = try await runtime.get(id: id)
        #expect(running.status == .running)

        try await runtime.stop(id: id, options: .default)
        let stopped = try await runtime.get(id: id)
        #expect(stopped.status == .exited)
        #expect(stopped.lastExitCode == 0)
    }

    @Test("logs() seeds stream from per-container ring buffer")
    func logsSeedsFromRingBuffer() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        let id = "demo-svc-1"
        _ = try await runtime.create(
            id: id,
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )

        guard let stdout = await runtime._testStdoutBuffer(for: id) else {
            Issue.record("expected stdout buffer for \(id)")
            return
        }
        try stdout.write(Data("hello".utf8))
        try stdout.write(Data("world".utf8))

        var collected: [RuntimeLogFrame] = []
        let stream = try await runtime.logs(id: id, options: .default)
        for await frame in stream {
            collected.append(frame)
        }
        #expect(collected.count == 2)
        #expect(String(data: collected[0].data, encoding: .utf8) == "hello")
        #expect(String(data: collected[1].data, encoding: .utf8) == "world")
    }

    // MARK: - CHAOS-1424 PR1 — lifecycle storage scaffold

    @Test("CHAOS-1424 PR1 — _testLifecycleMap is empty for fresh runtime")
    func phase2_lifecycleMap_emptyForFreshRuntime() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        #expect(await runtime._testLifecycleMap(for: "anything") == false)
    }

    @Test("CHAOS-1424 PR1 — _testLifecycleMap stays empty after registry-only create()")
    func phase2_lifecycleMap_emptyAfterRegistryOnlyCreate() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        _ = try await runtime.create(
            id: "demo-svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )

        // PR1 ships the map empty — PR2 will populate via ContainerManager.create.
        // This test guards the registry-only-fallback AC from regressing while
        // the lifecycle wiring lands in PR2.
        #expect(await runtime._testLifecycleMap(for: "demo-svc-1") == false)
    }

    @Test("remove() rejects running container without force")
    func removeRunningRequiresForce() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        let id = "demo-svc-1"
        _ = try await runtime.create(
            id: id,
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )
        try await runtime.start(id: id)

        await #expect(throws: RuntimeError.self) {
            try await runtime.remove(id: id, force: false)
        }

        try await runtime.remove(id: id, force: true)
        let listed = try await runtime.list(filters: .all)
        #expect(listed.isEmpty)
    }
}

#endif
