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
import ContainerCommands

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
        /// In-process call into the upstream `container` Swift package
        /// (e.g. `Application.ImagePull.parse(argv).run()`,
        /// `Application.NetworkCreate.parse(argv).run()`,
        /// `Application.BuildCommand.parse(argv).validate()/.run()`).
        ///
        /// The `name` is a stable identifier ("ImagePull", "NetworkCreate",
        /// "BuildCommand") used by the production binding to dispatch to the
        /// correct upstream type, and by recorders to filter / assert.
        ///
        /// `RunRequest.argv` for this kind represents the arguments that
        /// would be handed to `Application.<name>.parse(argv)`, byte-for-byte.
        ///
        /// Per plan §9 PR-6 (pulled forward to unblock CI for `RuntimeArgvTests`),
        /// routing these in-process calls through the seam means a
        /// `RecordingRunner`-bound test never reaches Apple `container` for
        /// pullImage / setupNetwork / build, even on hosts where the runtime
        /// is unavailable.
        case swiftAPI(name: String)
    }

    public let kind: Kind
    /// For shell-out kinds (`.streaming` / `.awaitOnly` / `.probe`) the first
    /// element is the executable (today always `"container"`, but the
    /// `ComposeWatch` helpers shell out to `"container-compose"`).
    ///
    /// For `.swiftAPI(name:)` this is the parsed-argument array that would
    /// be handed to `Application.<name>.parse(argv)` — there is no executable
    /// prefix because the call is in-process.
    public let argv: [String]
    /// Optional working directory; nil means "inherit caller's cwd".
    /// Ignored by `.swiftAPI` (in-process calls inherit the host process cwd).
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

/// The concrete `RunCommandRunner` used in production.
///
/// Behaviour parity invariants:
/// - `executableURL` resolved via `BinaryResolver` once per process for
///   `container` and `container-compose` (CHAOS-1421 narrows the original
///   plan §5 invariant; see `docs/reviews/path-execution-audit-2026-05-05.md`).
///   Honors `CONTAINER_COMPOSE_CONTAINER_BIN` and `CONTAINER_COMPOSE_SELF_BIN`
///   overrides; surfaces `RuntimeError.cliBinaryNotFound` /
///   `RuntimeError.binaryOverrideInvalid` instead of the historic exit-127.
/// - `arguments = Array(argv.dropFirst())` — argv[0] used to be the program
///   name consumed by `/usr/bin/env`; the resolver consumes it now.
/// - `currentDirectoryURL = cwd ?? FileManager.default.currentDirectoryPath`.
/// - Child `PATH` is still injected with the same hardcoded value so the
///   resolved binary's own subprocess lookups stay predictable.
/// - `.streaming` with non-nil closures: data routed through closures.
/// - `.streaming` with nil closures: stdout to `print(_:terminator:)`,
///   stderr to `fputs(_:stderr)` (preserves `ComposeRun.streamCommand` parity).
/// - `.awaitOnly`: stdio inherited (no pipes wired).
/// - `.probe`: stdio sent to `/dev/null`; exit==0 ⇒ `probeAvailable: true`.
///   Probe swallows resolver errors and returns `probeAvailable: false`,
///   since "feature unavailable" is the right semantic when the binary is
///   missing — the streaming/await paths surface the real diagnostic.
///
/// Non-zero exit codes are returned via `RunResult.exitCode`, never thrown.
/// Caller-side error translation per plan §10 Q4.
public struct ProductionRunner: RunCommandRunner {
    public init() {}

    /// Cached absolute path to Apple's `container` CLI.
    /// `static let` is lazy in Swift, so resolution happens at first use and
    /// the result (URL or error) is materialized exactly once per process.
    static let containerBin: Result<URL, RuntimeError> =
        BinaryResolver.cachedResolve("container", envOverride: "CONTAINER_COMPOSE_CONTAINER_BIN")

    /// Cached absolute path to this binary, used by `ComposeWatch` self-invocation.
    static let selfBin: Result<URL, RuntimeError> =
        BinaryResolver.cachedResolve("container-compose", envOverride: "CONTAINER_COMPOSE_SELF_BIN")

    /// Pick the right cached binary for an argv whose first element is the
    /// program name (`"container"` or `"container-compose"`).
    fileprivate static func resolveBinary(forArgv argv: [String]) throws -> URL {
        let cached: Result<URL, RuntimeError> = (argv.first == "container-compose") ? selfBin : containerBin
        return try cached.get()
    }

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

