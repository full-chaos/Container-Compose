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
import Logging
import ServiceLifecycle
import Testing
@testable import ContainerComposeCore

@Suite("ShutdownWatchdog (CHAOS-1423 follow-up)")
struct ShutdownWatchdogTests {

    // MARK: - Test helpers

    /// In-memory `LogHandler` that captures `.warning` and above so tests can
    /// assert what the watchdog actually emitted.
    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(level: Logger.Level, message: String, metadata: Logger.Metadata)] = []

        func append(level: Logger.Level, message: String, metadata: Logger.Metadata) {
            lock.lock()
            defer { lock.unlock() }
            entries.append((level, message, metadata))
        }

        func warnings() -> [(message: String, metadata: Logger.Metadata)] {
            lock.lock()
            defer { lock.unlock() }
            return entries
                .filter { $0.level == .warning }
                .map { ($0.message, $0.metadata) }
        }

        func makeHandler() -> LogHandler {
            CaptureHandler(capture: self)
        }
    }

    private struct CaptureHandler: LogHandler {
        let capture: LogCapture
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(
            level: Logger.Level,
            message: Logger.Message,
            metadata: Logger.Metadata?,
            source: String,
            file: String,
            function: String,
            line: UInt
        ) {
            capture.append(level: level, message: "\(message)", metadata: metadata ?? [:])
        }
    }

    /// Trivial `Service` whose `run()` body sleeps until cancelled. Used to
    /// pose as a wedged accept-loop for tracked-service tests.
    private struct ForeverSleepService: ServiceLifecycle.Service {
        func run() async throws {
            try await Task.sleep(for: .seconds(60 * 60 * 24))
        }
    }

    // MARK: - ServiceLivenessRegistry

    @Test("registry mark/unmark roundtrip")
    func registry_basicLifecycle() {
        let registry = ServiceLivenessRegistry()
        #expect(registry.snapshot().isEmpty)

        registry.markStarted("a")
        registry.markStarted("b")
        #expect(registry.snapshot() == ["a", "b"])

        registry.markStopped("a")
        #expect(registry.snapshot() == ["b"])

        registry.markStopped("b")
        #expect(registry.snapshot().isEmpty)
    }

    @Test("registry snapshot is sorted for deterministic logging")
    func registry_snapshotIsSorted() {
        let registry = ServiceLivenessRegistry()
        registry.markStarted("zeta")
        registry.markStarted("alpha")
        registry.markStarted("middle")
        #expect(registry.snapshot() == ["alpha", "middle", "zeta"])
    }

    @Test("registry tolerates concurrent mutation without crashing")
    func registry_concurrentSafe() async {
        let registry = ServiceLivenessRegistry()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let name = "svc-\(i)"
                    registry.markStarted(name)
                    registry.markStopped(name)
                }
            }
        }
        #expect(registry.snapshot().isEmpty)
    }

    // MARK: - ShutdownTrackedService

    @Test("tracked service registers during run and deregisters on normal exit")
    func tracked_normalExit() async throws {
        let registry = ServiceLivenessRegistry()

        // Service that asserts its own liveness mid-run.
        struct CheckingService: ServiceLifecycle.Service {
            let registry: ServiceLivenessRegistry
            let onMidRun: @Sendable () -> Void
            func run() async throws {
                onMidRun()
            }
        }

        let mid = LockBox<Bool>(initial: false)
        let inner = CheckingService(registry: registry) {
            // Inside run, our name should be in the registry.
            mid.set(registry.snapshot().contains("inner"))
        }
        let tracked = ShutdownTrackedService(name: "inner", registry: registry, wrapped: inner)

        try await tracked.run()

        #expect(mid.get() == true)
        #expect(registry.snapshot().isEmpty, "registry should be empty after run completes")
    }

    @Test("tracked service deregisters even when wrapped throws")
    func tracked_throwingExit() async {
        struct ThrowingService: ServiceLifecycle.Service {
            struct Boom: Error {}
            func run() async throws { throw Boom() }
        }
        let registry = ServiceLivenessRegistry()
        let tracked = ShutdownTrackedService(name: "boom", registry: registry, wrapped: ThrowingService())

        do {
            try await tracked.run()
            Issue.record("expected throw")
        } catch {
            // expected
        }
        #expect(registry.snapshot().isEmpty)
    }

    @Test("tracked service deregisters when wrapped throws CancellationError")
    func tracked_cancellationExit() async {
        let registry = ServiceLivenessRegistry()
        let tracked = ShutdownTrackedService(
            name: "sleeper",
            registry: registry,
            wrapped: ForeverSleepService()
        )

        let task = Task {
            try? await tracked.run()
        }
        // Give the task a moment to enter run().
        try? await Task.sleep(for: .milliseconds(20))
        #expect(registry.snapshot() == ["sleeper"])

        task.cancel()
        _ = await task.value
        #expect(registry.snapshot().isEmpty)
    }

    // MARK: - ShutdownWatchdogService

    @Test("watchdog logs shutdown_stalled when service still alive after threshold")
    func watchdog_logsWhenStuck() async throws {
        let registry = ServiceLivenessRegistry()
        registry.markStarted("hummingbird") // pose as a wedged service

        let capture = LogCapture()
        let logger = Logger(label: "test.watchdog") { _ in capture.makeHandler() }
        let watchdog = ShutdownWatchdogService(
            registry: registry,
            logger: logger,
            stallThreshold: .milliseconds(40)
        )

        // Run the watchdog in a child Task and cancel to trigger onCancel.
        let task = Task { try? await watchdog.run() }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.value

        // Wait past the stall threshold so the detached task can fire.
        try await Task.sleep(for: .milliseconds(120))

        let warnings = capture.warnings()
        #expect(warnings.contains { $0.message == "shutdown_stalled" },
                "expected a warning with message 'shutdown_stalled', got: \(warnings.map { $0.message })")

        // Verify the metadata names the wedged service.
        if let stalled = warnings.first(where: { $0.message == "shutdown_stalled" }) {
            let alive = stalled.metadata["alive_services"]
            if case .array(let arr) = alive {
                let names = arr.compactMap { value -> String? in
                    if case .string(let s) = value { return s } else { return nil }
                }
                #expect(names == ["hummingbird"])
            } else {
                Issue.record("alive_services metadata missing or wrong shape: \(String(describing: alive))")
            }
        }
    }

    @Test("watchdog stays silent when registry drains before threshold")
    func watchdog_silentWhenDrained() async throws {
        let registry = ServiceLivenessRegistry()
        registry.markStarted("hummingbird")

        let capture = LogCapture()
        let logger = Logger(label: "test.watchdog") { _ in capture.makeHandler() }
        let watchdog = ShutdownWatchdogService(
            registry: registry,
            logger: logger,
            stallThreshold: .milliseconds(80)
        )

        let task = Task { try? await watchdog.run() }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.value

        // Drain the registry BEFORE the stall threshold elapses.
        registry.markStopped("hummingbird")

        try await Task.sleep(for: .milliseconds(140))

        #expect(capture.warnings().isEmpty,
                "watchdog should not log when registry drains in time, got: \(capture.warnings().map { $0.message })")
    }

    @Test("spawnIfFirst is idempotent — graceful + cancel paths produce one log")
    func watchdog_idempotent() async throws {
        // Production race we're guarding against: SIGTERM is signaled,
        // `onGracefulShutdown` fires `spawnIfFirst()`, 10s of grace pass,
        // ServiceGroup escalates to cancellation, `onCancel` fires
        // `spawnIfFirst()` again — both inside a single `run()` invocation
        // on a single instance. Exactly one `Task.detached` must be spawned.
        let registry = ServiceLivenessRegistry()
        registry.markStarted("svc")

        let capture = LogCapture()
        let logger = Logger(label: "test.watchdog") { _ in capture.makeHandler() }
        let watchdog = ShutdownWatchdogService(
            registry: registry,
            logger: logger,
            stallThreshold: .milliseconds(40)
        )

        // Drive the race directly: simulate both shutdown paths firing
        // back-to-back on the same instance, then a third spurious call.
        watchdog.spawnIfFirst()
        watchdog.spawnIfFirst()
        watchdog.spawnIfFirst()
        #expect(watchdog.hasSpawned)

        // Wait past the stall threshold so the (single) detached task fires.
        try await Task.sleep(for: .milliseconds(120))

        let stalledLogs = capture.warnings().filter { $0.message == "shutdown_stalled" }
        #expect(stalledLogs.count == 1,
                "expected exactly one shutdown_stalled log, got \(stalledLogs.count)")
    }
}

// MARK: - LockBox

/// Tiny `Sendable` cell used to communicate between Service.run closures and
/// the test body across actor boundaries.
private final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(initial: T) { self.value = initial }

    func set(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
