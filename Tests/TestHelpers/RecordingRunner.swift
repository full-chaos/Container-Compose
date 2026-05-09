//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
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
@testable import ContainerComposeCore

/// Captures every `RunRequest` in time order. Backed by an actor for safe
/// concurrent appends from the unstructured `Task { }` in
/// `ComposeUp.configService`.
///
/// See `docs/plans/PLAN-recorder-seam.md` §6 for the full design. PR-1
/// introduces this type; it is unused until PR-2 wires it in via
/// `RuntimeArgvTests`.
public actor RecordingRunner: RunCommandRunner {

    /// One entry per call to `run(_:onStdout:onStderr:)`.
    public struct Entry: Sendable, Equatable {
        public let request: RunRequest
        /// Order of arrival, 0-indexed.
        public let sequence: Int
        /// Stdout closures the call site provided (we don't invoke them by
        /// default; tests can opt-in via `stubStdout`).
        public let hadStdoutHandler: Bool
        public let hadStderrHandler: Bool

        public init(
            request: RunRequest,
            sequence: Int,
            hadStdoutHandler: Bool,
            hadStderrHandler: Bool
        ) {
            self.request = request
            self.sequence = sequence
            self.hadStdoutHandler = hadStdoutHandler
            self.hadStderrHandler = hadStderrHandler
        }
    }

    public private(set) var entries: [Entry] = []

    /// Stubbed exit codes keyed by argv prefix. Last registered wins for the
    /// same prefix (so a test can override an earlier general stub with a
    /// later more-specific one).
    private var exitStubs: [(prefix: [String], exit: Int32)] = []

    /// Stubbed stdout chunks keyed by argv prefix. When a streaming call
    /// matches, each chunk is pushed to the call site's `onStdout` closure
    /// before the runner returns.
    private var stdoutStubs: [(prefix: [String], chunks: [String])] = []

    /// Stubbed probe answers keyed by full argv equality.
    private var probeStubs: [[String]: Bool] = [:]

    /// Stubbed errors thrown for matching `.swiftAPI(name:)` requests, keyed by
    /// name. Mirrors `ProductionRunner.dispatchSwiftAPI` semantics: in-process
    /// upstream calls (`Application.ImagePull`, `Application.BuildCommand`,
    /// `Application.NetworkCreate`) signal failure by **throwing**, not by
    /// returning a non-zero exit code. Tests stub via `stubThrow(swiftAPIName:error:)`.
    private var swiftAPIThrows: [String: any Error] = [:]

    /// CHAOS-1446: number of `run(...)` invocations currently in-flight on
    /// this actor. Incremented on entry, decremented via `defer` on exit
    /// (success OR failure). Always reflects the actor's CURRENT view; the
    /// peak across the run is exposed via `peakConcurrencyValue`.
    private var inFlightCount: Int = 0

    /// CHAOS-1446: high-water mark of `inFlightCount` observed across the
    /// runner's lifetime. Phase 2's `parallelPullsAchieveConcurrency` test
    /// asserts this is `>= 2` after firing overlapping pulls. The `Task.yield()`
    /// at the top of `run(...)` enables actor reentrancy so this can rise
    /// above 1; without the yield, actor serialization would clamp peak to 1.
    private var peakConcurrencyValue: Int = 0

    public init() {}

    // MARK: - Configuration

    /// Register an exit-code stub for any request whose argv starts with the
    /// given prefix. Used to test "what does compose up do when network create
    /// exits 5?" scenarios.
    public func stub(argvPrefix: [String], exitCode: Int32) {
        exitStubs.append((argvPrefix, exitCode))
    }

    /// Register stdout chunks to be replayed through the caller's `onStdout`
    /// closure before the runner returns. Only fires for `.streaming` calls
    /// whose argv starts with `argvPrefix`.
    public func stubStdout(argvPrefix: [String], chunks: [String]) {
        stdoutStubs.append((argvPrefix, chunks))
    }

    /// Set the probe answer for an exact argv. Default for unspecified probes
    /// is `true` (so `checkCreateSupported`-style probes succeed unless a test
    /// explicitly says otherwise).
    public func stubProbe(argv: [String], available: Bool) {
        probeStubs[argv] = available
    }

    /// Make subsequent `.swiftAPI(name:)` calls for `swiftAPIName` throw the
    /// given error. Mirrors `ProductionRunner.dispatchSwiftAPI` — failure of
    /// an in-process upstream call (e.g. `Application.ImagePull.parse(argv).run()`)
    /// throws rather than returning a non-zero exit. Use this to drive `.failed`
    /// arms in callers like `BridgeContainerClientRuntime.pull` / `.build`.
    ///
    /// CHAOS-1433: replaces the previous `stub(swiftAPIName:exitCode:)` API,
    /// which was deceptive — production never returned non-zero exits for
    /// `.swiftAPI`, so callers' `do/catch` blocks could not be exercised by
    /// stubbed exit codes alone.
    public func stubThrow(swiftAPIName: String, error: any Error) {
        swiftAPIThrows[swiftAPIName] = error
    }

    // MARK: - RunCommandRunner

    public func run(
        _ request: RunRequest,
        onStdout: (@Sendable (String) -> Void)?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> RunResult {
        // CHAOS-1446: track concurrency for parallel-fan-out test assertions.
        // Increment BEFORE the explicit `Task.yield()` below so racing
        // run(...) calls observe each other's in-flight increments while the
        // actor is suspended at the yield point.
        inFlightCount += 1
        peakConcurrencyValue = max(peakConcurrencyValue, inFlightCount)
        defer { inFlightCount -= 1 }

        // Explicit suspension to enable actor reentrancy. Without this the
        // actor would process every run(...) message strictly serially and
        // peakConcurrencyValue would always be 1 — making
        // `parallelPullsAchieveConcurrency`-style assertions impossible.
        // Task.yield() does not throw; existing single-shot tests (one
        // task awaiting one run() call at a time) are unaffected because
        // there is no other queued message to interleave with.
        await Task.yield()

        let entry = Entry(
            request: request,
            sequence: entries.count,
            hadStdoutHandler: onStdout != nil,
            hadStderrHandler: onStderr != nil
        )
        entries.append(entry)

        // Replay any stubbed stdout chunks (last registered wins per prefix).
        if let onStdout, request.kind == .streaming,
           let stub = stdoutStubs.last(where: { request.argv.starts(with: $0.prefix) }) {
            for chunk in stub.chunks { onStdout(chunk) }
        }

        switch request.kind {
        case .probe:
            let ok = probeStubs[request.argv] ?? true
            return RunResult(exitCode: ok ? 0 : 1, probeAvailable: ok)
        case .streaming, .streamingInteractive, .awaitOnly:
            let exit = exitStubs.last(where: { request.argv.starts(with: $0.prefix) })?.exit ?? 0
            return RunResult(exitCode: exit, probeAvailable: false)
        case .swiftAPI(let name):
            // CHAOS-1433: failure for `.swiftAPI` is signalled by **throwing**,
            // matching `ProductionRunner.dispatchSwiftAPI`. Tests inject via
            // `stubThrow(swiftAPIName:error:)`. Absence of a stub → success.
            if let stubbedError = swiftAPIThrows[name] {
                throw stubbedError
            }
            return RunResult(exitCode: 0, probeAvailable: false)
        }
    }

    // MARK: - Test affordances

    /// Snapshot of recorded entries in time order.
    public func recordedRequests() -> [Entry] { entries }

    /// CHAOS-1446: high-water mark of concurrent `run(...)` invocations on
    /// this actor. Used by parallel-fan-out tests to verify a fan-out helper
    /// is achieving real parallelism (assert `>= expected` to avoid scheduler
    /// timing flakes). Always `>= 1` as long as at least one `run(...)` was
    /// issued; `>= 2` requires concurrent invocations and the runner's
    /// `Task.yield()` reentrancy point.
    public func peakConcurrency() -> Int { peakConcurrencyValue }

    /// CHAOS-1446: number of `run(...)` invocations currently in-flight on
    /// this actor. Equals 0 when the actor is idle.
    public func currentInFlight() -> Int { inFlightCount }

    /// All recorded argvs in order — most assertions use this.
    public func argvs() -> [[String]] { entries.map(\.request.argv) }

    /// Filter to `container run` calls (the main argv-shape regression target).
    public func runArgvs() -> [[String]] {
        entries.filter { $0.request.argv.starts(with: ["container", "run"]) }
            .map(\.request.argv)
    }

    /// All recorded `.swiftAPI(name:)` call argvs, in time order.
    public func swiftAPIArgvs() -> [(name: String, argv: [String])] {
        entries.compactMap { entry in
            guard case let .swiftAPI(name) = entry.request.kind else { return nil }
            return (name, entry.request.argv)
        }
    }
    /// Filter recorded `.swiftAPI` calls by name.
    public func swiftAPIArgvs(named name: String) -> [[String]] {
        swiftAPIArgvs().filter { $0.name == name }.map(\.argv)
    }

    // MARK: - Unordered / parallel-friendly assertions (CHAOS-1446)

    /// Returns `true` iff the FIRST recorded entry whose argv starts with
    /// `firstPrefix` was recorded BEFORE the FIRST entry whose argv starts
    /// with `secondPrefix`. Returns `false` if either prefix is unmatched.
    ///
    /// Use this when fan-out makes inter-call ordering non-deterministic but
    /// you still need to assert intra-service ordering (e.g.,
    /// `stop-before-delete` for one service, even though SOME other service
    /// may interleave between the stop and the delete).
    public func happensBefore(_ firstPrefix: [String], _ secondPrefix: [String]) -> Bool {
        guard let firstIdx = entries.firstIndex(where: { $0.request.argv.starts(with: firstPrefix) }),
              let secondIdx = entries.firstIndex(where: { $0.request.argv.starts(with: secondPrefix) }) else {
            return false
        }
        return firstIdx < secondIdx
    }

    /// All recorded argvs whose argv starts with `argvPrefix`, returned in
    /// recorded (time) order. Use when you need to inspect the matching
    /// argvs but want to compute set/multiset assertions yourself.
    public func unorderedRunCalls(matching argvPrefix: [String]) -> [[String]] {
        entries
            .filter { $0.request.argv.starts(with: argvPrefix) }
            .map(\.request.argv)
    }

    /// Set-equality view of recorded argvs matching `argvPrefix`. Inter-call
    /// order is normalized away; intra-argv ordering is preserved (each argv
    /// is itself an array, compared element-wise inside the Set).
    /// Use this when fan-out has made inter-call ordering free but you still
    /// want to assert that exactly `expected` argvs were issued.
    public func unorderedArgvSet(matching argvPrefix: [String]) -> Set<[String]> {
        Set(unorderedRunCalls(matching: argvPrefix))
    }

    /// Multiset (count-aware) view of recorded argvs matching `argvPrefix`.
    /// Returns a dictionary mapping each unique argv to the number of times
    /// it was recorded. Use when you want to assert exact call counts under
    /// fan-out (e.g., "each service was pulled exactly once").
    public func unorderedArgvMultiset(matching argvPrefix: [String]) -> [[String]: Int] {
        unorderedRunCalls(matching: argvPrefix).reduce(into: [:]) { acc, argv in
            acc[argv, default: 0] += 1
        }
    }
}
