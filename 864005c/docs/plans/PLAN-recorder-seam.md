# PLAN — `RunCommandRecorder` Protocol Seam

_Plan author: Planner-D. Date: 2026-04-27._
_Refs: `PLAN.md` §1 (entrypoint bug), §2 layer B (recorder/fake), §3.1 option 3 (recorder seam)._

This document is a file-level execution plan for introducing a single seam through which every `container <subcommand>` invocation flows, so a `RecordingRunner` test double can drive the production command builders end-to-end and assert exact argv shapes — without Apple `container` being installed. It is structured so a downstream agent can execute it mechanically, PR by PR, with `swift test` green at every step.

---

## 1. Goal & non-goals

### Goal

Establish argv-shape regression coverage on CI for every `container run` / `container create` / `container kill` / `container start` / `container exec` invocation that `Container-Compose` emits. Today the only such coverage is the **dynamic** test target gated on `RuntimeAvailability.isAvailable()`, which is `false` on the GitHub macOS runner. The whole class of bugs documented in `PLAN.md §1` (entrypoint placed after the image at three different sites) is therefore invisible to CI. The seam introduced by this plan lets a static-only test target push compose YAML through the real `ComposeUp.run()` / `ComposeRun.run()` / `ComposeCreate.run()` / `ComposeBuild.run()` code paths and assert the exact `[String]` argv that *would* have been handed to Apple `container`, with zero subprocess execution.

### Non-goals

- **Not** replacing the dynamic test target. Dynamic tests still exist and still cover real-runtime invariants the recorder cannot — process exit semantics, container snapshot fields, kernel-system-start side effects.
- **Not** changing runtime behavior. After PR-1 lands, the production binding wraps the existing `streamCommand` / `shellCreate` / sibling helpers byte-for-byte; the only difference is the call site goes through one extra method dispatch. If a user's `compose up` produces argv X today, it must produce argv X after every PR in this sequence.
- **Not** trying to refactor the `Application.BuildCommand.parse(...).run()` path through the seam in PR-1. That path is a Swift API call into the upstream `container` package, not a shell-out — see §3 for the rationale and §9 for when (if ever) we revisit it.
- **Not** rebuilding the per-concern `*Args.build` builders. They already exist (`Compose+ArgsLifecycle.swift` etc.) and are pure; they are *consumers* of the seam (their output is what gets recorded), not part of it.

---

## 2. Inventory of shell-out sites

Every place in `Sources/Container-Compose/` that hands work to the Apple `container` runtime today. Two families:

- **Shell-out** — spawn `/usr/bin/env container ...` via `Process()`.
- **In-process** — call `Application.<Subcommand>.parse(...).run()` from the upstream `container` Swift package.

| File | Line(s) | Function / call site | Kind | Today's call | What it shells |
| --- | --- | --- | --- | --- | --- |
| `ComposeUp.swift` | 587 | `configService` (Task body) | shell-out (stream) | `streamCommand("container", args: ["run"] + runCommandArgs, …)` | `container run` for each service |
| `ComposeUp.swift` | 412–413 | `setupNetwork` | in-process | `Application.NetworkCreate.parse(...).run()` | `container network create` |
| `ComposeUp.swift` | 644–645 | `pullImage` | in-process | `Application.ImagePull.parse(...).run()` | `container image pull` |
| `ComposeUp.swift` | 762–766 | `buildService` | in-process | `Application.BuildCommand.parse(...).validate()/.run()` | `container build` |
| `ComposeUp.swift` | 854–906 | `streamCommand` | shell-out impl | wraps `Process()` | (the helper itself) |
| `ComposeRun.swift` | 308 | `run` (final shell-out) | shell-out (stream) | `streamCommand("container", args: ["run"] + runArgs, …)` | `container run` one-off |
| `ComposeRun.swift` | 352–353 | `pullImage` | in-process | `Application.ImagePull.parse(...).run()` | `container image pull` |
| `ComposeRun.swift` | 359–406 | `streamCommand` | shell-out impl | wraps `Process()` | (the helper itself) |
| `ComposeCreate.swift` | 429 | `createService` | shell-out (await-only) | `shellCreate(containerName:args:)` | `container create` |
| `ComposeCreate.swift` | 206–207 | `pullImage` | in-process | `Application.ImagePull.parse(...).run()` | `container image pull` |
| `ComposeCreate.swift` | 290–294 | `buildService` | in-process | `Application.BuildCommand.parse(...).validate()/.run()` | `container build` |
| `ComposeCreate.swift` | 334–335 | `setupNetwork` | in-process | `Application.NetworkCreate.parse(...).run()` | `container network create` |
| `ComposeCreate.swift` | 438–475 | `shellCreate` | shell-out impl | wraps `Process()` | (the helper itself) |
| `ComposeCreate.swift` | 478–497 | `checkCreateSupported` | shell-out (probe) | wraps `Process()` running `container create --help` | capability probe |
| `ComposeBuild.swift` | 230–232 | `buildService` | in-process | `Application.BuildCommand.parse(...).validate()/.run()` | `container build` |
| `ComposePull.swift` | 207–208 | (pull helper) | in-process | `Application.ImagePull.parse(...).run()` | `container image pull` |
| `ComposeKill.swift` | 132 | `killServices` loop | shell-out (await-only) | `shellKill(containerName:)` | `container kill --signal …` |
| `ComposeKill.swift` | 140–168 | `shellKill` | shell-out impl | wraps `Process()` | (the helper itself) |
| `ComposeStart.swift` | 134 | `startServices` loop | shell-out (await-only) | `shellStart(containerName:)` | `container start --detach` |
| `ComposeStart.swift` | 142–170 | `shellStart` | shell-out impl | wraps `Process()` | (the helper itself) |
| `ComposeExec.swift` | 172 | `run` final | shell-out (stream) | `shellExec(args:)` | `container exec …` |
| `ComposeExec.swift` | 178–225 | `shellExec` | shell-out impl | wraps `Process()` | (the helper itself) |
| `ComposeWatch.swift` | 153, 155, 179, 193, 202 | `WatchLoop.handleAction` | shell-out (fire-and-forget) | private `shell([…], cwd:)` | `container-compose <sub>` (re-entrant, **not** `container`) |
| `ComposeWatch.swift` | 208–225 | `WatchLoop.shell` | shell-out impl | wraps `Process()` | (the helper itself) |
| `Tests/TestHelpers/RuntimeAvailability.swift` | 30–46 | `isAvailable()` | shell-out (probe) | wraps `Process()` running `container --version` | runtime probe; **out of scope** |

