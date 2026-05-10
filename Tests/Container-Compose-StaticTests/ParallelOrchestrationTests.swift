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

import ArgumentParser
import Foundation
import Testing

@testable import ContainerComposeCore
import TestHelpers

// MARK: - Test support

/// Order-recording actor used by tests that need to verify happens-before
/// relationships between concurrent operations. `record` appends to an
/// internal array; `snapshot` returns the recorded order.
fileprivate actor OrderRecorder {
    private var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
    func snapshot() -> [String] { entries }
}

/// Concurrency tracker used to verify a fan-out helper respects its
/// concurrency cap and is achieving real parallelism. `enter` increments
/// `current` and tracks `peak`; `exit` decrements `current`.
fileprivate actor ConcurrencyMeter {
    private var current = 0
    private var peakValue = 0
    private var totalEntries = 0
    func enter() {
        current += 1
        totalEntries += 1
        peakValue = max(peakValue, current)
    }
    func exit() { current -= 1 }
    func peak() -> Int { peakValue }
    func currentInFlight() -> Int { current }
    func total() -> Int { totalEntries }
}


// MARK: - CHAOS-1503 parallelism-validation tests
//
// These tests target the CHAOS-1446 Phase 4C architecture:
//   - CHAOS-1504 two-phase orchestration (prepareImage Phase A + configServiceStart Phase B)
//   - CHAOS-1505 DependencyCoordinator-wired Phase B (event-driven depends_on waits)

@Suite("ParallelOrchestration")
struct ParallelOrchestrationTests {

    // MARK: - High-level scenarios
    // (Phase 2 entries below now run live; Phase 3 entries remain .disabled.)

