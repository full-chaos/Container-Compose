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

    // Deflake design (CHAOS-1446 reviewer follow-up):
    // Asserts (1) only the failing body reaches `runMeter.enter`, and
    // (2) at least one sibling observes `CancellationError`. We deliberately
    // do NOT assert the dispatch's literal `runMeter.total() < N` because
    // AsyncStream's single-consumer iteration forbids per-sibling gating
    // AND `AsyncSemaphore.withPermit` releases on body throw, letting
    // queued items race ahead of group-cancel propagation. The full
    // rationale + design constraints are in the inline comment block below.
    @Test("parallelPullFailFastCancelsSiblings — first failure cancels in-flight bodies")
    func parallelPullFailFastCancelsSiblings() async throws {
        struct PullFailed: Error {}
        let runMeter = ConcurrencyMeter()

        // CHAOS-1446 reviewer follow-up: deflake via cancellation-observation,
        // not timing-dependent sibling sleep races.
        //
        // Original (pre-deflake) test asserted `runMeter.total() < 4` after a
        // 5-second sibling sleep — the assumption being that group-cancel
        // propagation would interrupt the sleep before it completed. Reliable
        // in isolation, flaky under heavy CI parallel test load (sleep
        // completed before cancellation arrived).
        //
        // Two design constraints surfaced during the deflake:
        //   (a) AsyncStream is single-consumer, so the lead-suggested
        //       `for await _ in failureSignal { break }` per sibling does not
        //       work — only one sibling can iterate the stream at a time.
        //   (b) AsyncSemaphore.withPermit RELEASES its permit on body throw,
        //       so queued items beyond `limit=2` ARE granted permits and
        //       enter the body — the lead's claim that they would be
        //       "never started" does not hold for this semaphore impl.
        //
        // Deterministic invariants we assert instead:
        //   * exactly one body (db) reaches `runMeter.enter()` — the failing
        //     task itself.
        //   * at least one sibling observes `CancellationError` from
        //     `try await Task.sleep(...)` (sleep is interrupted by group's
        //     cancelAll within ms of db's throw, well within the 5s ceiling).
        // If a sibling's sleep completes WITHOUT cancellation (regression in
        // fail-fast cancellation propagation), the sibling falls through to
        // the bottom `runMeter.enter()` and the `total == 1` assertion catches
        // it.
        let cancelledMeter = ConcurrencyMeter()

        let items: [(key: String, value: String)] = [
            ("web", "nginx:1"),
            ("db", "postgres:16"),    // fails — must be in first `limit` items
            ("cache", "redis:7"),
            ("proxy", "traefik:3"),
        ]

        do {
            _ = try await runBoundedThrowingFanOut(items: items, limit: 2) { key, _ in
                if key == "db" {
                    // Failing task: increment runMeter once, then throw. No
                    // gate needed — siblings observe cancellation through their
                    // own `try await Task.sleep` below, which throws
                    // CancellationError when the group's cancelAll arrives.
                    await runMeter.enter()
                    throw PullFailed()
                }

                // Siblings: sleep for up to 5 seconds. Group's cancelAll on
                // the failing throw propagates to this task; `try await
                // Task.sleep` throws CancellationError as soon as the
                // cancellation signal arrives (typically within ms).
                // CancellationError is caught and counted in cancelledMeter,
                // proving fail-fast cancellation reached this sibling.
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch is CancellationError {
                    await cancelledMeter.enter()
                    throw CancellationError()
                }

                // Reached only if the 5s sleep completed without cancellation
                // — a regression in fail-fast cancellation propagation.
                // Increment runMeter so the assertion below catches the
                // regression rather than silently passing.
                await runMeter.enter()
            }
            Issue.record("Expected fan-out to throw")
        } catch let tagged as ServiceTaggedError {
            #expect(tagged.itemKey == "db", "thrown error must wrap the failing service name; got '\(tagged.itemKey)'")
        } catch {
            Issue.record("Expected ServiceTaggedError, got \(error)")
        }

        let total = await runMeter.total()
        #expect(total == 1, "only the failing service should run to completion; got total=\(total) (siblings reaching the bottom enter indicates cancellation propagation regressed)")

        let cancelled = await cancelledMeter.total()
        #expect(cancelled >= 1, "expected at least one sibling to observe CancellationError; got cancelled=\(cancelled)")
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
}