Two observations:

1. The `ComposeWatch` shell-outs are re-invocations of `container-compose` itself (they call `["container-compose", "build", svc]` etc., not `container`). They flow through the seam at the level of *the watch fork*, not at the `container` argv level. Routing them through the runner is still useful (so tests can assert "watch triggered a rebuild for svc X"), but it is a different kind of recording from `container run` argv. **Plan: route them, but mark as a separate recording lane.**
2. `RuntimeAvailability.isAvailable()` lives in `Tests/TestHelpers/`, runs at suite-trait time, and is unrelated to production behavior. It does not go through the seam.

---

## 3. Protocol shape

### Decision: one protocol with a discriminated request type

I considered two protocols (one streaming, one await-only) and rejected it: that splits call sites into two ergonomic lanes for what is fundamentally the same operation ("hand argv to the container runtime"), and forces test code to figure out which lane each call landed in. Instead, model the request as a value type with a `kind` discriminator and a single protocol method.

```swift
import Foundation

/// One thing the runner can be asked to do. Captures argv shape + how output
/// should be drained. Time-ordering of multiple requests is captured by the
/// recorder, not by the request itself.
public struct RunRequest: Sendable, Equatable {
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
}

/// What a runner returns. Mirrors `CommandResult` in `Helper Functions.swift`
/// closely so existing call sites translate easily.
public struct RunResult: Sendable, Equatable {
    public let exitCode: Int32
    /// Only populated for `.probe` calls (production binding reads exit
    /// status). For `.streaming` / `.awaitOnly` we don't capture stdout —
    /// the production helpers stream it to closures or to the parent stdio
    /// already.
    public let probeAvailable: Bool
}

/// The seam every command goes through to talk to the Apple `container`
/// runtime (or to itself, in the `ComposeWatch` self-invocation case).
public protocol RunCommandRunner: Sendable {
    /// Hand a request to the runner. For streaming requests, the supplied
    /// stdout/stderr closures may be invoked any number of times before the
    /// returned RunResult.
    func run(
        _ request: RunRequest,
        onStdout: (@Sendable (String) -> Void)?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> RunResult
}
```

### Why one protocol instead of two

- **Test ergonomics.** The recorder needs a single ordered log. Splitting "streaming" and "await-only" into separate protocols means the recorder has to merge two ordered lists post-hoc to assert "compose up did `pull foo` then `network create bar` then `run baz`". Time-ordering is the cheap, easy thing to lose.
- **Production ergonomics.** Both today's `streamCommand` and today's `shellCreate` already build a `Process()`, set the same `PATH`, and `try proc.run()`. The only divergence is whether they wire pipes vs. await termination. The production binding can switch on `kind` once and reuse the rest.
- **Sendable / actor isolation.** `RunRequest` and `RunResult` are pure value types — `Sendable` for free. The protocol method is `async throws`; the closures are `@Sendable`. The recorder's storage is an `actor` (see §6); the production binding is `Sendable` because it has no mutable state.

### Why `BuildCommand.parse(...).run()` stays out of the seam (for now)

`Application.BuildCommand.parse(commands).run()` is **not** a shell-out. It is a direct call into the upstream `container` Swift package. Plumbing it through `RunRequest` would require either (a) inventing a fake `BuildCommand` subtype that satisfies the upstream type (impossible without source-patching the dependency) or (b) wrapping the call so the recorder gets the `commands` array as argv.

Option (b) is doable and is the right long-term move because it gives `ComposeBuild` argv-shape coverage equal to `ComposeUp`. But it requires a `RunRequest.Kind.swiftAPI` variant whose production binding is `try Application.BuildCommand.parse(commands).run()`, while the recorder binding is "log argv and return success." That couples the seam to the upstream package's exact public surface (`BuildCommand`, `ImagePull`, `NetworkCreate`), which is risky if the upstream renames things.

**Decision:** PR-1 ships only the shell-out family (`streaming`, `awaitOnly`, `probe`). PR-6 (per §9) extends the protocol with a `swiftAPI` case for `BuildCommand` / `ImagePull` / `NetworkCreate` — if and only if a build-argv regression motivates it. Until then, those call sites stay direct.

### Sendable / Swift 6 concurrency

- `RunRequest`, `RunResult`: trivially `Sendable` (no reference types).
- `RunCommandRunner`: `Sendable` protocol; conforming production type holds no mutable state, so it is `Sendable` without ceremony.
- `RecordingRunner` (test type, §6): backed by an `actor` for thread-safe append. The protocol method is `async`, so `await`ing the actor is natural.
- The `@TaskLocal` injection (§4) is `Sendable` — `@TaskLocal` requires its value type to be `Sendable`, and `(any RunCommandRunner)?` is `Sendable` because the protocol is.