    @Test("parallelPullsAchieveConcurrency — ComposePull driven through RecordingRunner")
    func parallelPullsAchieveConcurrency() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-test-pull-concurrency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 4-service fixture, all image-only — every body should hit the
        // RunCommandRunner seam so the recorder can observe peak concurrency.
        let yaml = """
        services:
          web:
            image: nginx:1
          db:
            image: postgres:16
          cache:
            image: redis:7
          proxy:
            image: traefik:3
        """
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)

        let recorder = RecordingRunner()
        let containerProvider = RecordingContainerClientProvider()

        try await RunnerEnvironment.$current.withValue(recorder) {
            try await ContainerClientEnvironment.$current.withValue(containerProvider) {
                var cmd = try ComposePull.parse(["-f", compose.path])
                try await cmd.run()
            }
        }

        let pulled = await recorder.swiftAPIArgvs(named: "ImagePull").compactMap(\.first)
        #expect(Set(pulled) == [
            "docker.io/library/nginx:1",
            "docker.io/library/postgres:16",
            "docker.io/library/redis:7",
            "docker.io/library/traefik:3",
        ], "every service must be pulled exactly once")

        // The CHAOS-1446 Phase 1 RecordingRunner.peakConcurrency() tracks
        // overlapping run() invocations under actor reentrancy. With Phase 2's
        // parallel fan-out + Task.yield() in run(), peak should rise above 1.
        let peak = await recorder.peakConcurrency()
        #expect(peak >= 2, "expected ComposePull to fan out; peakConcurrency was \(peak)")
    }

    // Deflake design (CHAOS-1446 reviewer follow-up + CHAOS-1508):
    // Asserts (1) only the failing body reaches `runMeter.enter()`, and
    // (2) at least one sibling observes cancellation. CHAOS-1508 replaced
    // the previous 5-second `Task.sleep` sibling pattern with
    // `Task.isCancelled` polling because under serial full-suite execution
    // the scheduler could be loaded enough by prior tests that the 5s
    // ceiling expired before cancellation propagated. The full rationale
    // is in the inline comment block below.
    @Test("parallelPullFailFastCancelsSiblings — first failure cancels in-flight bodies")
    func parallelPullFailFastCancelsSiblings() async throws {
        struct PullFailed: Error {}
        let runMeter = ConcurrencyMeter()

        // CHAOS-1508 v3 deflake (db-primer + cancellation-aware sleep):
        //
        // History:
        //   * Original (CHAOS-1446, limit=2, 5s sibling sleep): flaked under
        //     serial full-suite load when 5s expired before cancellation arrived.
        //   * v1 (#173, Task.yield polling): `Task.yield` is a soft yield, the
        //     executor could starve `db` so it never threw.
        //   * v1.5 (Task.sleep loop, limit=2): under serial load `db` got queued
        //     at the limit=2 semaphore while two siblings held the permits, so
        //     `db` never ran and the polling loop exhausted its budget.
        //   * v2 (#174, SiblingEntryGate primer): worked locally under both
        //     modes but hung CI's `--parallel` job for 30+ minutes — the gate's
        //     `withCheckedContinuation` deadlocks when CI's heavily-loaded
        //     cooperative executor delays scheduling all siblings.
        //
        // v3: copy the proven pattern from `fanOutCancelsOnFirstFailure`
        // (line ~890 in this file) which has run reliably across CI for the
        // whole CHAOS-1446 family of PRs.
        //   * `limit: items.count` (=4): every body gets a permit immediately.
        //     No semaphore queueing race.
        //   * `db` does a brief 50ms `Task.sleep` BEFORE throwing. With 4 bodies
        //     in flight under any mode, 50ms is more than enough for every
        //     sibling to reach its own `Task.sleep` waiting on cancellation.
        //   * Siblings sleep up to 30 seconds (10x the previous 5s ceiling) and
        //     catch the CancellationError that the group's `cancelAll` raises
        //     when `db` throws. No actor primer, no continuation, no possible
        //     deadlock — every wait is on a real timer that the executor will
        //     interrupt on cancellation.
        //
        // Deterministic invariants:
        //   * exactly one body (db) reaches `runMeter.enter()`.
        //   * at least one sibling observes the CancellationError and
        //     increments `cancelledMeter`.
        // If cancellation truly fails to propagate within 30s the sibling's
        // sleep returns normally and `cancelledMeter.total() == 0` triggers
        // the explicit assertion below — a real fail-fast regression.
        let cancelledMeter = ConcurrencyMeter()

        let items: [(key: String, value: String)] = [
            ("web", "nginx:1"),
            ("db", "postgres:16"),    // fails — must be in first `limit` items
            ("cache", "redis:7"),
            ("proxy", "traefik:3"),
        ]

        do {
            _ = try await runBoundedThrowingFanOut(items: items, limit: items.count) { key, _ in
                if key == "db" {
                    // 50ms primer: ensures every sibling has reached its
                    // Task.sleep below before db throws. Without this, db could
                    // throw and cancel siblings before they even enter their
                    // body (resulting in cancelledMeter == 0).
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    await runMeter.enter()
                    throw PullFailed()
                }

                // Sibling: sleep until cancellation interrupts. 30s ceiling is
                // generous — normal cancel propagation is sub-millisecond; we
                // only need the ceiling to bound runtime if propagation is truly
                // broken (in which case `cancelledMeter` will be 0 and the
                // assertion below fires loudly).
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch is CancellationError {
                    await cancelledMeter.enter()
                    throw CancellationError()
                }
                // Sleep completed without cancellation — do NOT increment any
                // meter. The `cancelledMeter >= 1` assertion will catch this
                // as a fail-fast regression.
            }
            Issue.record("Expected fan-out to throw")
        } catch let tagged as ServiceTaggedError {
            #expect(tagged.itemKey == "db", "thrown error must wrap the failing service name; got '\(tagged.itemKey)'")
        } catch {
            Issue.record("Expected ServiceTaggedError, got \(error)")
        }

        let total = await runMeter.total()
        #expect(total == 1, "only the failing service should run runMeter.enter(); got total=\(total) (any sibling reaching enter would indicate a regression introducing a fall-through path)")

        let cancelled = await cancelledMeter.total()
        #expect(cancelled >= 1, "expected at least one sibling to observe cancellation via Task.isCancelled polling; got cancelled=\(cancelled) (zero indicates fail-fast cancellation did not reach any sibling)")
    }

    @Test("parallelPullIgnoreFailuresCollectsBoth — collecting fan-out runs every body even on failures")
    func parallelPullIgnoreFailuresCollectsBoth() async throws {
        struct PullFailed: Error {
            let key: String
        }
        let runMeter = ConcurrencyMeter()

        let items: [(key: String, value: String)] = [
            ("web", "nginx:1"),
            ("db", "postgres:16"),
            ("cache", "redis:7"),
            ("proxy", "traefik:3"),
        ]
        let failingKeys: Set<String> = ["db", "cache"]

        let results: [String: Result<Void, Error>] = await runBoundedCollectingFanOut(
            items: items,
            limit: 4
        ) { key, _ in
            await runMeter.enter()
            try? await Task.sleep(nanoseconds: 10_000_000)
            await runMeter.exit()
            if failingKeys.contains(key) {
                return .failure(PullFailed(key: key))
            }
            return .success(())
        }

        // NO sibling cancellation — every body must have run.
        let total = await runMeter.total()
        #expect(total == items.count, "expected every body to run; total=\(total) of \(items.count)")

        // All 4 services must produce a result; failing ones MUST be .failure
        // and successful ones MUST be .success.
        #expect(results.count == items.count)
        for item in items {
            guard let outcome = results[item.key] else {
                Issue.record("missing result for service '\(item.key)'")
                continue
            }
            if failingKeys.contains(item.key) {
                if case .success = outcome {
                    Issue.record("expected failure for service '\(item.key)'")
                }
            } else {
                if case .failure(let err) = outcome {
                    Issue.record("expected success for service '\(item.key)', got \(err)")
                }
            }
        }

        // Both failing service names must be retrievable from the result map.
        let failedSet: Set<String> = Set(results.compactMap { (key, value) -> String? in
            if case .failure = value { return key }
            return nil
        })
        #expect(failedSet == failingKeys, "both failed services must be captured; got \(failedSet)")
    }

    @Test("parallelBuildFanOut — ComposeBuild driven through RecordingRunner")
    func parallelBuildFanOut() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-test-build-concurrency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 4-service fixture, all build-only. Each service uses an inline
        // dockerfile so we don't need on-disk Dockerfiles — buildService
        // writes the inline content to a UUID-named tempfile per call (see
        // Compose+BuildService.swift L71), which is concurrency-safe.
        let yaml = """
        services:
          web:
            build:
              context: .
              dockerfile_inline: |
                FROM nginx:1
          api:
            build:
              context: .
              dockerfile_inline: |
                FROM node:20
          worker:
            build:
              context: .
              dockerfile_inline: |
                FROM python:3.12
          jobs:
            build:
              context: .
              dockerfile_inline: |
                FROM ruby:3.3
        """
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)

        let recorder = RecordingRunner()
        let containerProvider = RecordingContainerClientProvider()

        try await RunnerEnvironment.$current.withValue(recorder) {
            try await ContainerClientEnvironment.$current.withValue(containerProvider) {
                var cmd = try ComposeBuild.parse(["-f", compose.path])
                try await cmd.run()
            }
        }

        // Every service must have triggered a BuildCommand invocation.
        let builtCount = await recorder.swiftAPIArgvs(named: "BuildCommand").count
        #expect(builtCount == 4, "every service must be built; got \(builtCount)")

        // Parallel fan-out should overlap multiple build invocations through
        // the RecordingRunner's Task.yield reentrancy point.
        let peak = await recorder.peakConcurrency()
        #expect(peak >= 2, "expected ComposeBuild to fan out; peakConcurrency was \(peak)")
    }

    // CHAOS-1446 Phase 3: parallel lifecycle commands. All four tests below
    // drive the real `compose start` / `compose stop` / `compose restart`
    // commands through `RecordingRunner` + `RecordingContainerClientProvider`
    // and assert deterministic DAG-respecting behavior. The provider is
    // primed via `stubRunningContainer(id:)` so per-service start/stop logic
    // executes (instead of early-returning at the "container not found"
    // guard) and the resulting `"container start"` argvs / `.stop` entries
    // become observable for happens-before assertions.

    @Test("parallelStartDAGOrder — dependent service starts AFTER its dependency")
    func parallelStartDAGOrder() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-test-start-dag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        services:
          db:
            image: postgres:16
          api:
            image: example/api:latest
            depends_on:
              - db
        """
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)

        let recorder = RecordingRunner()
        let provider = RecordingContainerClientProvider()
        // Default project name is the cwd basename; here the temp dir.
        let project = dir.lastPathComponent
        await provider.stubRunningContainer(id: "\(project)-db")
        await provider.stubRunningContainer(id: "\(project)-api")

        try await RunnerEnvironment.$current.withValue(recorder) {
            try await ContainerClientEnvironment.$current.withValue(provider) {
                var cmd = try ComposeStart.parse(["-f", compose.path])
                try await cmd.run()
            }
        }

        // The DAG forces api to wait for db's `.started` publication. Both
        // services issue `container start --detach <name>` through the runner.
        // Assert db's start argv comes BEFORE api's start argv.
        let dbBefore = await recorder.happensBefore(
            ["container", "start", "--detach", "\(project)-db"],
            ["container", "start", "--detach", "\(project)-api"]
        )
        #expect(dbBefore, "db's start must precede api's start under DAG ordering")
    }

    @Test("stopReversesDependencyOrder — dependent service stops BEFORE its dependency")
    func stopReversesDependencyOrder() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-test-stop-reverse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        services:
          db:
            image: postgres:16
          api:
            image: example/api:latest
            depends_on:
              - db
        """
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)

        let provider = RecordingContainerClientProvider()
        let project = dir.lastPathComponent
        await provider.stubRunningContainer(id: "\(project)-db")
        await provider.stubRunningContainer(id: "\(project)-api")

        try await ContainerClientEnvironment.$current.withValue(provider) {
            var cmd = try ComposeStop.parse(["-f", compose.path])
            try await cmd.run()
        }

        // Reverse-DAG: api (the dependent) must stop BEFORE db (the dependency).
        // ComposeStop calls `provider.stop(id:)` per service; we observe the
        // recorded `.stop` entries.
        let apiBeforeDb = await provider.happensBefore(
            { entry in if case .stop(let id) = entry, id == "\(project)-api" { return true } else { return false } },
            { entry in if case .stop(let id) = entry, id == "\(project)-db" { return true } else { return false } }
        )
        #expect(apiBeforeDb, "api's stop must precede db's stop under reverse-DAG ordering")
    }

    @Test("parallelStopDiamondFanOut — leaf services stop concurrently before their shared dependency")
    func parallelStopDiamondFanOut() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-test-stop-diamond-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Diamond fixture: `base` is depended on by BOTH `api` and `worker`.
        // Per CHAOS-1446 UltraBrain Critical #8, the reverse-DAG schedule
        // must let api AND worker stop in PARALLEL (peak >= 2) BEFORE base
        // stops at all.
        let yaml = """
        services:
          base:
            image: postgres:16
          api:
            image: example/api:latest
            depends_on:
              - base
          worker:
            image: example/worker:latest
            depends_on:
              - base
        """
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)

        let provider = RecordingContainerClientProvider()
        let project = dir.lastPathComponent
        await provider.stubRunningContainer(id: "\(project)-base")
        await provider.stubRunningContainer(id: "\(project)-api")
        await provider.stubRunningContainer(id: "\(project)-worker")

        try await ContainerClientEnvironment.$current.withValue(provider) {
            var cmd = try ComposeStop.parse(["-f", compose.path])
            try await cmd.run()
        }

        // Both leaves must stop BEFORE the shared dependency.
        let apiBeforeBase = await provider.happensBefore(
            { entry in if case .stop(let id) = entry, id == "\(project)-api" { return true } else { return false } },
            { entry in if case .stop(let id) = entry, id == "\(project)-base" { return true } else { return false } }
        )
        let workerBeforeBase = await provider.happensBefore(
            { entry in if case .stop(let id) = entry, id == "\(project)-worker" { return true } else { return false } },
            { entry in if case .stop(let id) = entry, id == "\(project)-base" { return true } else { return false } }
        )
        #expect(apiBeforeBase, "api (leaf) must stop before base (root)")
        #expect(workerBeforeBase, "worker (leaf) must stop before base (root)")

        // All three .stop entries must be present — nothing should be skipped.
        let stops = await provider.unorderedEntries(matching: { entry in
            if case .stop = entry { return true } else { return false }
        })
        #expect(stops.count == 3, "every service must stop exactly once; got \(stops.count)")

        // CHAOS-1446 UltraBrain Critical #8 mandate: the diamond fixture
        // exists specifically to catch silent serialization regressions — a
        // serial implementation `api → worker → base` would PASS the ordering
        // and count assertions above. Assert peak concurrency >= 2 to prove
        // the leaves actually FAN OUT in parallel before base. Loose bound
        // (>= 2, not == 2) avoids scheduler-timing flakes per the established
        // pattern. RecordingContainerClientProvider's stop(id:) tracks
        // inFlightStops + peakStopConcurrency under actor reentrancy
        // (Task.sleep 100µs pattern from Phase 2's RecordingRunner).
        let peak = await provider.peakConcurrency()
        #expect(peak >= 2, "diamond fixture should fan out leaf stops in parallel; got peak=\(peak)")
    }

    @Test("restartStopBarrierBeforeStart — every start happens AFTER every stop completes")
    func restartStopBarrierBeforeStart() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-test-restart-barrier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        services:
          web:
            image: nginx:1
          db:
            image: postgres:16
          cache:
            image: redis:7
        """
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)

        let recorder = RecordingRunner()
        let provider = RecordingContainerClientProvider()
        let project = dir.lastPathComponent
        await provider.stubRunningContainer(id: "\(project)-web")
        await provider.stubRunningContainer(id: "\(project)-db")
        await provider.stubRunningContainer(id: "\(project)-cache")

        try await RunnerEnvironment.$current.withValue(recorder) {
            try await ContainerClientEnvironment.$current.withValue(provider) {
                var cmd = try ComposeRestart.parse(["-f", compose.path])
                try await cmd.run()
            }
        }

        // Stop phase records `.stop(id:)` entries on the provider.
        // Start phase records `"container start"` argvs on the runner.
        // The barrier invariant: every "container start" argv must come AFTER
        // every `.stop(id:)` entry. Since runner and provider are different
        // recorders, we measure barrier compliance via WALL ORDER — the
        // ComposeRestart `try await composeStop.stopServices(...)` synchronously
        // blocks before `composeStart.startServices(...)` runs, so by the time
        // any `"container start"` argv is recorded by the runner, every
        // `.stop(id:)` entry must already be on the provider.
        let providerEntries = await provider.entriesSnapshot()
        let stopCount = providerEntries.reduce(into: 0) { acc, entry in
            if case .stop = entry { acc += 1 }
        }
        #expect(stopCount == 3, "all three services must be stopped; got stopCount=\(stopCount)")

        let startArgvs = await recorder.unorderedRunCalls(matching: ["container", "start"])
        #expect(startArgvs.count == 3, "all three services must be started after stop barrier; got startCount=\(startArgvs.count)")

        // Stronger invariant: snapshot the provider's stop count BEFORE
        // collecting runner argvs. If any "container start" argv had been
        // recorded BEFORE the stop barrier completed, it would mean
        // `composeStart.startServices` ran while `composeStop.stopServices`
        // was still in flight — violating the barrier. The await between
        // the two phases in ComposeRestart prevents this; here we just
        // confirm both phases ran to completion.
        let services: [String] = ["web", "db", "cache"]
        for svc in services {
            let stopped = await provider.unorderedEntries(matching: { entry in
                if case .stop(let id) = entry, id == "\(project)-\(svc)" { return true } else { return false }
            })
            #expect(stopped.count == 1, "service \(svc) must be stopped exactly once; got \(stopped.count)")

            let started = await recorder.unorderedRunCalls(matching: ["container", "start", "--detach", "\(project)-\(svc)"])
            #expect(started.count == 1, "service \(svc) must be started exactly once; got \(started.count)")
        }
    }

    // MARK: - AsyncSemaphore — cancellation contract (UltraBrain Critical #1)

    @Test("AsyncSemaphore.acquire throws when cancelled before a permit is available")
    func semaphoreCancellationBeforePermit() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.acquire()

        let waiter = Task<Void, Error> {
            try await sem.acquire()
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let queued = await sem.currentWaiterCount()
        #expect(queued == 1, "waiter should be enqueued; got \(queued)")

        waiter.cancel()

        do {
            try await waiter.value
            Issue.record("Expected acquire to throw CancellationError after cancellation")
        } catch is CancellationError {
            // Expected.
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let remaining = await sem.currentWaiterCount()
        #expect(remaining == 0, "cancelled waiter must be removed; \(remaining) remain")

        let permits = await sem.currentPermits()
        #expect(permits == 0, "cancellation must NOT consume a permit; got \(permits)")

        await sem.release()

        let after = await sem.currentPermits()
        #expect(after == 1, "release should restore the permit")
    }

    @Test("AsyncSemaphore.withPermit releases the permit when the holding task is cancelled")
    func semaphoreCancellationWhileHoldingPermit() async throws {
        let sem = AsyncSemaphore(value: 1)
        let releasedSignal = OrderRecorder()

        let holder = Task<Void, Error> {
            try await sem.withPermit {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    await releasedSignal.record("body-cancelled")
                    throw error
                }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let preCancelPermits = await sem.currentPermits()
        #expect(preCancelPermits == 0, "permit should be held; got \(preCancelPermits)")

        holder.cancel()

        do {
            try await holder.value
        } catch {
            // Expected; the body's sleep observes cancellation and rethrows.
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let postCancelPermits = await sem.currentPermits()
        #expect(postCancelPermits == 1, "withPermit must release on body error; got \(postCancelPermits)")

        let signals = await releasedSignal.snapshot()
        #expect(signals.contains("body-cancelled"), "body should have observed cancellation")
    }

    @Test("AsyncSemaphore continues serving FIFO after a queued waiter is cancelled")
    func boundedFanOutContinuesAfterCancelledWaiter() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.acquire()

        let order = OrderRecorder()

        let cancelled = Task<Void, Error> {
            do {
                try await sem.acquire()
                await order.record("cancelled-acquired")
                await sem.release()
            } catch {
                await order.record("cancelled-thrown")
                throw error
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        let survivor = Task<Void, Error> {
            try await sem.acquire()
            await order.record("survivor-acquired")
            await sem.release()
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        let queuedBefore = await sem.currentWaiterCount()
        #expect(queuedBefore == 2, "expected 2 waiters before cancel; got \(queuedBefore)")

        cancelled.cancel()
        do { try await cancelled.value } catch {}

        try await Task.sleep(nanoseconds: 50_000_000)

        let queuedAfter = await sem.currentWaiterCount()
        #expect(queuedAfter == 1, "only survivor should remain; got \(queuedAfter)")

        await sem.release()

        try await survivor.value

        let recorded = await order.snapshot()
        #expect(recorded.contains("cancelled-thrown"))
        #expect(recorded.contains("survivor-acquired"))
        #expect(!recorded.contains("cancelled-acquired"))
    }


    // MARK: - AsyncSemaphore — basic invariants

    @Test("AsyncSemaphore allows up to N concurrent acquires")
    func semaphoreAllowsLimit() async throws {
        let sem = AsyncSemaphore(value: 3)
        try await sem.acquire()
        try await sem.acquire()
        try await sem.acquire()

        let permits = await sem.currentPermits()
        #expect(permits == 0, "all 3 permits should be taken")

        await sem.release()
        await sem.release()
        await sem.release()

        let after = await sem.currentPermits()
        #expect(after == 3, "all 3 permits should be restored")
    }

    @Test("AsyncSemaphore.withPermit releases on success")
    func semaphoreWithPermitSuccess() async throws {
        let sem = AsyncSemaphore(value: 2)
        let result = try await sem.withPermit { 42 }
        #expect(result == 42)

        let permits = await sem.currentPermits()
        #expect(permits == 2, "all permits should be available again")
    }

    @Test("AsyncSemaphore.withPermit releases on body error")
    func semaphoreWithPermitOnError() async throws {
        struct Boom: Error {}
        let sem = AsyncSemaphore(value: 1)

        do {
            _ = try await sem.withPermit { throw Boom() }
            Issue.record("Expected withPermit body to throw")
        } catch is Boom {
            // Expected.
        }

        let permits = await sem.currentPermits()
        #expect(permits == 1, "permit should be released after body error; got \(permits)")
    }

    // MARK: - ParallelLimitResolver

    @Test("ParallelLimitResolver: CLI value wins over env")
    func resolvedParallelLimitCLIOverEnv() throws {
        let env = ["COMPOSE_PARALLEL_LIMIT": "8"]
        let resolved = try ParallelLimitResolver.resolved(cli: 4, env: env)
        #expect(resolved == 4, "CLI value 4 must win over env value 8; got \(resolved)")
    }

    @Test("ParallelLimitResolver: valid env when no CLI returns env value")
    func resolvedParallelLimitValidEnv() throws {
        let env = ["COMPOSE_PARALLEL_LIMIT": "8"]
        let resolved = try ParallelLimitResolver.resolved(cli: nil, env: env)
        #expect(resolved == 8, "env value 8 must apply when no CLI; got \(resolved)")
    }

    @Test("ParallelLimitResolver: non-integer env throws ValidationError")
    func resolvedParallelLimitNonIntegerEnv() {
        let env = ["COMPOSE_PARALLEL_LIMIT": "not-a-number"]
        #expect(throws: ValidationError.self) {
            _ = try ParallelLimitResolver.resolved(cli: nil, env: env)
        }
    }

    @Test("ParallelLimitResolver: zero env throws ValidationError")
    func resolvedParallelLimitZeroEnv() {
        let env = ["COMPOSE_PARALLEL_LIMIT": "0"]
        #expect(throws: ValidationError.self) {
            _ = try ParallelLimitResolver.resolved(cli: nil, env: env)
        }
    }

    @Test("ParallelLimitResolver: negative env throws ValidationError")
    func resolvedParallelLimitNegativeEnv() {
        let env = ["COMPOSE_PARALLEL_LIMIT": "-3"]
        #expect(throws: ValidationError.self) {
            _ = try ParallelLimitResolver.resolved(cli: nil, env: env)
        }
    }

    @Test("ParallelLimitResolver: CLI wins even if env is invalid")
    func resolvedParallelLimitCLIWinsOverInvalidEnv() throws {
        let env = ["COMPOSE_PARALLEL_LIMIT": "garbage"]
        let resolved = try ParallelLimitResolver.resolved(cli: 6, env: env)
        #expect(resolved == 6, "CLI must win even with invalid env; got \(resolved)")
    }

    @Test("ParallelLimitResolver: CLI < 1 throws ValidationError")
    func resolvedParallelLimitInvalidCLI() {
        #expect(throws: ValidationError.self) {
            _ = try ParallelLimitResolver.resolved(cli: 0, env: [:])
        }
    }

    @Test("ParallelLimitResolver: no CLI no env returns default")
    func resolvedParallelLimitDefault() throws {
        let resolved = try ParallelLimitResolver.resolved(cli: nil, env: [:])
        #expect(resolved == ParallelLimitResolver.defaultLimit)
    }

    // MARK: - runBoundedThrowingFanOut — basic invariants

    @Test("runBoundedThrowingFanOut returns results in input order")
    func fanOutReturnsResultsInInputOrder() async throws {
        let items: [(key: String, value: Int)] = [
            ("a", 1), ("b", 2), ("c", 3), ("d", 4),
        ]
        let results = try await runBoundedThrowingFanOut(items: items, limit: 2) { _, value in
            try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...10_000_000))
            return value * 10
        }
        let keys = results.map(\.key)
        let values = results.map(\.value)
        #expect(keys == ["a", "b", "c", "d"])
        #expect(values == [10, 20, 30, 40])
    }

    @Test("runBoundedThrowingFanOut empty input returns empty array")
    func fanOutEmptyInput() async throws {
        let results = try await runBoundedThrowingFanOut(
            items: [(String, Int)](),
            limit: 4
        ) { _, _ in 0 }
        #expect(results.isEmpty)
    }

    @Test("runBoundedThrowingFanOut respects concurrency limit and achieves parallelism")
    func fanOutRespectsLimit() async throws {
        let meter = ConcurrencyMeter()
        let items = (0..<10).map { (key: "item-\($0)", value: $0) }

        _ = try await runBoundedThrowingFanOut(items: items, limit: 3) { _, _ in
            await meter.enter()
            try await Task.sleep(nanoseconds: 20_000_000)
            await meter.exit()
        }

        let peak = await meter.peak()
        #expect(peak <= 3, "peak \(peak) exceeds limit 3")
        #expect(peak >= 2, "expected real parallelism; peak was \(peak)")
    }

    @Test("runBoundedThrowingFanOut tags errors with item key")
    func fanOutTagsErrors() async throws {
        struct Boom: Error {}
        let items: [(key: String, value: Int)] = [("a", 1), ("b", 2), ("c", 3)]

        do {
            _ = try await runBoundedThrowingFanOut(items: items, limit: 2) { key, _ in
                if key == "b" { throw Boom() }
                try await Task.sleep(nanoseconds: 200_000_000)
                return 0
            }
            Issue.record("Expected fan-out to throw")
        } catch let tagged as ServiceTaggedError {
            #expect(tagged.itemKey == "b", "expected error tagged 'b'; got '\(tagged.itemKey)'")
            #expect(tagged.underlyingDescription.contains("Boom"))
        } catch {
            Issue.record("Expected ServiceTaggedError, got \(error)")
        }
    }

    @Test("runBoundedThrowingFanOut: first failure cancels in-flight siblings")
    func fanOutCancelsOnFirstFailure() async throws {
        struct Boom: Error {}
        let cancelMeter = ConcurrencyMeter()
        let items: [(key: String, value: Int)] = [
            ("fast-fail", 1),
            ("slow-1", 2),
            ("slow-2", 3),
            ("slow-3", 4),
        ]

        do {
            _ = try await runBoundedThrowingFanOut(items: items, limit: 4) { key, _ in
                if key == "fast-fail" {
                    try await Task.sleep(nanoseconds: 30_000_000)
                    throw Boom()
                }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    await cancelMeter.enter()
                    await cancelMeter.exit()
                    throw error
                }
            }
            Issue.record("Expected fan-out to throw")
        } catch is ServiceTaggedError {
            // Expected.
        }

        let cancelledCount = await cancelMeter.total()
        #expect(cancelledCount >= 2, "expected siblings to observe cancellation; got \(cancelledCount)")
    }

    // MARK: - DependencyCoordinator — readiness semantics (UltraBrain Critical #4)

    @Test("DependencyCoordinator.awaitMilestone returns immediately when already reached")
    func coordinatorAwaitImmediateWhenAlreadyReached() async throws {
        let coord = DependencyCoordinator()
        await coord.publishMilestone(.started, for: "db")

        try await coord.awaitMilestone(for: "db", milestone: .started)

        let waiterCount = await coord.currentWaiterCount()
        #expect(waiterCount == 0)
    }

    @Test("DependencyCoordinator.publishMilestone unblocks matching waiters")
    func coordinatorPublishUnblocksWaiters() async throws {
        let coord = DependencyCoordinator()
        let order = OrderRecorder()

        let waiter = Task<Void, Error> {
            try await coord.awaitMilestone(for: "db", milestone: .started)
            await order.record("woken")
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        let queued = await coord.currentWaiterCount()
        #expect(queued == 1)

        await coord.publishMilestone(.started, for: "db")

        try await waiter.value

        let recorded = await order.snapshot()
        #expect(recorded == ["woken"])
    }

    @Test("DependencyCoordinator: publishing .healthy satisfies .started waiters")
    func coordinatorHealthyImpliesStarted() async throws {
        let coord = DependencyCoordinator()
        let order = OrderRecorder()

        let waiter = Task<Void, Error> {
            try await coord.awaitMilestone(for: "db", milestone: .started)
            await order.record("started-satisfied")
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        await coord.publishMilestone(.healthy, for: "db")

        try await waiter.value

        let recorded = await order.snapshot()
        #expect(recorded == ["started-satisfied"])
    }

    @Test("DependencyCoordinator: publishing .completedSuccessfully satisfies .started waiters")
    func coordinatorCompletedImpliesStarted() async throws {
        let coord = DependencyCoordinator()
        let order = OrderRecorder()

        let waiter = Task<Void, Error> {
            try await coord.awaitMilestone(for: "migrations", milestone: .started)
            await order.record("started-via-completed")
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        await coord.publishMilestone(.completedSuccessfully, for: "migrations")

        try await waiter.value

        let recorded = await order.snapshot()
        #expect(recorded == ["started-via-completed"])
    }

    @Test("DependencyCoordinator: publishing .completedSuccessfully does NOT satisfy .healthy waiters")
    func coordinatorCompletedDoesNotImplyHealthy() async throws {
        let coord = DependencyCoordinator()

        let waiter = Task<Void, Error> {
            try await coord.awaitMilestone(for: "migrations", milestone: .healthy)
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        await coord.publishMilestone(.completedSuccessfully, for: "migrations")

        try await Task.sleep(nanoseconds: 50_000_000)

        let stillQueued = await coord.currentWaiterCount()
        #expect(stillQueued == 1, "completedSuccessfully must not satisfy a healthy waiter")

        // Clean up so the test doesn't leak the suspended waiter beyond
        // its assertion lifetime.
        await coord.cancelAll()
        do { try await waiter.value } catch {}
    }

    @Test("DependencyCoordinator: per-edge waits do NOT collapse to a max condition (Critical #4)")
    func coordinatorPerEdgeWaitsAreIndependent() async throws {
        let coord = DependencyCoordinator()
        let order = OrderRecorder()

        let waitsForStarted = Task<Void, Error> {
            try await coord.awaitMilestone(for: "db", milestone: .started)
            await order.record("started-resolved")
        }
        let waitsForHealthy = Task<Void, Error> {
            try await coord.awaitMilestone(for: "db", milestone: .healthy)
            await order.record("healthy-resolved")
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        await coord.publishMilestone(.started, for: "db")
        try await waitsForStarted.value

        let intermediate = await order.snapshot()
        #expect(intermediate == ["started-resolved"], "started waiter must resolve independently of healthy waiter")

        await coord.publishMilestone(.healthy, for: "db")
        try await waitsForHealthy.value

        let final = await order.snapshot()
        #expect(final == ["started-resolved", "healthy-resolved"])
    }

    @Test("DependencyCoordinator.cancelAll drains every pending waiter")
    func coordinatorCancelAllDrainsAllWaiters() async throws {
        let coord = DependencyCoordinator()

        let w1 = Task<Void, Error> { try await coord.awaitMilestone(for: "a", milestone: .started) }
        let w2 = Task<Void, Error> { try await coord.awaitMilestone(for: "b", milestone: .healthy) }
        let w3 = Task<Void, Error> { try await coord.awaitMilestone(for: "c", milestone: .completedSuccessfully) }
        try await Task.sleep(nanoseconds: 30_000_000)

        let queued = await coord.currentWaiterCount()
        #expect(queued == 3)

        await coord.cancelAll()

        for task in [w1, w2, w3] {
            do {
                try await task.value
                Issue.record("Expected awaitMilestone to throw after cancelAll")
            } catch is CancellationError {
                // Expected.
            }
        }

        let after = await coord.currentWaiterCount()
        #expect(after == 0)

        let cancelled = await coord.isCancelled()
        #expect(cancelled)
    }

    @Test("DependencyCoordinator.awaitMilestone after cancelAll throws CancellationError immediately")
    func coordinatorAwaitAfterCancelAllThrows() async throws {
        let coord = DependencyCoordinator()
        await coord.cancelAll()

        do {
            try await coord.awaitMilestone(for: "any", milestone: .started)
            Issue.record("Expected awaitMilestone to throw after cancelAll")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test("DependencyCoordinator.publishMilestone is idempotent")
    func coordinatorPublishIsIdempotent() async throws {
        let coord = DependencyCoordinator()
        await coord.publishMilestone(.started, for: "db")
        await coord.publishMilestone(.started, for: "db")
        await coord.publishMilestone(.started, for: "db")

        let snapshot = await coord.reachedSnapshot()
        #expect(snapshot["db"] == [.started])
    }

    @Test("DependencyCoordinator: cancelled waiter does not leak from queue")
    func coordinatorCancelledWaiterRemovedFromQueue() async throws {
        let coord = DependencyCoordinator()

        let task = Task<Void, Error> {
            try await coord.awaitMilestone(for: "db", milestone: .started)
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        let before = await coord.currentWaiterCount()
        #expect(before == 1)

        task.cancel()
        do { try await task.value } catch {}

        try await Task.sleep(nanoseconds: 50_000_000)

        let after = await coord.currentWaiterCount()
        #expect(after == 0, "cancelled waiter must be removed; \(after) remain")
    }

    // MARK: - runBoundedCollectingFanOut (CHAOS-1446 plan CR-5)

    @Test("runBoundedCollectingFanOut preserves all results without cancelling siblings")
    func collectingFanOutPreservesAllResults() async throws {
        struct Boom: Error {}
        let runMeter = ConcurrencyMeter()
        let items: [(key: String, value: Int)] = [
            ("a", 1), ("b", 2), ("c", 3), ("d", 4), ("e", 5),
        ]
        let failingKeys: Set<String> = ["b", "d"]

        let results: [String: Result<Int, Error>] = await runBoundedCollectingFanOut(items: items, limit: 3) { key, value -> Result<Int, Error> in
            await runMeter.enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            await runMeter.exit()
            if failingKeys.contains(key) {
                return .failure(Boom())
            }
            return .success(value * 10)
        }

        #expect(results.count == items.count, "every input must produce a result; got \(results.count) of \(items.count)")

        for (key, value) in items {
            guard let outcome = results[key] else {
                Issue.record("missing result for key '\(key)'")
                continue
            }
            if failingKeys.contains(key) {
                switch outcome {
                case .success(let unexpected):
                    Issue.record("expected .failure for key '\(key)', got .success(\(unexpected))")
                case .failure(let err):
                    #expect(err is Boom, "expected Boom for key '\(key)'; got \(err)")
                }
            } else {
                switch outcome {
                case .success(let v):
                    #expect(v == value * 10, "expected \(value * 10) for '\(key)', got \(v)")
                case .failure(let err):
                    Issue.record("expected .success for key '\(key)', got .failure(\(err))")
                }
            }
        }

        let totalRan = await runMeter.total()
        #expect(totalRan == items.count, "every body must have run — sibling cancellation is FORBIDDEN; observed \(totalRan) of \(items.count)")
    }

    @Test("runBoundedCollectingFanOut empty input returns empty dictionary")
    func collectingFanOutEmptyInput() async {
        let body: @Sendable (String, Int) async -> Result<Int, Error> = { _, _ in .success(0) }
        let results = await runBoundedCollectingFanOut(
            items: [(String, Int)](),
            limit: 4,
            body: body
        )
        #expect(results.isEmpty)
    }

    @Test("runBoundedCollectingFanOut respects concurrency limit")
    func collectingFanOutRespectsLimit() async {
        let meter = ConcurrencyMeter()
        let items = (0..<8).map { (key: "item-\($0)", value: $0) }

        let body: @Sendable (String, Int) async -> Result<Void, Error> = { _, _ in
            await meter.enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            await meter.exit()
            return .success(())
        }
        _ = await runBoundedCollectingFanOut(items: items, limit: 2, body: body)

        let peak = await meter.peak()
        #expect(peak <= 2, "peak \(peak) exceeds limit 2")
        #expect(peak >= 1, "expected at least one in-flight body; got \(peak)")
    }

    // MARK: - RecordingRunner peakConcurrency (CHAOS-1446 plan L350)

    @Test("RecordingRunner tracks peak concurrency across overlapping run() calls")
    func recordingRunnerTracksPeakConcurrency() async throws {
        let runner = RecordingRunner()

        // Fire 4 overlapping run() invocations from independent tasks. The
        // runner's Task.yield() at the top of run() lets the actor process
        // each addTask's queued message before the previous one completes,
        // so peakConcurrency rises above 1. Loose `>= 2` bound to avoid
        // scheduler-timing flakes; we just need to prove parallelism is
        // observable, not pin an exact value.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<4 {
                group.addTask {
                    let request = RunRequest(
                        kind: .awaitOnly,
                        argv: ["container", "peak-test-\(i)"],
                        cwd: "/tmp"
                    )
                    let nilStdout: (@Sendable (String) -> Void)? = nil
                    let nilStderr: (@Sendable (String) -> Void)? = nil
                    _ = try? await runner.run(request, onStdout: nilStdout, onStderr: nilStderr)
                }
            }
            await group.waitForAll()
        }

        let peak = await runner.peakConcurrency()
        #expect(peak >= 2, "expected concurrent run() invocations to interleave under actor reentrancy; peak was \(peak)")

        let inFlight = await runner.currentInFlight()
        #expect(inFlight == 0, "all run() calls must have completed; \(inFlight) still in-flight")
    }

    // MARK: - CHAOS-1503 compose-up parallelism-validation tests

    @Test("composeUpStartFanOutObservesPeakConcurrency — diamond fan-out overlaps api+worker after base")
    func composeUpStartFanOutObservesPeakConcurrency() async throws {
        let coordinator = DependencyCoordinator()
        let recorder = RecordingRunner()
        let order = OrderRecorder()
        let projectName = "cc-test-fanout-\(UUID().uuidString.prefix(8))"

        // Simulate Phase B's withThrowingTaskGroup for a diamond fixture:
        //   base (no deps) ← api, worker (both depend on base)
        // Each child task awaits its coordinator deps, runs a `container run`
        // argv through RecordingRunner, then publishes .started — mirroring
        // the CHAOS-1505 coordinator-wired TaskGroup in ComposeUp.run().
        try await withThrowingTaskGroup(of: Void.self) { group in
            // base — no deps, runs immediately
            group.addTask {
                await order.record("base-run")
                let request = RunRequest(
                    kind: .streaming,
                    argv: ["container", "run", "--detach", "--name", "\(projectName)-base", "postgres:16"]
                )
                _ = try await recorder.run(request, onStdout: nil, onStderr: nil)
                // Record "base-started" BEFORE publishMilestone so dependents
                // (gated on awaitMilestone) cannot resume and record their own
                // -run events until base-started is already in the order.
                // OrderRecorder is an actor so calls serialize; awaiters of the
                // .started milestone necessarily observe base-started first.
                await order.record("base-started")
                await coordinator.publishMilestone(.started, for: "base")
            }
            // api — depends on base (.started)
            group.addTask {
                try await coordinator.awaitMilestone(for: "base", milestone: .started)
                await order.record("api-run")
                let request = RunRequest(
                    kind: .streaming,
                    argv: ["container", "run", "--detach", "--name", "\(projectName)-api", "nginx:1"]
                )
                _ = try await recorder.run(request, onStdout: nil, onStderr: nil)
                await coordinator.publishMilestone(.started, for: "api")
            }
            // worker — depends on base (.started)
            group.addTask {
                try await coordinator.awaitMilestone(for: "base", milestone: .started)
                await order.record("worker-run")
                let request = RunRequest(
                    kind: .streaming,
                    argv: ["container", "run", "--detach", "--name", "\(projectName)-worker", "redis:7"]
                )
                _ = try await recorder.run(request, onStdout: nil, onStderr: nil)
                await coordinator.publishMilestone(.started, for: "worker")
            }
            try await group.waitForAll()
        }

        // Both api and worker must run AFTER base published .started.
        let snapshot = await order.snapshot()
        let baseStartedIdx = try #require(snapshot.firstIndex(of: "base-started"))
        let apiRunIdx = try #require(snapshot.firstIndex(of: "api-run"))
        let workerRunIdx = try #require(snapshot.firstIndex(of: "worker-run"))
        #expect(baseStartedIdx < apiRunIdx, "api must start after base reaches running")
        #expect(baseStartedIdx < workerRunIdx, "worker must start after base reaches running")

        // api and worker fan out concurrently through the recorder —
        // the recorder's 100µs reentrancy sleep lets the overlapping run()
        // invocations both bump inFlightCount before either exits.
        let peak = await recorder.peakConcurrency()
        #expect(peak >= 2, "expected api+worker container run calls to overlap; peakConcurrency was \(peak)")
    }

    @Test("concurrentFailureExactlyOnceSidecarTeardown — failure catch drains coordinator before sidecar stop")
    func concurrentFailureExactlyOnceSidecarTeardown() async throws {
        let coordinator = DependencyCoordinator()
        let recorder = RecordingRunner()
        let order = OrderRecorder()
        let projectName = "cc-test-fail-teardown-\(UUID().uuidString.prefix(8))"
        let sidecarName = "\(projectName)-compose-dns"

        // Simulate the failure-path tear-down ordering contract from
        // ComposeUp.run() L344-372:
        //   1. dependencyCoordinator.cancelAll() — drain suspended waiters
        //   2. EmbeddedDNSSidecar.stop — sidecar teardown (stop + delete)
        //
        // We register a real suspended waiter via a detached `Task { ... }`
        // (mirrors the pattern at L1001-1029, `coordinatorCancelAllDrainsAllWaiters`)
        // — `withThrowingTaskGroup` does NOT propagate cancellation through
        // an `awaitMilestone` continuation cleanly (the group's structured
        // wait deadlocks on the suspended actor continuation), so the
        // detached-task pattern is the canonical way to assert the drain.
        let waiterTask = Task<Void, Error> {
            try await coordinator.awaitMilestone(for: "bad-svc", milestone: .started)
        }
        // Yield until the waiter is actually queued on the coordinator before
        // simulating the catch-path tear-down — otherwise cancelAll could fire
        // before the waiter registers and the test would race.
        while await coordinator.currentWaiterCount() < 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        // Simulate the catch block from ComposeUp.run().
        // Step 1: cancelAll (drain depends_on waiters)
        await order.record("cancelAll")
        await coordinator.cancelAll()

        // Step 2: sidecar stop (best-effort teardown)
        await order.record("sidecar-stop")
        _ = try? await recorder.run(
            RunRequest(kind: .awaitOnly, argv: ["container", "stop", sidecarName]),
            onStdout: nil, onStderr: nil
        )
        _ = try? await recorder.run(
            RunRequest(kind: .awaitOnly, argv: ["container", "delete", sidecarName]),
            onStdout: nil, onStderr: nil
        )

        // Verify the suspended waiter was drained with CancellationError.
        var waiterError: Error?
        do {
            try await waiterTask.value
        } catch {
            waiterError = error
        }
        #expect(waiterError is CancellationError, "suspended awaitMilestone waiter must throw CancellationError after cancelAll; got \(String(describing: waiterError))")

        // (a) cancelAll MUST fire before sidecar stop.
        let events = await order.snapshot()
        let cancelIdx = try #require(events.firstIndex(of: "cancelAll"))
        let stopIdx = try #require(events.firstIndex(of: "sidecar-stop"))
        #expect(cancelIdx < stopIdx, "coordinator.cancelAll() must fire before sidecar teardown")

        // (b) Sidecar stop + delete appear exactly once each.
        let sidecarStops = await recorder.unorderedRunCalls(matching: ["container", "stop", sidecarName])
        let sidecarDeletes = await recorder.unorderedRunCalls(matching: ["container", "delete", sidecarName])
        #expect(sidecarStops.count == 1, "sidecar stop must be invoked exactly once; got \(sidecarStops.count)")
        #expect(sidecarDeletes.count == 1, "sidecar delete must be invoked exactly once; got \(sidecarDeletes.count)")

        // (c) Coordinator is cancelled — subsequent waits throw immediately.
        let isCancelled = await coordinator.isCancelled()
        #expect(isCancelled, "coordinator must be cancelled after failure teardown")
    }

    @Test("adoptedServiceNilIPDoesNotDeadlock — adopted upstream publishes .started, dependent proceeds",
          .timeLimit(.minutes(1)))
    func adoptedServiceNilIPDoesNotDeadlock() async throws {
        let coordinator = DependencyCoordinator()
        let order = OrderRecorder()

        // Simulate an adopted db (nil IP from RecordingContainerClientProvider)
        // and a dependent app. Under the CHAOS-1505 coordinator wiring,
        // the adopted db's configServiceStart publishes .started (L337),
        // which unblocks app — even though the adopted container has no
        // resolved IP. Without the coordinator, the polling fallback in
        // Compose+Wait.swift would spin for 60s trying to resolve the dep.
        try await withThrowingTaskGroup(of: Void.self) { group in
            // db (adopted): publishes .started immediately. In production,
            // configServiceStart skips the spawn for adopted services but
            // still reaches publishMilestone(.started) at L337.
            group.addTask {
                await order.record("db-publish")
                await coordinator.publishMilestone(.started, for: "db")
            }
            // app: depends_on db (.started)
            group.addTask {
                try await coordinator.awaitMilestone(for: "db", milestone: .started)
                await order.record("app-proceed")
            }
            try await group.waitForAll()
        }

        // Assert app proceeded. The .timeLimit(.seconds(10)) annotation
        // on this @Test catches deadlocks (coordinator-bypass would spin
        // for 60s in the polling fallback).
        let events = await order.snapshot()
        #expect(events.contains("db-publish"), "adopted db must publish .started")
        #expect(events.contains("app-proceed"), "dependent app must proceed after db publishes")
        let dbIdx = try #require(events.firstIndex(of: "db-publish"))
        let appIdx = try #require(events.firstIndex(of: "app-proceed"))
        #expect(dbIdx < appIdx, "db publish must happen before app proceeds")
    }

    @Test("perEdgeDependsOnConditions — A waits for B healthy AND C started independently")
    func perEdgeDependsOnConditions() async throws {
        let coordinator = DependencyCoordinator()
        let order = OrderRecorder()

        // Fixture: A depends on B (.healthy) and C (.started).
        // Phase B's per-edge coordinator waits (CHAOS-1505) mean A's task
        // awaits BOTH milestones independently before proceeding. This is
        // UltraBrain Critical #4: per-edge waits must NOT collapse to a
        // single max-condition wait.
        try await withThrowingTaskGroup(of: Void.self) { group in
            // C: publishes .started immediately
            group.addTask {
                await coordinator.publishMilestone(.started, for: "C")
                await order.record("C-started")
            }
            // B: publishes .healthy after a short delay
            group.addTask {
                try await Task.sleep(nanoseconds: 50_000_000)
                await coordinator.publishMilestone(.healthy, for: "B")
                await order.record("B-healthy")
            }
            // A: awaits both deps per-edge (mirrors ComposeUp L308-316)
            group.addTask {
                try await coordinator.awaitMilestone(for: "B", milestone: .healthy)
                try await coordinator.awaitMilestone(for: "C", milestone: .started)
                await order.record("A-started")
            }
            try await group.waitForAll()
        }

        let events = await order.snapshot()
        let bHealthyIdx = try #require(events.firstIndex(of: "B-healthy"))
        let cStartedIdx = try #require(events.firstIndex(of: "C-started"))
        let aStartedIdx = try #require(events.firstIndex(of: "A-started"))

        // A's run must appear ONLY AFTER both B-healthy AND C-started.
        #expect(bHealthyIdx < aStartedIdx, "A must wait for B to reach healthy")
        #expect(cStartedIdx < aStartedIdx, "A must wait for C to reach started")
    }

    @Test("optionalDepWarningPreservesEdgeSemantics — optional dep failure warns but dependent proceeds")
    func optionalDepWarningPreservesEdgeSemantics() async throws {
        let coordinator = DependencyCoordinator()
        let recorder = RecordingRunner()
        let projectName = "cc-test-optdep-\(UUID().uuidString.prefix(8))"

        // Capture stdout via the dup2-Pipe pattern (mirrors SecurityArgsTests,
        // GpusBlkioTests, etc.).
        let pipe = Pipe()
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        guard original >= 0,
              dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0
        else {
            if original >= 0 { close(original) }
            Issue.record("dup2 setup failed")
            return
        }

        // Simulate Phase B: foo fails (coordinator cancels the waiter),
        // bar has optional dep on foo. Bar's awaitMilestone catches
        // CancellationError for the optional dep (mirrors ComposeUp L317-325),
        // prints the warning, and proceeds to launch.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // bar: optional dep on foo, then launches
                group.addTask {
                    do {
                        try await coordinator.awaitMilestone(for: "foo", milestone: .started)
                    } catch {
                        // Mirror ComposeUp.run() L321-325: optional dep warning
                        let condition = DependsOnCondition.serviceStarted
                        print(
                            "Warning: optional dependency 'foo' for service " +
                            "'bar' did not satisfy condition " +
                            "'\(condition.rawValue)': \(error.localizedDescription)"
                        )
                    }
                    // bar proceeds to launch regardless
                    let request = RunRequest(
                        kind: .streaming,
                        argv: ["container", "run", "--detach", "--name",
                               "\(projectName)-bar", "alpine:latest"]
                    )
                    _ = try? await recorder.run(request, onStdout: nil, onStderr: nil)
                }
                // Give bar time to suspend on awaitMilestone before cancelling.
                try await Task.sleep(nanoseconds: 50_000_000)
                // Simulate foo failure → cancel coordinator (mirrors catch block).
                await coordinator.cancelAll()
                try await group.waitForAll()
            }
        }

        // Restore stdout and read captured output.
        fflush(stdout)
        _ = dup2(original, STDOUT_FILENO)
        close(original)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // (a) Warning string must appear in captured stdout.
        #expect(
            output.contains("Warning: optional dependency 'foo' for service 'bar'"),
            "expected optional-dep warning in stdout; got: \(output)"
        )

        // (b) bar must still launch — RecordingRunner must see a container run argv.
        let barRuns = await recorder.unorderedRunCalls(
            matching: ["container", "run", "--detach", "--name", "\(projectName)-bar"]
        )
        #expect(barRuns.count == 1,
                "bar must still launch despite optional dep failure; got \(barRuns.count) run argvs")
    }

    @Test("attachedModeParallelism — attached mode fan-out",
          .timeLimit(.minutes(1)))
    func attachedModeParallelism() async throws {
        // CHAOS-1507: with cancellation-aware waitForever(), attached-mode
        // `compose up` (no --detach) can be exercised end-to-end. We launch
        // ComposeUp.run() in a Task, poll RecordingRunner until all 3
        // service `container run` argvs land, snapshot peak concurrency,
        // then cancel the task to unblock waitForever().
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-test-attached-parallelism-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 3 independent services — no depends_on — so Phase B can fan out
        // freely and peakConcurrency is bounded only by RunCommandRunner
        // reentrancy.
        let yaml = """
        services:
          alpha:
            image: nginx:1
          beta:
            image: redis:7
          gamma:
            image: postgres:16
        """
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)

        let projectName = "cc-test-attached-\(UUID().uuidString.prefix(8))"
        let recorder = RecordingRunner()
        let provider = RecordingContainerClientProvider()

        // Wrap ComposeUp.run() in a Task so we can observe Phase B progress
        // while the surrounding `await waitForever()` is still parked.
        let task = Task<Void, Error> {
            try await RunnerEnvironment.$current.withValue(recorder) {
                try await ContainerClientEnvironment.$current.withValue(provider) {
                    var cmd = try ComposeUp.parse([
                        "--cwd", dir.path,
                        "-p", String(projectName),
                        "-f", compose.path,
                    ])
                    try await cmd.run()
                }
            }
        }

        // Poll for all 3 `container run` argvs (5s timeout). 50ms tick keeps
        // the test responsive without busy-spinning.
        let deadline = Date().addingTimeInterval(5.0)
        var runArgvs: [[String]] = []
        while Date() < deadline {
            runArgvs = await recorder.unorderedRunCalls(matching: ["container", "run"])
            if runArgvs.count >= 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(runArgvs.count >= 3,
                "expected 3 service `container run` argvs within 5s; got \(runArgvs.count)")

        let peak = await recorder.peakConcurrency()
        #expect(peak >= 2,
                "expected attached-mode Phase B to fan out; peakConcurrency was \(peak)")

        // Cancel waitForever() and ensure the task unblocks promptly. Accept
        // either a clean return (waitForever swallows CancellationError) or
        // a propagated CancellationError from an upstream awaited child.
        task.cancel()
        let unblock = Task<Void, Error> {
            do {
                try await task.value
            } catch is CancellationError {
                // Expected on Task.cancel().
            }
        }
        let timeout = Task<Void, Error> {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            throw CancellationError()
        }
        do {
            try await unblock.value
            timeout.cancel()
        } catch {
            timeout.cancel()
            Issue.record("ComposeUp.run() did not unblock within ~1s after task.cancel(): \(error)")
        }
    }
}
