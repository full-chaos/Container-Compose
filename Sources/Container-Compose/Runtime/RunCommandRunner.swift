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

// MARK: - RunRequest

/// One thing the runner can be asked to do. Captures argv shape + how output
/// should be drained. Time-ordering of multiple requests is captured by the
/// recorder, not by the request itself.
///
/// See `docs/plans/PLAN-recorder-seam.md` §3 for the design rationale.
public struct RunRequest: Sendable, Equatable {
    /// Discriminator describing how the runner should drive the underlying
    /// process. Each kind maps onto an existing helper family in the source
    /// tree (streaming / await-only / probe). See §3 of the plan.
    public enum Kind: Sendable, Equatable {
        /// stdout/stderr should be streamed to the supplied closures.
        /// Production binding wires these to the existing per-line handlers;
        /// recorder binding stashes the closures so it can replay stubbed
        /// stdout chunks if a test wants to.
        case streaming
        /// Process is awaited to completion; stdout/stderr go to the parent
        /// process's stdio (or are silently dropped, depending on the
        /// existing helper's contract — `shellCreate`, `shellKill`,
        /// `shellStart`, `shellExec` all behave this way today).
        case awaitOnly
        /// The runner should report whether a sub-command exists (used by
        /// `ComposeCreate.checkCreateSupported`). `argv` is the probe.
        /// Production binding spawns and checks status==0; recorder binding
        /// returns a stubbed bool keyed on the probe argv.
        case probe
    }

    public let kind: Kind
    /// First element is the executable (today always `"container"`, but the
    /// `ComposeWatch` helpers shell out to `"container-compose"` — we admit
    /// any executable the seam might be asked to run).
    public let argv: [String]
    /// Optional working directory; nil means "inherit caller's cwd".
    public let cwd: String?

    public init(kind: Kind, argv: [String], cwd: String? = nil) {
        self.kind = kind
        self.argv = argv
        self.cwd = cwd
    }
}

// MARK: - RunResult

/// What a runner returns. Mirrors `CommandResult` in `Helper Functions.swift`
/// closely so existing call sites translate easily.
///
/// Per plan §3, this intentionally does NOT carry stdout/stderr buffers:
/// streaming output goes through the `onStdout`/`onStderr` closures of
/// `RunCommandRunner.run(_:onStdout:onStderr:)`, and `awaitOnly` calls inherit
/// parent stdio (mirroring the existing `shellCreate`/`shellKill`/`shellStart`
/// helpers). `probeAvailable` is only meaningful for `.probe` kind.
public struct RunResult: Sendable, Equatable {
    public let exitCode: Int32
    /// Only populated for `.probe` calls (production binding reads exit
    /// status). For `.streaming` / `.awaitOnly` we don't capture stdout —
    /// the production helpers stream it to closures or to the parent stdio
    /// already.
    public let probeAvailable: Bool

    public init(exitCode: Int32, probeAvailable: Bool) {
        self.exitCode = exitCode
        self.probeAvailable = probeAvailable
    }
}

// MARK: - RunCommandRunner

