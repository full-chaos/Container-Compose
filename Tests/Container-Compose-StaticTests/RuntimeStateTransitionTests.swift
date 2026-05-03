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
import TestHelpers

// MARK: - RuntimeStateTransitionTests

/// State-machine coverage for the `Runtime` protocol: verifies that the
/// `created → running → stopped` lifecycle produces correct states, events,
/// and errors across the in-memory `MockRuntime` conformer. Uses `MockRuntime`
/// exclusively so tests are backend-neutral and require no virtualization
/// entitlements or apple/container daemon.
@Suite("Runtime state transitions")
struct RuntimeStateTransitionTests {

    // MARK: - created → running transition

    @Test("created → running: start() advances status and sets startedAt")
    func createdToRunning_statusAndStartedAt() async throws {
        let runtime = MockRuntime()

        let created = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "nginx:1")
        )
        #expect(created.status == .created)
        #expect(created.startedAt == nil)

        try await runtime.start(id: "svc-1")

        let running = try await runtime.get(id: "svc-1")
        #expect(running.status == .running)
        #expect(running.startedAt != nil)
    }

    @Test("created → running: list() reflects running status after start()")
    func createdToRunning_listReflectsState() async throws {
        let runtime = MockRuntime()

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "redis:7")
        )
        try await runtime.start(id: "svc-1")

        let all = try await runtime.list(filters: .all)
        #expect(all.count == 1)
        #expect(all.first?.status == .running)

        let running = try await runtime.list(filters: RuntimeListFilters(status: [.running]))
        #expect(running.count == 1)

        let created = try await runtime.list(filters: RuntimeListFilters(status: [.created]))
        #expect(created.isEmpty)
    }

    @Test("created → running: events stream emits .created then .started in order")
    func createdToRunning_eventOrder() async throws {
        let runtime = MockRuntime()
        let eventStream = try await runtime.events()

        let collector = Task {
            var events: [RuntimeContainerEvent] = []
            for await event in eventStream {
                events.append(event)
                if events.count == 2 { break }
            }
            return events
        }

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )
        try await runtime.start(id: "svc-1")

        let events = await collector.value
        #expect(events.count == 2)
        guard events.count == 2 else { return }

        guard case .created(let createdID, _) = events[0] else {
            Issue.record("expected .created, got \(events[0])")
            return
        }
        guard case .started(let startedID, _) = events[1] else {
            Issue.record("expected .started, got \(events[1])")
            return
        }
        #expect(createdID == "svc-1")
        #expect(startedID == "svc-1")
    }

    // MARK: - running → stopped transition + cleanup

    @Test("running → stopped: stop() advances status and sets lastExitCode")
    func runningToStopped_statusAndExitCode() async throws {
        let runtime = MockRuntime()

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "postgres:16")
        )
        try await runtime.start(id: "svc-1")
        try await runtime.stop(id: "svc-1", options: .default)

        let stopped = try await runtime.get(id: "svc-1")
        #expect(stopped.status == .stopped)
        #expect(stopped.lastExitCode == 0)
    }

    @Test("running → stopped: list() reports stopped status after stop()")
    func runningToStopped_listReflectsState() async throws {
        let runtime = MockRuntime()

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )
        try await runtime.start(id: "svc-1")
        try await runtime.stop(id: "svc-1", options: .default)

        let stopped = try await runtime.list(filters: RuntimeListFilters(status: [.stopped]))
        #expect(stopped.count == 1)

        let running = try await runtime.list(filters: RuntimeListFilters(status: [.running]))
        #expect(running.isEmpty)
    }

    @Test("running → stopped → removed: remove() cleans up state")
    func runningToStoppedToRemoved_cleanup() async throws {
        let runtime = MockRuntime()

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )
        try await runtime.start(id: "svc-1")
        try await runtime.stop(id: "svc-1", options: .default)
        try await runtime.remove(id: "svc-1", force: false)

        let listed = try await runtime.list(filters: .all)
        #expect(listed.isEmpty)

        await #expect(throws: RuntimeError.notFound(id: "svc-1")) {
            _ = try await runtime.get(id: "svc-1")
        }
    }

    @Test("running → removed with force: remove(force:true) removes running container")
    func runningForceRemove() async throws {
        let runtime = MockRuntime()

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )
        try await runtime.start(id: "svc-1")

        // Should not throw with force: true
        try await runtime.remove(id: "svc-1", force: true)

        let listed = try await runtime.list(filters: .all)
        #expect(listed.isEmpty)
    }

    @Test("stop() emits .stopped event with exitCode 0")
    func stopEmitsStoppedEvent() async throws {
        let runtime = MockRuntime()
        let eventStream = try await runtime.events()

        let collector = Task {
            var events: [RuntimeContainerEvent] = []
            for await event in eventStream {
                events.append(event)
                if events.count == 3 { break }
            }
            return events
        }

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "redis:7")
        )
        try await runtime.start(id: "svc-1")
        try await runtime.stop(id: "svc-1", options: .default)

        let events = await collector.value
        #expect(events.count == 3)
        guard events.count == 3 else { return }

        guard case .stopped(let id, let exitCode, _) = events[2] else {
            Issue.record("expected .stopped, got \(events[2])")
            return
        }
        #expect(id == "svc-1")
        #expect(exitCode == 0)
    }

    // MARK: - Error conditions

    @Test("create() throws .alreadyExists for duplicate id")
    func createDuplicate_throwsAlreadyExists() async throws {
        let runtime = MockRuntime()

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )

        await #expect(throws: RuntimeError.alreadyExists(id: "svc-1")) {
            _ = try await runtime.create(
                id: "svc-1",
                configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
            )
        }
    }

    @Test("get() throws .notFound for missing container")
    func getMissing_throwsNotFound() async throws {
        let runtime = MockRuntime()

        await #expect(throws: RuntimeError.notFound(id: "ghost")) {
            _ = try await runtime.get(id: "ghost")
        }
    }

    @Test("start() on missing container throws .notFound")
    func startMissing_throwsNotFound() async throws {
        let runtime = MockRuntime()

        await #expect(throws: RuntimeError.notFound(id: "ghost")) {
            try await runtime.start(id: "ghost")
        }
    }

    @Test("start() on running container throws .invalidState")
    func startRunning_throwsInvalidState() async throws {
        let runtime = MockRuntime()

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )
        try await runtime.start(id: "svc-1")

        await #expect(throws: RuntimeError.invalidState(
            id: "svc-1",
            expected: .created,
            actual: .running
        )) {
            try await runtime.start(id: "svc-1")
        }
    }

    @Test("stop() on missing container throws .notFound")
    func stopMissing_throwsNotFound() async throws {
        let runtime = MockRuntime()

        await #expect(throws: RuntimeError.notFound(id: "ghost")) {
            try await runtime.stop(id: "ghost", options: .default)
        }
    }

    @Test("stop() on created (not running) container throws .invalidState")
    func stopCreated_throwsInvalidState() async throws {
        let runtime = MockRuntime()

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )

        await #expect(throws: RuntimeError.invalidState(
            id: "svc-1",
            expected: .running,
            actual: .created
        )) {
            try await runtime.stop(id: "svc-1", options: .default)
        }
    }

    @Test("remove() on running container without force throws .invalidState")
    func removeRunningWithoutForce_throwsInvalidState() async throws {
        let runtime = MockRuntime()

        _ = try await runtime.create(
            id: "svc-1",
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )
        try await runtime.start(id: "svc-1")

        await #expect(throws: RuntimeError.invalidState(
            id: "svc-1",
            expected: .stopped,
            actual: .running
        )) {
            try await runtime.remove(id: "svc-1", force: false)
        }
    }

    @Test("remove() on missing container throws .notFound")
    func removeMissing_throwsNotFound() async throws {
        let runtime = MockRuntime()

        await #expect(throws: RuntimeError.notFound(id: "ghost")) {
            try await runtime.remove(id: "ghost", force: false)
        }
    }

    @Test("logs() on missing container throws .notFound")
    func logsMissing_throwsNotFound() async throws {
        let runtime = MockRuntime()

        await #expect(throws: RuntimeError.notFound(id: "ghost")) {
            _ = try await runtime.logs(id: "ghost", options: .default)
        }
    }

    @Test("statistics() on missing container throws .notFound")
    func statisticsMissing_throwsNotFound() async throws {
        let runtime = MockRuntime()

        await #expect(throws: RuntimeError.notFound(id: "ghost")) {
            _ = try await runtime.statistics(for: "ghost")
        }
    }

    // MARK: - Concurrent operations

    @Test("concurrent creates with distinct ids do not deadlock or corrupt state")
    func concurrentCreatesDistinctIds() async throws {
        let runtime = MockRuntime()
        let ids = (1...10).map { "svc-\($0)" }

        try await withThrowingTaskGroup(of: RuntimeContainer.self) { group in
            for id in ids {
                group.addTask {
                    try await runtime.create(
                        id: id,
                        configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
                    )
                }
            }
            var created: [RuntimeContainer] = []
            for try await container in group {
                created.append(container)
            }
            #expect(created.count == ids.count)
        }

        let listed = try await runtime.list(filters: .all)
        #expect(listed.count == ids.count)
        let listedIDs = Set(listed.map(\.id))
        #expect(listedIDs == Set(ids))
    }

    @Test("concurrent start/stop cycles on distinct containers do not corrupt state")
    func concurrentLifecycleDistinctContainers() async throws {
        let runtime = MockRuntime()
        let ids = (1...5).map { "svc-\($0)" }

        // Pre-create all containers
        for id in ids {
            _ = try await runtime.create(
                id: id,
                configuration: RuntimeCreateConfiguration(imageReference: "nginx:1")
            )
        }

        // Concurrently start all
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { try await runtime.start(id: id) }
            }
            try await group.waitForAll()
        }

        let running = try await runtime.list(filters: RuntimeListFilters(status: [.running]))
        #expect(running.count == ids.count)

        // Concurrently stop all
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { try await runtime.stop(id: id, options: .default) }
            }
            try await group.waitForAll()
        }

        let stopped = try await runtime.list(filters: RuntimeListFilters(status: [.stopped]))
        #expect(stopped.count == ids.count)
    }

    @Test("concurrent duplicate creates: exactly one succeeds, rest throw .alreadyExists")
    func concurrentDuplicateCreates_exactlyOneSucceeds() async throws {
        let runtime = MockRuntime()
        let concurrency = 5

        var successes = 0
        var alreadyExistsCount = 0
        var unexpectedErrors: [Error] = []

        await withTaskGroup(of: Result<RuntimeContainer, Error>.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    do {
                        let c = try await runtime.create(
                            id: "shared-svc",
                            configuration: RuntimeCreateConfiguration(imageReference: "redis:7")
                        )
                        return .success(c)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success:
                    successes += 1
                case .failure(let error as RuntimeError):
                    if case .alreadyExists = error {
                        alreadyExistsCount += 1
                    } else {
                        unexpectedErrors.append(error)
                    }
                case .failure(let error):
                    unexpectedErrors.append(error)
                }
            }
        }

        #expect(successes == 1, "exactly one create should succeed")
        #expect(alreadyExistsCount == concurrency - 1, "all other creates should throw .alreadyExists")
        #expect(unexpectedErrors.isEmpty, "no unexpected errors")
    }
}