---

## 4. Injection mechanism

Three options compared.

### (a) Task-local

```swift
public enum RunnerEnvironment {
    @TaskLocal public static var current: (any RunCommandRunner) = ProductionRunner()
}
```

Test setup:
```swift
try await RunnerEnvironment.$current.withValue(recorder) {
    var cmd = try ComposeUp.parse([...])
    try await cmd.run()
}
```

Production setup: nothing — the default value (`ProductionRunner()`) is used.

| Axis | Rating |
| --- | --- |
| Production ergonomics | Excellent — call sites just write `RunnerEnvironment.current` |
| Test setup ergonomics | Excellent — wrap once at suite level via Swift Testing trait |
| Swift 6 concurrency | Native — `@TaskLocal` is the canonical Swift 6 mechanism |
| Risk | Task-locals don't propagate to `Task { }` blocks not started via `Task.detached(operation:)` — but `ComposeUp.swift:578` *does* spawn an unstructured `Task { }` for streaming, which **does** inherit task-locals. ✓ |

### (b) Type-erased property/parameter

Add `var runner: (any RunCommandRunner)? = nil` to every `*Command` struct, and a public initializer parameter or a `setRunner(_:)` method. Tests must remember to set it on every parsed command.

| Axis | Rating |
| --- | --- |
| Production ergonomics | Mildly worse — every command grows a property; default must be wired |
| Test setup ergonomics | Worse — every test that parses a command must remember to set the runner; easy to forget |
| Swift 6 concurrency | Fine; commands are already `@unchecked Sendable` |
| Risk | High footgun: a missed setter call silently runs the production binding in a test |

### (c) Static singleton with swap setter

```swift
public enum Runners {
    public nonisolated(unsafe) static var current: any RunCommandRunner = ProductionRunner()
}
```

Tests do `Runners.current = recorder` in a `setUp`, restore in `tearDown`.