/// The seam every command goes through to talk to the Apple `container`
/// runtime (or to itself, in the `ComposeWatch` self-invocation case).
///
/// Conforming types are bound into the `RunnerEnvironment.current` task-local,
/// so they must be `Sendable`. See plan §4 for injection details.
public protocol RunCommandRunner: Sendable {
    /// Hand a request to the runner. For streaming requests, the supplied
    /// stdout/stderr closures may be invoked any number of times before the
    /// returned `RunResult`.
    ///
    /// Per plan §10 Q4, the runner must always **return** for `.awaitOnly`
    /// (even on non-zero exit) so callers can perform their own error
    /// translation; only failure-to-launch should `throw`.
    func run(
        _ request: RunRequest,
        onStdout: (@Sendable (String) -> Void)?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> RunResult
}

// MARK: - RunnerEnvironment (task-local injection)

/// Task-local holder for the active `RunCommandRunner`. Production code
/// reads `RunnerEnvironment.current` directly; tests bind a recorder via
/// `RunnerEnvironment.$current.withValue(recorder) { … }`.
///
/// Per plan §4, task-locals propagate to unstructured `Task { }` blocks
/// (only `Task.detached` resets them, and we don't use that anywhere).
public enum RunnerEnvironment {
    /// Default is the production binding so call sites can read
    /// `RunnerEnvironment.current` without nil-checking.
    @TaskLocal public static var current: any RunCommandRunner = ProductionRunner()
}

// MARK: - ProductionRunner

/// The concrete `RunCommandRunner` used in production. Wraps the existing
/// `Process()`-based helpers byte-for-byte (per plan §5). PR-1 introduces
/// this type but does NOT switch any call sites; that happens in PR-2..5.
///
/// Behaviour parity invariants (per plan §5 / §10 Q5):
/// - `executableURL = /usr/bin/env`, argv passed verbatim.
/// - `currentDirectoryURL = cwd ?? FileManager.default.currentDirectoryPath`.
/// - PATH merged identically: `/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
/// - `.streaming` with non-nil closures: data routed through closures.
/// - `.streaming` with nil closures: stdout to `print(_:terminator:)`,
///   stderr to `fputs(_:stderr)` (preserves `ComposeRun.streamCommand` parity).
/// - `.awaitOnly`: stdio inherited (no pipes wired).
/// - `.probe`: stdio sent to `/dev/null`; exit==0 ⇒ `probeAvailable: true`.
///
/// Non-zero exit codes are returned via `RunResult.exitCode`, never thrown.
/// Caller-side error translation per plan §10 Q4.
public struct ProductionRunner: RunCommandRunner {
    public init() {}

    public func run(
        _ request: RunRequest,
        onStdout: (@Sendable (String) -> Void)?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> RunResult {
        switch request.kind {
        case .streaming:
            let exit = try await spawnStreaming(
                argv: request.argv,
                cwd: request.cwd,
                onStdout: onStdout,
                onStderr: onStderr
            )
            return RunResult(exitCode: exit, probeAvailable: false)

        case .awaitOnly:
            let exit = try await spawnAwait(
                argv: request.argv,
                cwd: request.cwd
            )
            return RunResult(exitCode: exit, probeAvailable: false)

        case .probe:
            let ok = await spawnProbe(
                argv: request.argv,
                cwd: request.cwd
            )
            return RunResult(exitCode: ok ? 0 : 1, probeAvailable: ok)
        }
    }

    // MARK: - Private spawners
    //
    // Each spawner is a verbatim port of an existing helper body (modulo the
    // argv-as-array parameterisation). PR-2..5 will delete the originals.

    /// Mirrors `ComposeUp.streamCommand` (Sources/Container-Compose/Commands/
    /// ComposeUp.swift:902-955). When `onStdout`/`onStderr` are nil, falls
    /// through to `print` / `fputs(_:stderr)` to preserve `ComposeRun.streamCommand`
    /// (Sources/Container-Compose/Commands/ComposeRun.swift:359-406) parity.
    private func spawnStreaming(
        argv: [String],
        cwd: String?,
        onStdout: (@Sendable (String) -> Void)?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            process.currentDirectoryURL = URL(
                fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath
            )
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]) { _, new in new }

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let string = String(data: data, encoding: .utf8) {
                    if let onStdout {
                        onStdout(string)
                    } else {
                        // ComposeRun parity: write directly to parent stdout.
                        print(string, terminator: "")
                    }
                }
            }

            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let string = String(data: data, encoding: .utf8) {
                    if let onStderr {
                        onStderr(string)
                    } else {
                        // ComposeRun parity: write directly to parent stderr.
                        fputs(string, stderr)
                    }
                }
            }

            process.terminationHandler = { proc in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Mirrors `ComposeCreate.shellCreate` minus the inline NSError-on-non-zero
    /// translation (Sources/Container-Compose/Commands/ComposeCreate.swift:438-475).
    /// Caller translates exit codes per plan §10 Q4. stdio inherited (no pipes).
    private func spawnAwait(argv: [String], cwd: String?) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = argv
            proc.currentDirectoryURL = URL(
                fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath
            )
            proc.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]) { _, new in new }

            proc.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Mirrors `ComposeCreate.checkCreateSupported`
    /// (Sources/Container-Compose/Commands/ComposeCreate.swift:478-497).
    /// stdio nulled. Returns true iff exit==0.
    private func spawnProbe(argv: [String], cwd: String?) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = argv
            if let cwd {
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]) { _, new in new }
            proc.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus == 0)
            }
            do {
                try proc.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