        case .swiftAPI(let name):
            try await dispatchSwiftAPI(name: name, argv: request.argv)
            return RunResult(exitCode: 0, probeAvailable: false)
        }
    }

    /// Production dispatch for `.swiftAPI(name:)` requests. Each branch is
    /// the byte-for-byte equivalent of the original in-process call site
    /// (see plan §5 byte-for-byte invariant).
    ///
    /// Adding a new `.swiftAPI(name:)` value here is the contract for
    /// extending the seam with another upstream call.
    private func dispatchSwiftAPI(name: String, argv: [String]) async throws {
        switch name {
        case "ImagePull":
            let cmd = try Application.ImagePull.parse(argv)
            do {
                try await cmd.run()
            } catch {
                if let mapped = Self.imagePullNotFoundError(from: error, argv: argv) {
                    throw mapped
                }
                throw error
            }
        case "NetworkCreate":
            let cmd = try Application.NetworkCreate.parse(argv)
            try await cmd.run()
        case "BuildCommand":
            var cmd = try Application.BuildCommand.parse(argv)
            try cmd.validate()
            try await cmd.run()
        default:
            throw NSError(
                domain: "RunCommandRunner",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "ProductionRunner has no swiftAPI dispatch for name=\(name); add it in Sources/Container-Compose/Runtime/RunCommandRunner.swift."
                ]
            )
        }
    }

    static func imagePullNotFoundError(from error: Error, argv: [String]) -> RuntimeError? {
        guard isImageNotFoundError(error) else { return nil }

        return RuntimeError.imageNotFound(
            reference: imageReference(fromImagePullArgv: argv)
        )
    }

    private static func isImageNotFoundError(_ error: Error) -> Bool {
        let descriptions = [
            String(describing: error),
            String(reflecting: error),
            (error as NSError).localizedDescription
        ]

        return descriptions.contains { description in
            let lowercased = description.lowercased()
            return lowercased.contains("not found") || containsStatus404(lowercased)
        }
    }

    private static func containsStatus404(_ description: String) -> Bool {
        description.split(whereSeparator: { !$0.isNumber }).contains { $0 == "404" }
    }

    private static func imageReference(fromImagePullArgv argv: [String]) -> String {
        var skipNextValue = false
        for arg in argv {
            if skipNextValue {
                skipNextValue = false
                continue
            }

            if arg == "--platform" {
                skipNextValue = true
                continue
            }

            if arg.hasPrefix("--platform=") || arg.hasPrefix("-") {
                continue
            }

            return arg
        }

        return "<unknown>"
    }

    // MARK: - Private spawners
    //
    // Each spawner is a verbatim port of an existing helper body (modulo the
    // argv-as-array parameterisation). PR-2..5 will delete the originals.

    /// Mirrors the deleted `ComposeUp.streamCommand` / `ComposeRun.streamCommand`
    /// helpers, with one upgrade per PLAN.md §4: stdout/stderr are buffered
    /// per-handle until newline-terminated lines can be emitted, so each
    /// `onStdout`/`onStderr` invocation receives exactly one complete line
    /// (no trailing `\n`). This fixes the column-wrap bug where the upstream
    /// callers (e.g. `ComposeUp.configService`'s `handleOutput`) prefix every
    /// invocation with `"<service>: "` — previously each transport-chunk
    /// boundary was treated as a line boundary, yielding fragmented prefixed
    /// output.
    ///
    /// When `onStdout`/`onStderr` are nil, falls through to `print(line)` /
    /// `fputs("<line>\n", stderr)` — both add a trailing newline (matching
    /// the pre-fix `print(_:terminator:"")` / `fputs(_:stderr)` behaviour for
    /// newline-terminated streams, while now correctly buffering chunks split
    /// across reads).
    private func spawnStreaming(
        argv: [String],
        cwd: String?,
        onStdout: (@Sendable (String) -> Void)?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> Int32 {
        let resolvedBin = try Self.resolveBinary(forArgv: argv)
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = resolvedBin
            process.arguments = Array(argv.dropFirst())
            process.currentDirectoryURL = URL(
                fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath
            )
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": BinaryResolver.resolutionPath
            ]) { _, new in new }

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            // PLAN.md §4: one buffer per handle. `readabilityHandler`
            // invocations on a single FileHandle are serialized by the OS,
            // so single-handle access needs no locking.
            let stdoutBuffer = LineBuffer()
            let stderrBuffer = LineBuffer()

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data) { line in
                    if let onStdout {
                        onStdout(line)
                    } else {
                        // ComposeRun parity: write directly to parent stdout
                        // (default `print` terminator is "\n").
                        print(line)
                    }
                }
            }

            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrBuffer.append(data) { line in
                    if let onStderr {
                        onStderr(line)
                    } else {
                        // ComposeRun parity: write directly to parent stderr.
                        fputs("\(line)\n", stderr)
                    }
                }
            }

            process.terminationHandler = { proc in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                // Flush any trailing partial line (process exited without a
                // final newline). `LineBuffer.flush` is a no-op on empty.
                stdoutBuffer.flush { line in
                    if let onStdout {
                        onStdout(line)
                    } else {
                        print(line)
                    }
                }
                stderrBuffer.flush { line in
                    if let onStderr {
                        onStderr(line)
                    } else {
                        fputs("\(line)\n", stderr)
                    }
                }
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
        let resolvedBin = try Self.resolveBinary(forArgv: argv)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            let proc = Process()
            proc.executableURL = resolvedBin
            proc.arguments = Array(argv.dropFirst())
            proc.currentDirectoryURL = URL(
                fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath
            )
            proc.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": BinaryResolver.resolutionPath
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
        // Probe semantics: "is this feature available?" — swallow resolver
        // errors (binary missing or override invalid) and return false.
        // Streaming/await paths surface the real diagnostic when actually used.
        guard let resolvedBin = try? Self.resolveBinary(forArgv: argv) else {
            return false
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let proc = Process()
            proc.executableURL = resolvedBin
            proc.arguments = Array(argv.dropFirst())
            if let cwd {
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": BinaryResolver.resolutionPath
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

// MARK: - BinaryResolver

/// Resolves the absolute path to a binary by searching a fixed PATH list,
/// optionally honoring an env-var override. Centralizes the PATH literal that
/// previously lived inside three `Process()` spawners (CHAOS-1421;
/// `docs/reviews/path-execution-audit-2026-05-05.md`).
///
/// Lookup precedence:
/// 1. If `envOverride` is set in the process environment and non-empty:
///    - If the path is executable → use it.
///    - If the path is set but NOT executable → throw
///      `RuntimeError.binaryOverrideInvalid`. Setting the override is a user
///      contract; falling back silently to the PATH walk would hide a config
///      error.
/// 2. Otherwise walk `resolutionPath` and return the first executable found.
/// 3. If neither path locates an executable, return nil.
enum BinaryResolver {
    /// Hardcoded resolution PATH. Mirrors the union of common macOS binary
    /// locations across Apple Silicon (`/opt/homebrew/bin`) and Intel
    /// (`/usr/local/bin`) installs, plus the system defaults.
    static let resolutionPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Resolve `name` against the resolution PATH, optionally honoring an
    /// env-var override. See type doc for precedence rules.
    static func resolve(_ name: String, envOverride: String) throws -> URL? {
        if let override = ProcessInfo.processInfo.environment[envOverride], !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw RuntimeError.binaryOverrideInvalid(envVar: envOverride, path: override)
            }
            return URL(fileURLWithPath: override)
        }
        for dir in resolutionPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Resolve and pre-materialize as a `Result` for `static let` caching.
    /// Translates a nil PATH-walk result into `RuntimeError.cliBinaryNotFound`
    /// so the cached value is always either a usable URL or a typed error.
    static func cachedResolve(_ name: String, envOverride: String) -> Result<URL, RuntimeError> {
        do {
            if let url = try resolve(name, envOverride: envOverride) {
                return .success(url)
            }
            return .failure(.cliBinaryNotFound(binary: name, searchPath: resolutionPath))
        } catch let err as RuntimeError {
            return .failure(err)
        } catch {
            return .failure(.backendFailure(message: error.localizedDescription))
        }
    }
}

// MARK: - LineBuffer

/// Buffers byte chunks read from a streaming `FileHandle` until newline-
/// terminated lines can be emitted. Fixes the log column-wrap bug
/// (PLAN.md §4) where transport-chunk boundaries were being treated as
/// line boundaries by `ProductionRunner.spawnStreaming`.
///
/// `readabilityHandler` invocations on a given `FileHandle` are serialized
/// by the OS, so this class needs no internal locking for single-handle
/// use. Each `spawnStreaming` invocation creates two independent buffers
/// (one for stdout, one for stderr).
///
/// Contract:
/// - Splits only on `\n` (0x0A). `\r\n` line endings will leave the `\r`
///   attached to the emitted line (we do not strip it). This matches the
///   pre-fix behaviour of treating bytes verbatim.
/// - Drops invalid UTF-8 lines silently rather than emitting garbage.
///   (A partial multi-byte UTF-8 sequence at the end of a chunk stays
///   buffered until the rest arrives, so well-formed UTF-8 is preserved.)
///
/// `internal` (rather than `private`) so unit tests can exercise it
/// directly via `@testable import ContainerComposeCore`.
final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()

    /// Append `data`, then invoke `emit` once per complete `\n`-terminated
    /// line found in the accumulated buffer. The trailing `\n` is stripped
    /// before emission. Any partial line at the end stays buffered.
    func append(_ data: Data, emit: (String) -> Void) {
        buffer.append(data)
        while let nlIdx = buffer.firstIndex(of: 0x0A) {  // '\n'
            let lineData = buffer[buffer.startIndex..<nlIdx]
            if let line = String(data: Data(lineData), encoding: .utf8) {
                emit(line)
            }
            // Drop emitted bytes + the newline.
            buffer.removeSubrange(buffer.startIndex...nlIdx)
        }
    }

    /// Emit any remaining buffered bytes as a final line (no trailing
    /// newline expected on EOF). Call this from `terminationHandler` after
    /// the readability handlers have been nil'd. No-op if buffer is empty.
    func flush(emit: (String) -> Void) {
        guard !buffer.isEmpty else { return }
        if let line = String(data: buffer, encoding: .utf8) {
            emit(line)
        }
        buffer.removeAll()
    }
}