| Axis | Rating |
| --- | --- |
| Production ergonomics | Excellent |
| Test setup ergonomics | Mediocre — global mutable state, must remember to restore; no per-test isolation |
| Swift 6 concurrency | Bad — `nonisolated(unsafe)` is a code smell; concurrent tests step on each other |
| Risk | Tests that run in parallel (Swift Testing's default!) will race on the global |

### Decision: (a) Task-local

Task-locals are the only option that gives per-test isolation under Swift Testing's parallel execution and that propagates correctly into the unstructured `Task { }` at `ComposeUp.swift:578`. The Swift 6 ergonomics are best-in-class — this is exactly the pattern the language was designed for. The single caveat (`Task.detached` does *not* inherit task-locals) is irrelevant here because we don't use `Task.detached` in any command. If we ever do, we re-bind the task-local at the boundary.

```swift
// Final shape:
public enum RunnerEnvironment {
    /// Default is the production binding so `ProductionRunner()` is "free"
    /// (no nil checks at every call site).
    @TaskLocal public static var current: any RunCommandRunner = ProductionRunner()
}
```

Call sites simply read `RunnerEnvironment.current` (no `?` unwrap).

---

## 5. Production binding

A single concrete type that wraps the existing helpers byte-for-byte.

```swift
import Foundation

public struct ProductionRunner: RunCommandRunner {
    public init() {}

    public func run(
        _ request: RunRequest,
        onStdout: (@Sendable (String) -> Void)?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> RunResult {
        switch request.kind {
        case .streaming:
            // Existing ComposeUp.streamCommand body — verbatim — but
            // generalised over the executable. Old call: streamCommand(
            //   "container", args: [...], onStdout: ..., onStderr: ...).
            // New call: spawn argv[0] with argv[1...].
            let exit = try await spawnStreaming(
                argv: request.argv,
                cwd: request.cwd,
                onStdout: onStdout ?? { _ in },
                onStderr: onStderr ?? { _ in }
            )
            return RunResult(exitCode: exit, probeAvailable: false)

        case .awaitOnly:
            // Existing shellCreate / shellKill / shellStart pattern.
            let exit = try await spawnAwait(
                argv: request.argv,
                cwd: request.cwd
            )
            return RunResult(exitCode: exit, probeAvailable: false)

        case .probe:
            // Existing checkCreateSupported pattern — null both stdio,
            // return exit==0 as bool.
            let ok = await spawnProbe(
                argv: request.argv,
                cwd: request.cwd
            )
            return RunResult(exitCode: ok ? 0 : 1, probeAvailable: ok)
        }
    }

    // MARK: - Private spawners (each is a verbatim move of the existing
    // body in ComposeUp/ComposeRun/ComposeCreate/ComposeKill/ComposeStart/
    // ComposeExec.)

    private func spawnStreaming(
        argv: [String],
        cwd: String?,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        // Body lifted from ComposeUp.swift:854-906 with the exec name
        // generalised: process.arguments = argv (instead of [command] + args).
        // Cwd defaulted to FileManager.default.currentDirectoryPath when nil.
        // PATH-merge identical to existing helpers.
        ...
    }

    private func spawnAwait(argv: [String], cwd: String?) async throws -> Int32 {
        // Body lifted from ComposeCreate.shellCreate (lines 448-474), with
        // arguments = argv.
        ...
    }

    private func spawnProbe(argv: [String], cwd: String?) async -> Bool {
        // Body lifted from ComposeCreate.checkCreateSupported (lines 479-497).
        ...
    }
}
```

### Byte-for-byte invariants

- `executableURL = URL(fileURLWithPath: "/usr/bin/env")` — identical.
- `process.arguments = argv` where `argv = ["container", "run", ...]` (callers prepend `"container"`).
- `currentDirectoryURL = URL(fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath)`.
- `process.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"]) { _, new in new }` — identical.
- Pipes wired exactly as today (streaming reads `availableData`, decodes UTF-8, calls closure; await-only does not pipe).
- Termination handler resumes the continuation with `terminationStatus`; await-only path translates non-zero into `NSError(domain: …)` matching the existing `ComposeCreate` / `ComposeKill` / `ComposeStart` error shape (see §10 risks).

The acceptance test for "byte-for-byte" is: `git diff` of `ProductionRunner` private spawners vs. the corresponding helper bodies, modulo only the argv parameterisation.

---

## 6. Test-only `RecordingRunner`

Implementation lives in `Tests/TestHelpers/RecordingRunner.swift`. (Adding to `TestHelpers/` makes it importable from both static and dynamic test targets.)

```swift
import Foundation
@testable import ContainerComposeCore

/// Captures every RunRequest in time order. Backed by an actor for safe
/// concurrent appends from the unstructured Task in ComposeUp.configService.
public actor RecordingRunner: RunCommandRunner {
    /// One entry per call to run().
    public struct Entry: Sendable, Equatable {
        public let request: RunRequest
        /// Order of arrival, 0-indexed.
        public let sequence: Int
        /// Stdout closures the call site provided (we don't invoke them by
        /// default; tests can opt-in via `stubStdout`).
        public let hadStdoutHandler: Bool
        public let hadStderrHandler: Bool
    }

    public private(set) var entries: [Entry] = []

    /// Stubbed responses keyed by argv prefix (matches longest-prefix-first).
    /// Tests register: `await runner.stub(argvPrefix: ["container","run"], exitCode: 0)`.
    private var exitStubs: [(prefix: [String], exit: Int32)] = []

    /// Stubbed stdout chunks keyed similarly. When a streaming call matches,
    /// each chunk is pushed to the call site's onStdout closure before the
    /// runner returns.
    private var stdoutStubs: [(prefix: [String], chunks: [String])] = []

    /// Stubbed probe answers keyed by full argv equality.
    private var probeStubs: [[String]: Bool] = [:]

    public init() {}

    // MARK: - Configuration

    public func stub(argvPrefix: [String], exitCode: Int32) {
        exitStubs.append((argvPrefix, exitCode))
    }

    public func stubStdout(argvPrefix: [String], chunks: [String]) {
        stdoutStubs.append((argvPrefix, chunks))
    }

    public func stubProbe(argv: [String], available: Bool) {
        probeStubs[argv] = available
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

        // Replay any stubbed stdout chunks.
        if let onStdout, request.kind == .streaming,
           let stub = stdoutStubs.last(where: { request.argv.starts(with: $0.prefix) }) {
            for chunk in stub.chunks { onStdout(chunk) }
        }

        // Look up exit stub (last registered wins for the same prefix).
        switch request.kind {
        case .probe:
            let ok = probeStubs[request.argv] ?? true
            return RunResult(exitCode: ok ? 0 : 1, probeAvailable: ok)
        case .streaming, .awaitOnly:
            let exit = exitStubs.last(where: { request.argv.starts(with: $0.prefix) })?.exit ?? 0
            return RunResult(exitCode: exit, probeAvailable: false)
        }
    }

    // MARK: - Test affordances

    /// All recorded argvs in order — most assertions use this.
    public func argvs() -> [[String]] { entries.map(\.request.argv) }

    /// Filter to `container run` calls.
    public func runArgvs() -> [[String]] {
        entries.filter { $0.request.argv.starts(with: ["container", "run"]) }
            .map(\.request.argv)
    }
}
```

### Captured fields

- **argv list** — `entries[i].request.argv` (full).
- **cwd** — `entries[i].request.cwd` (optional, distinguishes calls that ran in different working dirs, e.g. ComposeRun and ComposeUp).
- **streaming flag** — `entries[i].request.kind` (`.streaming` vs. `.awaitOnly` vs. `.probe`).
- **time ordering** — `entries[i].sequence` (also implicit in array index, but stored explicitly so a filtered subset still preserves order).
- **handlers present** — `hadStdoutHandler` / `hadStderrHandler` (lets a test assert "yes, ComposeUp wired its colored-output handler").

### Stubbed exit codes / stdout

- `stub(argvPrefix:exitCode:)` for non-zero exit testing (e.g. "what if `container run` fails for service db?").
- `stubStdout(argvPrefix:chunks:)` for tests that exercise the colored output path or the per-line wrap behavior noted in `PLAN.md §4`.
- `stubProbe(argv:available:)` is what makes `ComposeCreate.checkCreateSupported` testable on CI: tests can flip "create supported" on/off without spawning subprocess.

---

## 7. Per-file call-site changes

Real line numbers from `main` as of 2026-04-27. After the seam exists, every shell-out site changes mechanically:

### `Sources/Container-Compose/Commands/ComposeUp.swift`

- **L587** — replace
  ```swift
  let _ = try await streamCommand("container", args: ["run"] + runCommandArgs, onStdout: handleOutput, onStderr: handleOutput)
  ```
  with
  ```swift
  let _ = try await RunnerEnvironment.current.run(
      RunRequest(kind: .streaming, argv: ["container", "run"] + runCommandArgs, cwd: cwd),
      onStdout: handleOutput,
      onStderr: handleOutput
  )
  ```
- **L854–906** — `streamCommand` method body deleted. The extension can be removed in PR-3 once `ComposeRun`'s copy is also gone.
- **L412–413** (`Application.NetworkCreate.parse(...).run()`), **L644–645** (`Application.ImagePull`), **L762–766** (`Application.BuildCommand`) — **untouched in the shell-out seam PRs.** Revisited in PR-6 (§9) only if needed.

### `Sources/Container-Compose/Commands/ComposeRun.swift`

- **L308** — replace
  ```swift
  let _ = try await streamCommand("container", args: ["run"] + runArgs, cwd: cwd)
  ```
  with
  ```swift
  let _ = try await RunnerEnvironment.current.run(
      RunRequest(kind: .streaming, argv: ["container", "run"] + runArgs, cwd: cwd),
      onStdout: nil,
      onStderr: nil
  )
  ```
  (ComposeRun's existing helper writes directly to stdout/stderr — pass `nil` closures and let the production runner do the same parent-stdio fall-through, see §10.)
- **L297–299** — fix the entrypoint placement bug at the same time the seam swap lands. Replace
  ```swift
  } else if let entrypointParts = service.entrypoint {
      runArgs.append("--entrypoint")
      runArgs.append(contentsOf: entrypointParts)
  } else if let commandParts = service.command {
      runArgs.append(contentsOf: commandParts)
  }
  ```
  with the corrected ordering described in `PLAN.md §1` (insert `--entrypoint <head>` *before* the image at L292, append tail + command after).
- **L359–406** — `streamCommand` method body deleted.

### `Sources/Container-Compose/Commands/ComposeCreate.swift`

- **L429** — replace
  ```swift
  try await shellCreate(containerName: containerName, args: createArgs)
  ```
  with
  ```swift
  let probeResult = try await RunnerEnvironment.current.run(
      RunRequest(kind: .probe, argv: ["container", "create", "--help"], cwd: cwd),
      onStdout: nil, onStderr: nil
  )
  guard probeResult.probeAvailable else {
      print("Warning: Apple container doesn't support 'create'; please use 'compose up' instead.")
      return
  }
  let _ = try await RunnerEnvironment.current.run(
      RunRequest(
          kind: .awaitOnly,
          argv: ["container", "create", "--name", containerName] + createArgs,
          cwd: cwd
      ),
      onStdout: nil, onStderr: nil
  )
  ```
- **L420–422** — fix the entrypoint placement bug for the create site at the same time. Same correction as ComposeUp/ComposeRun.
- **L438–475** — `shellCreate` method body deleted.
- **L478–497** — `checkCreateSupported` method body deleted (its work is now done via `.probe`).

### `Sources/Container-Compose/Commands/ComposeKill.swift`

- **L132** — replace
  ```swift
  try await shellKill(containerName: container.id)
  ```
  with
  ```swift
  let result = try await RunnerEnvironment.current.run(
      RunRequest(
          kind: .awaitOnly,
          argv: ["container", "kill", "--signal", signal, container.id],
          cwd: cwd
      ),
      onStdout: nil, onStderr: nil
  )
  guard result.exitCode == 0 else {
      throw NSError(
          domain: "ComposeKill",
          code: Int(result.exitCode),
          userInfo: [NSLocalizedDescriptionKey: "container kill exited with status \(result.exitCode)"]
      )
  }
  ```
- **L140–168** — `shellKill` method body deleted.

### `Sources/Container-Compose/Commands/ComposeStart.swift`

- **L134** — replace
  ```swift
  try await shellStart(containerName: containerName)
  ```
  with the equivalent `RunRequest(kind: .awaitOnly, argv: ["container","start","--detach", containerName], cwd: cwd)` call, with the same exit-code-to-NSError translation as ComposeKill above.
- **L142–170** — `shellStart` method body deleted.

### `Sources/Container-Compose/Commands/ComposeExec.swift`

- **L172** — replace
  ```swift
  let _ = try await shellExec(args: execArgs)
  ```
  with
  ```swift
  let _ = try await RunnerEnvironment.current.run(
      RunRequest(kind: .streaming, argv: ["container", "exec"] + execArgs, cwd: cwd),
      onStdout: nil, onStderr: nil
  )
  ```
- **L178–225** — `shellExec` method body deleted.

### `Sources/Container-Compose/Commands/ComposeWatch.swift`

- **L153, L155, L179, L193, L202** — five call sites in `WatchLoop.handleAction`. Each becomes a `RunRequest(kind: .awaitOnly, argv: ["container-compose", ...], cwd: cwd)` through the runner. Tests can assert "watch fired the rebuild flow" without spawning a real `container-compose` subprocess.
- **L208–225** — private `shell([], cwd:)` body deleted.

### `Sources/Container-Compose/Commands/ComposeBuild.swift`

- **No shell-out call sites.** All `Application.BuildCommand.parse(...).run()` calls remain direct. Untouched until PR-6.

---

## 8. Static test plan

New file: **`Tests/Container-Compose-StaticTests/RuntimeArgvTests.swift`**

Each test follows the pattern: write a temp compose YAML, parse the relevant subcommand, bind a `RecordingRunner` via `RunnerEnvironment.$current.withValue(recorder) { try await cmd.run() }`, then assert against `await recorder.argvs()`.

### Test list

#### 1. `up_emits_entrypoint_before_image`

Compose YAML:
```yaml
services:
  app:
    image: alpine:latest
    entrypoint: ["/app/entrypoint.sh"]
```

Assertion:
```swift
let argv = try #require(await recorder.runArgvs().first)
let entryIdx = try #require(argv.firstIndex(of: "--entrypoint"))
let imgIdx = try #require(argv.firstIndex(of: "alpine:latest"))
#expect(entryIdx < imgIdx, "--entrypoint must appear before the image")
#expect(argv[entryIdx + 1] == "/app/entrypoint.sh")
```

This is the regression test for `PLAN.md §1`. It is the only test that can validate the fix without `swift run` against a real container. **PR-A** has already fixed this for the `up` site — this test confirms it stays fixed.

#### 2. `run_emits_entrypoint_before_image`

Same YAML as test 1 plus a `ComposeRun.parse(["app"])`. Same assertion. **Currently red** because `ComposeRun.swift:297-299` still has the inverted ordering. PR-3 in the migration sequence fixes it.

#### 3. `create_emits_entrypoint_before_image`

Same YAML as test 1 plus a `ComposeCreate.parse([])`. Recorder stubs `.probe` for `["container", "create", "--help"]` to `available: true`. Same assertion. **Currently red** because `ComposeCreate.swift:420-422` has the same bug. PR-4 fixes it.

#### 4. `up_entrypoint_with_command_appends_command_to_positional_args`

Compose YAML:
```yaml
services:
  worker:
    image: alpine:latest
    entrypoint: ["/sbin/tini", "--"]
    command: ["my-binary", "--flag"]
```

Assertion: argv contains the sequence
```
["--entrypoint", "/sbin/tini", … (other flags) …, "alpine:latest", "--", "my-binary", "--flag"]
```
i.e. first element of `entrypoint` becomes the `--entrypoint` value, **rest of `entrypoint` appended after image**, then `command` after that. Ensures the canonical "override entrypoint, keep args" docker-compose pattern is preserved.

#### 5. `up_emits_explicit_ip_port_mapping`

Compose YAML:
```yaml
services:
  web:
    image: nginx:alpine
    ports:
      - "127.0.0.1:18081:80"
      - "8080:80/udp"
```

Assertion: argv contains `["-p", "127.0.0.1:18081:80"]` and `["-p", "0.0.0.0:8080:80/udp"]` (matches `composePortToRunArg` semantics in `Helper Functions.swift:117`). Catches port-parsing regressions cheaply on CI — currently this is dynamic-only via `ComposeUpTests.testComposeUpWithExplicitIPPortMapping`.

#### 6. `up_merges_env_file_and_environment`

Compose YAML pointing at `./test.env` containing `KEY=from_file`, plus inline `environment: {KEY: from_inline, OTHER: ${BASE}}` and a `BASE` set in the synthetic `.env`.

Assertion: argv contains `-e KEY=from_inline` (inline wins over env_file), `-e OTHER=<resolved>` (substitution happened), and the original `KEY=from_file` is **not** present.

#### 7. `build_emits_labels_and_cache_from`

Compose YAML with a `build:` block containing `labels` and `cache_from`. (Note: this exercises the `Application.BuildCommand.parse(...)` path. This test will work *only after* PR-6 lifts that path through the seam. Until then, mark with `@Test(.disabled("blocked on PR-6"))` so it ships red-but-skipped from PR-2 onward.)

Assertion: `commands` array passed to BuildCommand contains the expected `--label key=value` pairs and `--cache-from refX` flags.

#### 8. `kill_emits_signal_in_argv`

Compose YAML with two services. Run `ComposeKill.parse(["--signal", "SIGUSR1"])`.

Assertion: every recorded argv starts with `["container", "kill", "--signal", "SIGUSR1", …]`. Order matches reverse topo-sort.

### Suite scaffolding

```swift
import Testing
import Foundation
@testable import ContainerComposeCore
import TestHelpers

@Suite("Runtime argv recording")
struct RuntimeArgvTests {
    private func runWithRecorder(
        _ body: () async throws -> Void
    ) async throws -> RecordingRunner {
        let recorder = RecordingRunner()
        try await RunnerEnvironment.$current.withValue(recorder) {
            try await body()
        }
        return recorder
    }

    @Test("up: --entrypoint before image (entrypoint head only)")
    func upEntrypointBeforeImage() async throws { ... }
    // ... etc, one @Test per case above.
}
```

---

## 9. Migration order (sequenced PRs)

Each PR keeps `swift test` green at the boundary. The entrypoint bug fixes are deliberately sequenced *after* the corresponding test exists — that way each fix is a red→green flip in a single CI run.

### PR-1 — protocol + production binding + task-local + RecordingRunner (~150 lines)

**Scope**: Add the seam infrastructure. No call sites switched.

**Files touched**:
- `Sources/Container-Compose/Runtime/RunCommandRunner.swift` (new) — `RunRequest`, `RunResult`, `RunCommandRunner` protocol, `ProductionRunner` struct, `RunnerEnvironment` task-local.
- `Tests/TestHelpers/RecordingRunner.swift` (new) — actor implementation per §6.

**CI**: Existing `swift test` still passes — nothing depends on the new types yet. The new types are unused in production until PR-2.

**Diff size**: ~150 lines added, 0 removed.

### PR-2 — switch ComposeUp + add RuntimeArgvTests for up (~250 lines)

**Scope**: Route `ComposeUp.swift:587` through the runner; delete `ComposeUp.streamCommand`. Add tests 1, 4, 5, 6, 8 (the ones that drive `compose up`).

**Files touched**:
- `Sources/Container-Compose/Commands/ComposeUp.swift` — L587 swap, L854–906 deletion.
- `Tests/Container-Compose-StaticTests/RuntimeArgvTests.swift` (new).

**CI**: Test 1 passes (PR-A already fixed `up`'s entrypoint bug). Tests 4–6, 8 pass.

**Diff size**: ~80 lines source removed, ~250 lines tests added.

### PR-3 — switch ComposeRun + fix run entrypoint bug + add test 2 (~120 lines)

**Scope**: Route `ComposeRun.swift:308` through the runner; fix the inverted entrypoint ordering at L297–299 in the same commit. Add test 2 to `RuntimeArgvTests`.

**Files touched**:
- `Sources/Container-Compose/Commands/ComposeRun.swift` — L297–299 fix, L308 swap, L359–406 deletion.
- `Tests/Container-Compose-StaticTests/RuntimeArgvTests.swift` — add `run_emits_entrypoint_before_image`.

**CI**: Test 2 was red on `main`; now green. All other tests unchanged.

**Diff size**: ~50 lines source removed, ~30 lines added.

### PR-4 — switch ComposeCreate + fix create entrypoint bug + add test 3 (~140 lines)

**Scope**: Route `ComposeCreate.shellCreate` and `checkCreateSupported` through the runner; fix the inverted entrypoint ordering at L420–422. Add test 3 to `RuntimeArgvTests`.

**Files touched**:
- `Sources/Container-Compose/Commands/ComposeCreate.swift` — L420–422 fix, L429 swap (calls .probe + .awaitOnly), L438–475 deletion, L478–497 deletion.
- `Tests/Container-Compose-StaticTests/RuntimeArgvTests.swift` — add `create_emits_entrypoint_before_image`.

**CI**: Test 3 was red on `main`; now green.

**Diff size**: ~70 lines source removed, ~50 lines source/test added.

### PR-5 — switch remaining shell-outs (Kill, Start, Exec, Watch) (~150 lines)

**Scope**: Route the remaining four commands through the runner. No new tests required for green CI, but add `kill_emits_signal_in_argv` (test 8) to lock in the kill argv shape.

**Files touched**:
- `Sources/Container-Compose/Commands/ComposeKill.swift` — L132 swap, L140–168 deletion.
- `Sources/Container-Compose/Commands/ComposeStart.swift` — L134 swap, L142–170 deletion.
- `Sources/Container-Compose/Commands/ComposeExec.swift` — L172 swap, L178–225 deletion.
- `Sources/Container-Compose/Commands/ComposeWatch.swift` — five call site swaps in `WatchLoop`, L208–225 deletion.

**Diff size**: ~140 lines source removed, ~50 lines added.

### PR-6 (optional, when motivated) — `BuildCommand` / `ImagePull` / `NetworkCreate` through the seam

**Scope**: Add a `RunRequest.Kind.swiftAPI` case (or, alternatively, an `argvOnly` recorder mode that captures the parsed argv without invoking the upstream `Application.*` types). Switch the seven in-process call sites listed in §2. Enable test 7 (`build_emits_labels_and_cache_from`).

**Files touched**: All four files that call `Application.BuildCommand.parse` / `Application.ImagePull.parse` / `Application.NetworkCreate.parse` (ComposeUp, ComposeCreate, ComposeBuild, ComposePull, ComposeRun for ImagePull). Adds a build-aware test.

**Defer-criterion**: Only do PR-6 when a build-argv regression actually surfaces or when the Phase 4 backlog requires `compose build` parity testing. The shell-out family (PR-2 through PR-5) covers the active bug class.

---

## 10. Risks / open questions

### Q1: Does `Application.BuildCommand.parse(commands).run()` interact with the seam?

No, until PR-6. Until then, `compose build` and the build path inside `compose up` / `compose create` continue to call the upstream `container` package directly. This means the entrypoint bug class (which lives in `container run` argv) is fully covered by the seam, but build-argv bugs remain dynamic-test-only.

### Q2: Does `ContainerizationExtras` (or the in-process `ContainerClient`) hook into stdout streaming?

Audit: `ContainerClient` is used for `client.list()`, `client.get(id:)`, `client.stop(id:)`, `client.delete(id:)`, and `NetworkClient().get(id:)`. **None** of these stream output via `Process()`. They are pure Swift API calls that return values. They are out of scope for the seam — they are not user-facing argv. If a test wants to fake them, that's a different (smaller) concern: fake `ContainerClient` directly.

### Q3: Do dynamic tests still work after the seam is in?

Yes, with one twist. Dynamic tests don't bind a `RecordingRunner`, so the task-local default — `ProductionRunner()` — is used. `ProductionRunner` is a byte-for-byte wrapper of the existing helpers. So dynamic tests behave identically.

The twist: the unstructured `Task { }` at `ComposeUp.swift:578` inherits the task-local from its parent task. Inside the task body, `RunnerEnvironment.current` resolves to whatever was bound in the enclosing `withValue` (or to `ProductionRunner()` if nothing was bound). Confirmed by Swift Evolution proposal SE-0311: "Task local values are propagated to child tasks. Both structured (`async let`, `Task` group) and unstructured (`Task { }`) child tasks inherit." Only `Task.detached(operation:)` does **not** inherit, and we don't use that anywhere.

### Q4: How does the `await-only` exit-code-to-error translation differ across `shellCreate` / `shellKill` / `shellStart`?

Each currently throws an `NSError` with `domain` matching its filename ("ComposeCreate", "ComposeKill", "ComposeStart"), `code: Int(p.terminationStatus)`, and a localized description. After the seam, `RunResult.exitCode` is returned to the caller, who must translate. Two designs:

1. **Caller-side translation** (preferred). Each command site that previously threw inline now writes:
   ```swift
   guard result.exitCode == 0 else {
       throw NSError(domain: "ComposeKill", code: Int(result.exitCode), …)
   }
   ```
   Pros: domain-name fidelity preserved per call site. Cons: 3 extra lines per site.
2. **Runner-side translation**. `ProductionRunner` throws on non-zero in `.awaitOnly` mode. Pros: less per-site code. Cons: the recorder loses the ability to stub a non-zero exit and observe what the caller does about it.

**Decision**: Option 1. The recorder needs to be able to inject failures (test for "what does compose up do when network create exits 5?"), so the runner must always return — never throw — on non-zero exit. Caller-side translation it is.

### Q5: `ComposeRun.streamCommand` writes directly to `print` / `fputs(stderr)` instead of taking closures. Production parity?

`ComposeRun.swift:381–391` reads the stream and `print`s / `fputs(str, stderr)`s directly. This is different from `ComposeUp`, which forwards to caller closures. To preserve byte-for-byte behavior, `ProductionRunner` must, when both `onStdout` and `onStderr` are nil and `kind == .streaming`, route stdout to `print(_:terminator:)` and stderr to `fputs(_:stderr)`. The recorder ignores nil closures (no chunks pushed). Document this in the `ProductionRunner` doc comment.

### Q6: ComposeWatch's five shell-outs invoke `container-compose`, not `container`. Is that a recording problem?

No — argv[0] is part of the request. Tests asserting "watch triggered a rebuild" check `argv.starts(with: ["container-compose", "build"])`. The only nuance: a recorder-bound test cannot transitively assert what *that* `container-compose build` would have done (because it never runs). That's fine — those nested invocations have their own argv tests via PR-2/3/4.

### Q7: Does Swift Testing's `.serialized` trait on `ComposeUpTests` matter for the new `RuntimeArgvTests`?

No. `ComposeUpTests` is `.serialized` because it boots the actual container subsystem. The static `RuntimeArgvTests` has no shared resource — every test creates its own `RecordingRunner` inside its own task-local. They can run fully in parallel.

### Q8: Sample compose files location

Currently `Tests/TestHelpers/DockerComposeYamlFiles.swift` is the canonical fixture file. New tests should reuse / extend it rather than inline strings. (See `ComposeUpTests.swift` for usage pattern.)

---

## 11. Acceptance criteria

A future executing agent has finished this work when **all** of the following hold:

- [ ] `Sources/Container-Compose/Runtime/RunCommandRunner.swift` exists and exports `RunRequest`, `RunResult`, `RunCommandRunner`, `ProductionRunner`, `RunnerEnvironment`.
- [ ] `Tests/TestHelpers/RecordingRunner.swift` exists and conforms to `RunCommandRunner`. It is importable from both static and dynamic test targets.
- [ ] All `streamCommand` call sites in `Sources/Container-Compose/Commands/` have been replaced by `RunnerEnvironment.current.run(...)` calls. Specifically:
  - `ComposeUp.swift:587` — gone.
  - `ComposeRun.swift:308` — gone.
  - `ComposeUp.streamCommand` extension method (lines 854–906) — deleted.
  - `ComposeRun.streamCommand` private method (lines 359–406) — deleted.
- [ ] All `shell*` await-only helpers in `Sources/Container-Compose/Commands/` have been replaced:
  - `ComposeCreate.shellCreate` (438–475) — deleted.
  - `ComposeCreate.checkCreateSupported` (478–497) — deleted.
  - `ComposeKill.shellKill` (140–168) — deleted.
  - `ComposeStart.shellStart` (142–170) — deleted.
  - `ComposeExec.shellExec` (178–225) — deleted.
  - `ComposeWatch.WatchLoop.shell` (208–225) — deleted.
- [ ] The entrypoint placement bug (`PLAN.md §1`) is fixed at all three sites:
  - `ComposeUp.swift` — already fixed (PR-A).
  - `ComposeRun.swift:297–299` — fixed in PR-3.
  - `ComposeCreate.swift:420–422` — fixed in PR-4.
- [ ] `Tests/Container-Compose-StaticTests/RuntimeArgvTests.swift` exists with at least 6 active `@Test` functions covering: up entrypoint placement, run entrypoint placement, create entrypoint placement, entrypoint+command interaction, port mapping (`ports` parsing through `composePortToRunArg`), env merging (`env_file` + `environment`), and kill signal argv.
- [ ] `swift test` passes on a fresh checkout **without** Apple `container` installed. Specifically: `swift test --filter Container-Compose-StaticTests` is fully green, and `Container-Compose-DynamicTests` is skipped (not failed) because of `RuntimeAvailability.isAvailable() == false`.
- [ ] `swift test` still passes **with** Apple `container` installed — i.e., dynamic tests behave identically to before the seam was introduced.
- [ ] `make build` produces a binary whose `compose up` / `compose run` / `compose create` against `~/projects/cloudflare/compose.yml` (the user's reference fixture, per `PLAN.md §Suggested resumption path`) produces the same logs and same eventual container state as before.
- [ ] Every commit on the branch tree builds independently (no breakage between PR-1 and PR-2 etc.).
- [ ] No `nonisolated(unsafe)` introduced. No new `@unchecked Sendable` introduced (commands keep their existing `@unchecked Sendable` for unrelated reasons).

---

_End of plan._
