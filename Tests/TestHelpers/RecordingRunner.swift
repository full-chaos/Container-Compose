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
}
