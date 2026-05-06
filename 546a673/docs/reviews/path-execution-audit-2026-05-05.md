# PATH-Based Execution Audit — `RunCommandRunner.swift`

- **Linear:** CHAOS-1421
- **Branch:** `enhacement/final-features`
- **Trigger:** Codex review (`docs/reviews/codex-20260505.md` Medium Priority #6) — *"Review runtime command lookup and other PATH-based execution points for whether they should be narrowed or made explicit."*
- **Scope:** Research-only. No source modifications.
- **Date:** 2026-05-05

---

## 1. Executive Summary

`ProductionRunner` shells out three different ways (`spawnStreaming`, `spawnAwait`, `spawnProbe`) and every one of them invokes `/usr/bin/env` with a hardcoded `PATH` of `/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`. Each spawner re-walks that PATH at every call to resolve the same two binaries — `container` and (in `ComposeWatch`) `container-compose`. The current behaviour is safe (no shell interpolation, no inherited-PATH ambiguity) but it is wasteful, repeats a magic string in three places, and offers no escape hatch for tests, alternate installs, or CI shims. Recommendation: **Option B with a small B+C blend** — resolve `container` (and `container-compose`) once at process startup, store the absolute path, and accept an env-var override for testability and unusual installs. This eliminates per-call PATH walks, removes the duplicated magic string, and gives tests a clean injection point that does not need to fight the production PATH constant.

---

## 2. Current State

### 2.1 `Process()` invocation sites

| File:Line | Spawner | Executable | argv[0] (typical) | Working dir | Environment |
|---|---|---|---|---|---|
| `Sources/Container-Compose/Runtime/RunCommandRunner.swift:315` | `spawnStreaming` | `/usr/bin/env` | `"container"` (or `"container-compose"` from `ComposeWatch`) | `cwd ?? FileManager.default.currentDirectoryPath` | `ProcessInfo.environment` merged with hardcoded `PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` |
| `Sources/Container-Compose/Runtime/RunCommandRunner.swift:402` | `spawnAwait` | `/usr/bin/env` | `"container"` (or `"container-compose"` from `ComposeWatch`) | same | same |
| `Sources/Container-Compose/Runtime/RunCommandRunner.swift:429` | `spawnProbe` | `/usr/bin/env` | `"container"` (today only `["container", "create", "--help"]`) | optional | same |

`Process()` is **not** instantiated anywhere else in `Sources/`. (Verified via `grep -rn 'Process()' Sources/` — only the three sites above.) All other historical Process call sites that lived in command files have been deleted as part of the runner-seam migration; the comments in `Sources/Container-Compose/Commands/Compose{Kill,Exec,Run,Up,Start,Create}.swift` explicitly say so (e.g. `ComposeKill.swift:151`, `ComposeUp.swift:1135`, `ComposeCreate.swift:560`).

### 2.2 What is being executed

`grep -n '"container"' Sources/Container-Compose/Commands/` shows the actual argv[0] payloads handed to the runner:

- `ComposeExec.swift:187` — `["container", "exec"] + execArgs`
- `ComposeKill.swift:157` — `["container", "kill", "--signal", signal, container.id]`
- `ComposePush.swift:162` — `["container", "image", "push", qualifiedImageName] + …`
- `ComposeTop.swift:202` — `["container", "exec", containerName, "ps", "-ef"]`
- `ComposeUp.swift:886` — `["container", "run"] + runCommandArgs`
- `ComposeStart.swift:160` — `["container", "start", "--detach", containerName]`
- `ComposeRun.swift:339` — `["container", "run"] + runArgs`
- `ComposeCreate.swift:400, 425` — `["container", "create", "--help"]` (probe) / `["container", "create", …]`
- `ComposeWatch.swift:186, 188, 212, 226, 235` — `["container-compose", …]` (self-invocation; see `RunCommandRunner.swift:70` and `:114`)

So in practice the runner resolves exactly two binaries via `env`: **`container`** (Apple's CLI) and **`container-compose`** (this binary, re-entered).

### 2.3 Other PATH-related strings in the tree

`grep -rn -E '/usr/bin/env|/usr/local/bin|/opt/homebrew/bin|/usr/bin|/bin/' Sources/` returns **only** the three runner spawners and their two doc-comment mirrors at lines 154 and 156. No other code in `Sources/` hardcodes paths into `/usr/bin`, `/usr/local/bin`, `/opt/homebrew/bin`, `/usr/sbin`, or `/sbin`. There are no `launchPath` users (deprecated API) and no other `executableURL` writes.

---

## 3. Risk Analysis

The current approach is *defensively safe* but has the following soft failure modes:

1. **Three-way duplication of the PATH literal.** Any drift (e.g. forgetting `/opt/homebrew/bin` on an Apple-Silicon-only build) would silently change resolution for one spawner but not the others. The doc comment on `ProductionRunner` (line 156) makes this an explicit invariant, which is itself a smell — invariants enforced by code comments tend to rot.
2. **Per-call PATH walk overhead.** `env` re-stats each PATH directory on every spawn. For high-fan-out commands like `ComposeUp` (which spawns one `container run` per service) and `ComposeWatch` (which re-execs `container-compose` per file event), this is wasted syscalls.
3. **No diagnostic if `container` is missing.** Today, the failure surface is whatever exit code `env` returns when it cannot find the binary (typically 127), wrapped in a `RunResult.exitCode`. The user sees a non-zero exit with no specific "the `container` CLI is not installed" message. A startup-time resolution would let us emit a clear, actionable diagnostic once.
4. **No test override.** `RunCommandRunner` is already injectable via `RunnerEnvironment.$current` (and tests use `RecordingRunner`), so this is *less* acute than in projects without a seam — but tests that exercise `ProductionRunner` itself (rare but present) cannot point it at a stub binary without environment-wide PATH manipulation. CI shims (`container` in a repo-local `bin/`) currently require the operator to know they must alter the system PATH to be picked up by the merged hardcoded PATH, which they will not be — because the merge order (`{ _, new in new }`) **prefers the hardcoded value over the inherited one**.
5. **Env-merge hides operator intent.** The `merging(... { _, new in new })` policy means a user who exports a custom `PATH` upstream of `container-compose` is silently overridden. That is intentional (per the docstring "doesn't depend on the user's `$PATH`") but it is also a foot-gun if anyone tries to use a sandbox-PATH or Nix-style installation pattern.
6. **`/usr/bin/env` itself is a small TOCTOU surface.** Apple-blessed and effectively immutable on macOS, so the practical risk is low — but if we're auditing for "explicit", it is worth naming.

None of these are urgent. The current code does not have a security bug; it has an *expressiveness* and *operability* gap.

---

## 4. Options Evaluated

### Option A — Status quo

**Keep `/usr/bin/env` + hardcoded `PATH` in all three spawners.**

- **Pros**
  - Zero churn; behaviour is already proven and matches the byte-for-byte port invariant called out in `PLAN.md §5`.
  - `/usr/bin/env` is a stable, signed system binary on macOS; using it sidesteps SIP edge cases.
  - PATH is consistent across user shells (zsh/bash/fish) — operator's login shell PATH cannot accidentally shadow `container`.
- **Cons**
  - Magic string lives in three places.
  - Repeated PATH walks on every spawn.
  - No clean injection seam for tests of `ProductionRunner`.
  - Failure mode if `container` is missing is silent (exit 127 with no diagnostic).
  - Operator override (custom PATH, repo-local shim) is silently ignored.

### Option B — Resolve once at startup, exec the resolved absolute path

**Walk the same PATH once during `ProductionRunner` initialization (or lazily on first use), cache the absolute URL of `container` and `container-compose`, and set `executableURL` to the cached URL directly. Drop the `env` indirection. Drop the per-call `PATH` env-var injection.**

- **Pros**
  - Single source of truth for the resolution PATH (one constant, one walker).
  - One PATH walk per process lifetime instead of per spawn.
  - Clear startup-time diagnostic: "`container` CLI not found in `<PATH>` — install it from <https://...>".
  - `ps`/audit logs show the absolute path of the binary actually executed (better forensics, easier to spot "wrong `container` was on PATH" bugs).
  - Removes the env-merge dance entirely.
- **Cons**
  - More code (a small resolver helper plus a struct field).
  - Loses the (probably unused) ability for an operator to install a different `container` mid-session and have it picked up on the next spawn.
  - If we keep the resolution lazy, the diagnostic moves from startup to first-use (still better than today, but less proactive).
  - Slight behavioural drift from the byte-for-byte plan invariant — needs a doc-comment update on `ProductionRunner` and a follow-up test.

### Option C — Explicit env-var override

**Honor `CONTAINER_COMPOSE_CONTAINER_BIN` (and `CONTAINER_COMPOSE_SELF_BIN` for the watch case) when set; otherwise fall back to either Option A or Option B.**

- **Pros**
  - Trivial test injection: a test sets the env var to a stub path and `ProductionRunner` is now hermetic.
  - CI reproducibility: jobs can pin to a specific `container` binary version without mutating system state.
  - Supports unusual installs (Nix, Homebrew tap with non-standard prefix, dev-built `container` from source).
- **Cons**
  - One more knob in the user-facing surface area; needs to be documented.
  - Without Option B underneath, you still have the per-call PATH walk and the duplication problem.

These options compose: **C is additive on top of A or B**.

---

## 5. Recommendation

**Pick Option B, with Option C bolted on (B + C).**

Justification: The duplication of the PATH literal across three spawners is exactly the kind of invariant-by-comment that decays in a year-old codebase, and resolving once gives us a real diagnostic when `container` is not installed — which today is the silent-exit-127 footgun that bites first-run users. Layering C (the env-var override) on top costs maybe ten lines and gives `ProductionRunner` the same testability that `RecordingRunner` already gives the rest of the runtime, plus a documented escape hatch for CI and atypical installs. Option A is fine if we want to defer; the current code is not broken, just under-expressed. We should not pick C alone — without the startup resolution from B, the override only patches one symptom.

A pragmatic implementation order: do B first (one PR, contained behaviour change, plus an updated doc comment on `ProductionRunner` to retire the "`/usr/bin/env`, argv passed verbatim" invariant), then add C in a follow-up that is mostly docs + a four-line resolver tweak.

---

## 6. Suggested Diff (sketch only)

A single small helper, called once during `ProductionRunner` init (or memoized via a `static let`), would replace the three `executableURL` / `environment` blocks. Sketch:

```swift
// Sources/Container-Compose/Runtime/RunCommandRunner.swift

private enum BinaryResolver {
    static let resolutionPath =
        "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Resolve `name` against `resolutionPath`, optionally honouring an env override.
    /// Returns nil if not found in any directory.
    static func resolve(_ name: String, override envVar: String? = nil) -> URL? {
        if let envVar, let p = ProcessInfo.processInfo.environment[envVar],
           !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        for dir in resolutionPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

// In ProductionRunner: cache once, e.g.
//   private static let containerBin = BinaryResolver.resolve(
//       "container", override: "CONTAINER_COMPOSE_CONTAINER_BIN")
//   private static let selfBin = BinaryResolver.resolve(
//       "container-compose", override: "CONTAINER_COMPOSE_SELF_BIN")
//
// Each spawn{Streaming,Await,Probe} then does:
//   let exe = (argv.first == "container-compose") ? Self.selfBin : Self.containerBin
//   guard let exe else { throw RuntimeError.containerCLINotFound(...) }
//   process.executableURL = exe
//   process.arguments = Array(argv.dropFirst())   // argv[0] is now the resolved binary
//   // No more PATH-merge dance.
```

Notes for the implementer:

- Dropping `argv.first` is a real behaviour change — `env` would have placed `argv[0]` literally as `container`, but a direct `executableURL` set means we want `arguments` to be the *parameters*, not the program name. Worth a focused test.
- The `RunRequest.argv` doc-comment (line 68-75) currently says "the first element is the executable" — that contract stays correct from the **caller's** perspective; `ProductionRunner` is the only thing that needs to know the difference between argv[0]-as-name and `executableURL`-as-resolved.
- `PLAN.md §5` byte-for-byte invariant needs an explicit follow-up note: "PR-N narrows resolution per CHAOS-1421 audit".

---

## 7. Out of scope

- The choice of which directories belong in `resolutionPath` (the current `/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` set is fine; a future PR could add `~/.local/bin` or shave `/usr/sbin` if we audit which subcommands actually live there).
- The `RecordingRunner` lane — already injected via `RunnerEnvironment.$current` and unaffected by this audit.
- `Process.environment` policy beyond `PATH`. The merge-with-overwrite-on-conflict pattern is independently fine; this audit only addresses the PATH key.
