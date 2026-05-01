# Plan — No-Upstream Action Plan v2

**Author:** Sisyphus
**Date:** 2026-05-01
**Repo:** `/Users/chris/projects/full-chaos/container/container-compose`
**Trigger:** Post-audit follow-up. The 2026-05-01 feature-parity audit (`docs/feature-parity.md`) revealed Container-Compose drops to ~58% honest coverage (was inflated to ~74% by silent-failure flags). User asked: "create a plan to tackle what we can currently, without upstream apple/container changes." User also flagged: "`--shm-size` was recently added yesterday."
**Review:** Initial draft rejected by Momus (3 blockers). This v2 reflects fixes: drop R1/R2 (already shipped), drop CHAOS-1367 from active phases (already in main as CHAOS-1344), fix file paths, add executable QA per task.

---

## 1. Goal

Drain the no-upstream backlog now that we have:
1. A precise feature-parity inventory (`docs/feature-parity.md`)
2. Honest public coverage matrix (PR #72 — `coverage.html` reflecting Tier 0 silent failures)
3. Verified apple/container HEAD state (multiple flags landed in last 30 days)
4. A 16-ticket Linear backlog (CHAOS-1370 + CHAOS-1378 families) ready for execution

After this plan ships:
- Container-Compose builds against a fork that's caught up with upstream apple/container HEAD
- ~22 Tier 0 silent-failure sites are remediated (warn-skip pattern, no more `unknown option`)
- 4+ open backlog items closed (CHAOS-1366, CHAOS-1369, CHAOS-1363, CHAOS-1370 family)
- Coverage matrix reconciled to reflect post-remediation state
- All Tier 1 wireable items (CHAOS-1336, CHAOS-1368) have either landed or have updated effort estimates pending Tier 0 cleanup

---

## 2. Scope decisions (with evidence)

### Already shipped (verified during planning) — Linear hygiene only

| Prior work | Status | Verification |
|---|---|---|
| **R1** (drop ComposeRun's private `pullImage`) | SHIPPED | `grep -c "private func pullImage" Sources/Container-Compose/Commands/ComposeRun.swift` returns 0; line 164 calls shared helper |
| **R2** (consolidate env merging) | SHIPPED | `mergeServiceEnvironment` exists at `Sources/Container-Compose/Helper Functions.swift:73-99`; all 3 callsites (ComposeUp:584, ComposeCreate:359, ComposeRun:271) use it; tests at `Tests/Container-Compose-StaticTests/EnvironmentMergeTests.swift` exist |
| **CHAOS-1367** (pull host-platform default) | SHIPPED in code | `Compose+Pull.swift:56-61` already implements `defaultRuntimePlatform()` fallback (CHAOS-1344 fix). Phase 5 only needs Linear closure with PR link |

### IN scope (will implement)

| ID | Title | Tier | Evidence |
|---|---|---|---|
| **F0** | Bump `full-chaos/container@tier2-fork-patches` to pull upstream main (gain `--shm-size` and any other recent landings) | sync | Upstream PR #1488 (`--shm-size`) merged 2026-04-30; fork last commit `c910d3d` is Apr 22. Fork is 8 days behind. Verified via `gh api repos/full-chaos/container/compare/apple:main...full-chaos:tier2-fork-patches`. |
| **CHAOS-1370** | Tier 0 sweep umbrella + 7 sub-issues | Tier 0 | Filed 2026-05-01. All 7 sub-issues independently verified against fork's `Flags.swift` — flags genuinely missing. |
| **CHAOS-1366** | Add `RuntimeError.imageNotFound(reference:)` mapping case | infra | Verified: `enum RuntimeError` at `Sources/Container-Compose/Runtime/Runtime.swift:169` has cases `.notFound(id:) / .alreadyExists / .invalidState / .timeout / .notSupported / .backendFailure / .persistenceFailure` — no `.imageNotFound`. |
| **CHAOS-1369** | Deprecation warning cleanup for `EventRoutes` | tech-debt | Verified: `EventsRoutes.swift:85` extends deprecated `APIStatsErrorResponse`; `ProjectRoutes.swift:122` extends deprecated `APIErrorResponse`. Both visible at `make build` tail. |
| **CHAOS-1363** | LaunchAgent `ThrottleInterval` for fast-crash protection | infra | Verified: `Resources/com.full-chaos.container-compose.plist` has Label/ProgramArguments/RunAtLoad/KeepAlive/StandardOutPath/StandardErrorPath but NO `<key>ThrottleInterval</key>`. |
| **CHAOS-1336** (partial) | Wire `service.deploy.resources.reservations.cpus/memory` | Tier 1, blocked | Reservations emit `--memory-reservation` which is currently a silent failure (CHAOS-1375 territory). After Tier 0 sweep, the wireup either drops these mappings or files an upstream FR. |
| **CHAOS-1368** | Replace volume hardlink-dir with `container volume create` | Tier 1 | apple/container's `container volume create --label/--opt/--size` exists upstream. Open question: does `container run -v <name>:<path>` resolve names? Plan includes a 30-min smoke test as Phase 4 gate. |
| **Coverage reconciliation** | Update `coverage.html` post-Tier-0-sweep: notes flip from "silent failure" to "decoded; warn-skipped" | docs | Mechanical follow-on; pattern matches CHAOS-1338. |

### OUT of scope (upstream-blocked or fork-engineering — documented for next planning cycle)

| ID | Why | Evidence |
|---|---|---|
| CHAOS-1334 (network IPAM extensions) | Needs fork patch to add `--driver-opts`/`--attachable`/`--ipv6`/`--ip-range`/`--gateway`/`--aux-address`/`--ipam-driver`/`--ipam-opt` to `container network create` | apple/container `NetworkCreate.swift` only has `--label`/`--internal`/`--subnet`/`--subnet-v6`/`--plugin`/`--plugin-variant` |
| CHAOS-1335 (volume `driver_opts`) | Could be Tier 1 if we move to native CRUD (CHAOS-1368), but propagation requires the fork to expose `--opt KEY=VALUE` in `volume create` flags. Currently `container volume create --opt` exists upstream — re-verify scope after CHAOS-1368 lands. | bg_865daeda showed VolumeCreate has `--opt` |
| CHAOS-1378 family (Tier 3 FRs) | All 7 require apple/container engineering; this plan filters them OUT | docs/feature-parity.md §6 |
| CHAOS-1332 (AI models / provider) | Frontier Tier 5 — spec evolving, not investing yet | docs/feature-parity.md §8 |
| CHAOS-1345 (Architecture PRD) | Umbrella backlog; no concrete deliverable | — |

---

## 3. Pre-flight verification (before kicking off Phase 0)

### 3.1 — QA execution conventions (READ THIS FIRST)

All shell QA snippets in this plan assume the following conventions. Per Momus v4 review, default `bash`/`zsh` interpretation of the snippets has two pitfalls that invalidate pass/fail gates:

1. **Pipelines mask exit codes.** `make build 2>&1 | tail -5` returns `tail`'s exit code, NOT the build's. Run every QA block under `set -o pipefail`:
   ```sh
   set -o pipefail
   make build 2>&1 | tail -5    # now actually fails if build fails
   ```
   Either prefix each block with `set -o pipefail`, run individual commands without piping, or invoke a wrapper:
   ```sh
   bash -o pipefail -c '<command>'
   ```

2. **`grep -c ... # expect 0` is misleading.** On both BSD and GNU `grep`, zero matches exits with status 1, so a naive `grep -c X file` assertion FAILS exactly when the expected result is "0 matches." Wherever you see `# expect 0` in the QA blocks below, interpret it as one of these idiomatic forms:
   ```sh
   # Negation form (preferred):
   ! grep -qE 'pattern' file && echo "PASS: no matches"

   # Explicit count form:
   [ "$(grep -cE 'pattern' file 2>/dev/null || true)" -eq 0 ] && echo "PASS: 0 matches"
   ```
   The `2>/dev/null || true` belt-and-suspenders prevents the `grep -c` exit-1 from killing a piped script.

3. **Directory greps need `-r` or specific files.** Plain `grep -E 'pat' Some/Dir/` errors with `Is a directory`. Either use `grep -rE 'pat' Some/Dir/` or list files explicitly: `grep -E 'pat' Some/Dir/{File1,File2}.swift`.

4. **`swift test --filter` accepts a literal substring**, not regex. Where the plan writes `--filter "GpusBlkio|ResourceArgs"`, run two separate test invocations: `swift test --filter GpusBlkio && swift test --filter ResourceArgs`.

The QA snippets in §4 are written in their compact form for readability; apply the conventions above when executing.

### 3.2 — Baseline establishment

```sh
cd /Users/chris/projects/full-chaos/container/container-compose
git checkout main && git pull origin main
set -o pipefail
make build                                          # exit 0 expected
swift test --filter Container-Compose-StaticTests   # exit 0 expected
linear issues get CHAOS-1370 | grep '"state"'       # confirm Backlog
linear issues get CHAOS-1378 | grep '"state"'       # confirm Backlog
```

Expected: all green, both umbrellas open, baseline clean.

---

## 4. Phases

Each phase is a separate PR with its own CHAOS-style commit subject. Each ends with passing build + tests + clean diagnostics. **Every sub-task includes an executable QA scenario with concrete tool, command, and pass criteria.**

### Phase 0 — Branch + fork bump (1-2 hr)

**Goal:** Catch fork up to upstream so `--shm-size` and any other recent landings are picked up.

#### 0.1 — Branch
- [ ] Create branch `feat/no-upstream-action-plan-v2` off `main`.

**QA:** `git branch --show-current` outputs `feat/no-upstream-action-plan-v2`.

#### 0.2 — Fork merge upstream

This is in a SEPARATE repo (`full-chaos/container`), but Container-Compose drives the cadence.

- [ ] In `/Users/chris/projects/full-chaos/container/container/`:
  ```sh
  git fetch upstream main && git fetch origin
  git checkout tier2-fork-patches
  git merge --no-ff upstream/main -m "merge: pull apple/container@main into tier2-fork-patches (gain --shm-size, etc.)"
  ```
- [ ] Resolve any conflicts. Most likely conflict-free since fork's 4 commits don't touch `Flags.swift` body, only add fields.
- [ ] In the fork: `swift build` and `swift test` to confirm clean post-merge.
- [ ] Push: `git push origin tier2-fork-patches`.

**QA per the merge** (grep patterns updated per Momus v3 review — Swift ArgumentParser uses `customLong("name")` / `.long` / `.shortAndLong` modifiers, NOT literal `"--name"` strings):

```sh
cd /Users/chris/projects/full-chaos/container/container/
swift build 2>&1 | tail -5      # exit 0; no errors
swift test 2>&1 | tail -5       # exit 0

# Verify --shm-size landed (it appears as customLong("shm-size") OR a property named shmSize with .long)
grep -nE 'customLong\("shm-size"\)|var shmSize:' Sources/Services/ContainerAPIService/Client/Flags.swift   # expect >= 1 match

# Verify --restart still present (fork patch)
grep -nE 'customLong\("restart"\)|var restart:' Sources/Services/ContainerAPIService/Client/Flags.swift    # expect >= 1 match
```

Pass criteria: build + test exit 0; both greps return >= 1 match (proves merge brought `--shm-size` AND fork's `--restart` survived).

#### 0.3 — Bump Container-Compose's `Package.resolved`

- [ ] In container-compose repo: `swift package update container` to pick up the new fork SHA.
- [ ] Commit `Package.resolved` with subject: `chore(deps): bump full-chaos/container to gain upstream --shm-size (PR #1488 + others)`.

**QA:**

```sh
cd /Users/chris/projects/full-chaos/container/container-compose
swift package update container 2>&1 | tail -3
make build 2>&1 | tail -5                                   # exit 0
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3   # exit 0

# Verify --shm-size in the checked-out fork source (declaration form, not literal)
grep -nE 'customLong\("shm-size"\)|var shmSize:' .build/checkouts/container/Sources/Services/ContainerAPIService/Client/Flags.swift   # expect >= 1 match
```

Pass criteria: All commands exit 0; new fork SHA in `Package.resolved`; grep finds `--shm-size` declaration.

#### 0.4 — Identify newly-landed flag surface

After fork bump, re-grep `.build/checkouts/container/Sources/Services/ContainerAPIService/Client/Flags.swift` for the flags previously listed as silent failures. **Use ArgumentParser declaration patterns**, not literal `"--flag"` strings — the latter only appears in some files (e.g., help text) but is unreliable as a presence indicator.

- [ ] Run the audit grep. Each line below probes one flag using all three common ArgumentParser shapes (`customLong("name")`, `name: .long`/`shortAndLong` paired with a `var <camelCase>:` declaration):
  ```sh
  FLAGS_FILE=.build/checkouts/container/Sources/Services/ContainerAPIService/Client/Flags.swift
  for flag_decl in \
    'shm-size|var shmSize:' \
    'stop-signal|var stopSignal:' \
    'add-host|var addHost:' \
    'cap-add|var capAdd:' \
    'cap-drop|var capDrop:' \
    'ulimit|var ulimits:' \
    'memory-reservation|var memoryReservation:' \
    'pids-limit|var pidsLimit:' \
    'security-opt|var securityOpt:' \
    'gpus|var gpus:'; do
    cli_part="${flag_decl%%|*}"
    var_part="${flag_decl##*|}"
    matches=$(grep -cE "customLong\\(\"$cli_part\"\\)|$var_part" "$FLAGS_FILE")
    echo "$cli_part: $matches"
  done
  ```
- [ ] Capture which flags returned >= 1. Each such flag is now upstream-supported and must be EXCLUDED from the Tier 0 sweep (Phase 2 sub-issues).
- [ ] Comment the list on CHAOS-1370 (markdown bullet list).

**QA:** The script above runs to completion; each flag prints `<name>: <count>`; document the resulting list. Pass criteria: at minimum `shm-size: 1` and `cap-add: 1` and `ulimit: 1` after fork bump (per the librarian audit findings).

**Exit gate Phase 0:**

1. `make build` exits 0 with the new fork.
2. `swift test --filter Container-Compose-StaticTests` exits 0.
3. Fork's `Flags.swift` contains `--shm-size` (line known after grep).
4. `Package.resolved` committed; PR opened with title `chore(deps): bump fork`.
5. CHAOS-1370 commented with the "newly-landed flags" list from 0.4.

---

### Phase 1 — Quick wins (CHAOS-1366 + CHAOS-1369 + CHAOS-1363) (~2-3 hr)

**Goal:** Drain the small-effort backlog to clear the deck for the Tier 0 sweep.

Each is a separate commit / PR.

#### 1.1 — CHAOS-1366: `RuntimeError.imageNotFound`

**File path corrections (per Momus v2 review):**
- `enum RuntimeError` lives at `Sources/Container-Compose/Runtime/Runtime.swift:169` (NOT `Runtime/RuntimeError.swift`).
- The active image-pull dispatch path is at `Sources/Container-Compose/Runtime/RunCommandRunner.swift:209-220` (handles `case "ImagePull"`). `AppleContainerizationRuntime.swift` does NOT contain the pull path. The compose-side caller is `Sources/Container-Compose/Commands/Compose+Pull.swift:52-65`.

This task ships in two parts. Part A is enum-only; Part B is the actual error-mapping at the dispatch boundary.

##### Part A — Enum + `errorDescription` (mandatory)

- [ ] Read `Sources/Container-Compose/Runtime/Runtime.swift:169-198` to see the existing enum + `LocalizedError` extension.
- [ ] Add new case to `enum RuntimeError`:
  ```swift
  case imageNotFound(reference: String)
  ```
- [ ] Add corresponding switch arm in `LocalizedError.errorDescription`:
  ```swift
  case .imageNotFound(let reference):
      return "Runtime: image '\(reference)' not found"
  ```
- [ ] Add `Equatable` if not auto-derived (the existing enum has associated values; verify the synthesized `Equatable` covers the new case).

##### Part B — Map dispatch errors at `RunCommandRunner.swift` (mandatory)

- [ ] Read `Sources/Container-Compose/Runtime/RunCommandRunner.swift:200-230` to see the `ImagePull` dispatch case (line 211-212: `let cmd = try Application.ImagePull.parse(argv)`).
- [ ] Wrap the `try await cmd.run()` (or equivalent) in a `do/catch` that detects the upstream "image not found" error condition. Concrete options to inspect upstream's error type:
  - `Application.ImagePull` may throw a typed `ContainerizationError` with a `.notFound` case; if so, map it.
  - It may throw a generic `Error` whose description contains `not found` / `404`; if so, string-match (least preferred — only fall back to this if no typed surface exists).
- [ ] On detection: re-throw `RuntimeError.imageNotFound(reference: <imageRef>)`. Source the `<imageRef>` from the dispatched argv (the first positional arg per `Compose+Pull.swift:54`).
- [ ] Verify the caller path (`Compose+Pull.swift:64`) propagates the new error type cleanly (no need to handle differently in the caller — error bubbles up to `compose up` exit handler).

##### Tests

- [ ] Add `Tests/Container-Compose-StaticTests/RuntimeErrorTests.swift` if it doesn't exist. Test cases:
  1. **Description:** Construct `.imageNotFound(reference: "alpine:3")`; assert `.errorDescription` returns `"Runtime: image 'alpine:3' not found"`.
  2. **Equality:** Two `.imageNotFound(reference: "alpine:3")` are equal; one with reference "alpine:3" is NOT equal to one with "redis:7".
- [ ] Add to `Tests/Container-Compose-StaticTests/ComposePullTests.swift` (or create `RunCommandRunnerImagePullTests.swift`):
  3. **Mapping (using `RecordingRunner` or a synthetic dispatch):** Inject a runner that throws an upstream "not found" error for a given image reference; verify `Compose+Pull.pullImage(...)` propagates `RuntimeError.imageNotFound(reference: <expected>)`.

**QA per CHAOS-1366:**

```sh
# Static tests
swift test --filter RuntimeErrorTests 2>&1 | tail -5      # exit 0; cases 1 + 2 pass
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3   # exit 0; no regressions

# Code-state assertions
grep -c "case imageNotFound" Sources/Container-Compose/Runtime/Runtime.swift                  # expect 1
grep -c 'Runtime: image' Sources/Container-Compose/Runtime/Runtime.swift                      # expect 1 (the errorDescription string)
grep -c "RuntimeError.imageNotFound" Sources/Container-Compose/Runtime/RunCommandRunner.swift # expect 1 (Part B mapping)

# Optional smoke (runtime-equipped only)
.build/release/container-compose up -f /tmp/missing-image.yaml   # should exit non-zero with "Runtime: image 'foo:bar' not found", NOT a generic stack trace
```

Pass criteria: 5 commands succeed; smoke (if runtime available) shows the new error type in stderr.

**Commit:** `feat(runtime): map image-not-found errors to RuntimeError.imageNotFound (CHAOS-1366)`

#### 1.2 — CHAOS-1369: EventRoutes deprecation cleanup

**Critical correction (per Momus v2 review):** `APIErrorEnvelope` already conforms to `ResponseEncodable` in `Sources/Container-Compose/Server/APISchemas.swift:550` (`public struct APIErrorEnvelope: Codable, Sendable, Hashable, ResponseEncodable {`). The deprecation warnings come from the route-level extensions `APIStatsErrorResponse` (deprecated type) and `APIErrorResponse` (deprecated type) — NOT from a missing `APIErrorEnvelope` conformance. Adding `extension APIErrorEnvelope: ResponseEncodable {}` would create a duplicate conformance and fail to compile.

**Correct fix:** simply DELETE the two deprecated route-level extensions. The deprecated types remain DEFINED in `APISchemas.swift` (intentional, for backward compat at the type level), but Hummingbird response encoding only needs `APIErrorEnvelope` which is already wired.

##### Steps

- [ ] Verify pre-conditions:
  ```sh
  grep -n "APIErrorEnvelope.*ResponseEncodable\|APIErrorEnvelope: ResponseEncodable" Sources/Container-Compose/Server/APISchemas.swift
  ```
  Expected: line 550 shows `APIErrorEnvelope` conforms.
- [ ] Confirm no real callers still need the deprecated route-level conformances:
  ```sh
  grep -rn "as APIStatsErrorResponse\|: APIStatsErrorResponse\|APIStatsErrorResponse(" Sources/Container-Compose/Server/Routes/
  grep -rn "as APIErrorResponse\|: APIErrorResponse\|APIErrorResponse(" Sources/Container-Compose/Server/Routes/
  ```
  If any active uses (i.e., not just the deprecated extension itself or backward-compat comments), STOP and re-scope; the deletion is unsafe. If only matches are the extension + comments, proceed.
- [ ] In `Sources/Container-Compose/Server/Routes/EventsRoutes.swift:85`: DELETE the line `extension APIStatsErrorResponse: ResponseEncodable {}`. Leave any comments at lines 84/86 if they still apply (likely the comment can also be removed).
- [ ] In `Sources/Container-Compose/Server/Routes/ProjectRoutes.swift:122`: DELETE the line `extension APIErrorResponse: ResponseEncodable {}`. The comment at line 121 (`// APIErrorResponse: ResponseEncodable retained for backward compat (deprecated).`) becomes obsolete — delete it too.
- [ ] No changes to `APISchemas.swift` (the deprecated type definitions stay; they're intentionally kept).

##### QA per CHAOS-1369

Run with `set -o pipefail` per §3.1.

```sh
set -o pipefail

# Build must show ZERO deprecation warnings for these specific symbols
WARN_COUNT="$(make build 2>&1 | grep -cE "APIStatsErrorResponse.*deprecated|'APIErrorResponse'.*deprecated" || true)"
[ "$WARN_COUNT" -eq 0 ] && echo "PASS: no deprecation warnings" || { echo "FAIL: $WARN_COUNT warnings"; exit 1; }

# General test pass
swift test --filter Container-Compose-StaticTests   # exit 0

# Confirm extensions deleted from each Routes/ file (recursive grep, then assert 0)
EXT_COUNT="$(grep -rE "^extension APIStatsErrorResponse|^extension APIErrorResponse" Sources/Container-Compose/Server/Routes/ 2>/dev/null | wc -l | tr -d ' ')"
[ "$EXT_COUNT" -eq 0 ] && echo "PASS: extensions deleted" || { echo "FAIL: $EXT_COUNT remaining"; exit 1; }

# Type definitions ARE retained in APISchemas.swift (backward compat)
grep -cE "struct APIStatsErrorResponse|struct APIErrorResponse" Sources/Container-Compose/Server/APISchemas.swift  # expect >= 1 (still defined)
```

Pass criteria: build emits zero deprecation warnings for these specific symbols; tests pass; route-level extensions gone; type definitions retained.

**Commit:** `chore: remove deprecated APIStatsErrorResponse/APIErrorResponse route-level extensions (CHAOS-1369)`

#### 1.3 — CHAOS-1363: LaunchAgent ThrottleInterval

**File path:** `Resources/com.full-chaos.container-compose.plist`.

- [ ] Read the plist to confirm current state (53 lines; no `ThrottleInterval`).
- [ ] Insert the following after `</array>` (line 37 — the close of `ProgramArguments`):
  ```xml
      <!-- Throttle restarts: launchd will not relaunch within this window -->
      <key>ThrottleInterval</key>
      <integer>10</integer>
  ```
  10 seconds is the standard launchd recommendation for daemon plists; matches `brew services` defaults.
- [ ] Update Homebrew formula tests if any reference the plist content.

**QA per CHAOS-1363:**

```sh
plutil -lint Resources/com.full-chaos.container-compose.plist                    # "OK" output expected
grep -c "ThrottleInterval" Resources/com.full-chaos.container-compose.plist      # exactly 1
grep -c "<integer>10</integer>" Resources/com.full-chaos.container-compose.plist # exactly 1
plutil -extract ThrottleInterval raw Resources/com.full-chaos.container-compose.plist   # outputs "10"
```

Pass criteria: plist validates; key + value present; `plutil -extract` returns 10.

**Commit:** `chore(serve): add ThrottleInterval to LaunchAgent plist for fast-crash protection (CHAOS-1363)`

**Exit gate Phase 1:**

1. All 3 sub-tasks have their commits + green CI.
2. `make build` exits 0 with **fewer warnings** than baseline (CHAOS-1369 should have removed the deprecation warnings — count via `make build 2>&1 | grep -c "warning:"`).
3. `lsp_diagnostics` clean on every touched file (no error-severity entries).
4. Linear: comment + transition each ticket (CHAOS-1366, CHAOS-1369, CHAOS-1363) to In Review or Done.

---

### Phase 2 — Tier 0 sweep (CHAOS-1370 family) (~6-10 hr)

**Goal:** Execute the 7 sub-issues filed under CHAOS-1370 to stop emitting flags upstream rejects.

**Recipe to follow** (from `bg_27b0d5bf`): Recipe A — Tier 0 Cleanup (canonical reference: CHAOS-1329/1330/1331).

The recipe in one paragraph: replace `args.append("--<flag>", value)` with `warnUnsupportedRuntimeFieldOnce("service.<field>", "Note: '<field>' is parsed but not supported by Apple container; ignored.")`. Update the corresponding test in `Tests/Container-Compose-StaticTests/<Topic>ArgsTests.swift` to assert the warn-skip path. After the source change lands, update the `coverage.html` row note from "silent failure" to "decoded; warn-skipped" (status stays `partial`).

**IMPORTANT scope adjustment from Phase 0.4:** Any flag that is NOW upstream-supported (e.g., `--shm-size` per PR #1488) should be EXCLUDED from the warn-skip pattern — it's no longer a silent failure. Adjust CHAOS-1375 scope accordingly.

#### 2.1 — CHAOS-1371: `--security-opt` / `--userns`

- [ ] In `Sources/Container-Compose/Commands/Compose+ArgsSecurity.swift:40-45`:
  - Wrap `args.append(contentsOf: ["--security-opt", opt])` block in a `warnUnsupportedRuntimeFieldOnce("service.security_opt", "Note: 'security_opt' is parsed but not supported by Apple container; ignored.")` call.
  - Same for `--userns` block.
- [ ] Update `Tests/Container-Compose-StaticTests/SecurityArgsTests.swift`:
  - Find tests that assert `--security-opt` is in argv → flip to assert it is NOT in argv.
  - Add new test asserting the warning print path (use `RecordingRunner` or capture stdout).
- [ ] Coverage flip in `coverage.html`: `service.security_opt` and `service.userns_mode` row notes change from "silent failure" to "decoded; warn-skipped via warnUnsupportedRuntimeFieldOnce".

**QA per CHAOS-1371:**

```sh
swift test --filter SecurityArgsTests 2>&1 | tail -5      # exit 0
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3   # exit 0
grep -c "args.append.*security-opt" Sources/Container-Compose/Commands/Compose+ArgsSecurity.swift   # expect 0
grep -c "args.append.*userns" Sources/Container-Compose/Commands/Compose+ArgsSecurity.swift        # expect 0
grep -c "warnUnsupportedRuntimeFieldOnce.*security_opt" Sources/Container-Compose/Commands/Compose+ArgsSecurity.swift   # expect 1
```

Pass criteria: tests pass; emissions removed; warnings added.

**Commit:** `feat(args): warn-and-skip --security-opt / --userns (CHAOS-1371)`

#### 2.2 — CHAOS-1372: `--ipc` / `--pid` / `--uts`

**Files to modify:** `Sources/Container-Compose/Commands/Compose+ArgsNetworking.swift:134-149`, `Tests/Container-Compose-StaticTests/NetworkArgsTests.swift`.

- [ ] Replace each `args.append(contentsOf: ["--ipc"|"--pid"|"--uts", value])` block with `warnUnsupportedRuntimeFieldOnce("service.<field>", "Note: '<field>' is parsed but not supported by Apple container; ignored.")`.
- [ ] Update tests asserting these flags appear → flip to assert absence + warning.
- [ ] Coverage flip in `coverage.html`: 3 row notes flipped.

**QA per CHAOS-1372:**

```sh
swift test --filter NetworkArgsTests 2>&1 | tail -5                                                # exit 0
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3                                   # exit 0
grep -cE 'args.append.*"--(ipc|pid|uts)"' Sources/Container-Compose/Commands/Compose+ArgsNetworking.swift   # expect 0
grep -cE 'warnUnsupportedRuntimeFieldOnce.*"service\.(ipc|pid|uts)"' Sources/Container-Compose/Commands/Compose+ArgsNetworking.swift  # expect 3
```

**Commit:** `feat(args): warn-and-skip --ipc / --pid / --uts (CHAOS-1372)`

#### 2.3 — CHAOS-1373: `--device` / `--sysctl`

**Files to modify:** `Sources/Container-Compose/Commands/Compose+ArgsStorage.swift:45-56`, `Tests/Container-Compose-StaticTests/StorageArgsTests.swift`.

- [ ] Replace each `args.append(contentsOf: ["--device", device])` (loop) with a single `warnUnsupportedRuntimeFieldOnce` per non-empty array.
- [ ] Same for `--sysctl`.
- [ ] Update tests.
- [ ] Coverage flip.

**QA per CHAOS-1373:**

```sh
swift test --filter StorageArgsTests 2>&1 | tail -5                                                # exit 0
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3                                   # exit 0
grep -cE 'args.append.*"--(device|sysctl)"' Sources/Container-Compose/Commands/Compose+ArgsStorage.swift   # expect 0
grep -cE 'warnUnsupportedRuntimeFieldOnce.*"service\.(devices|sysctls)"' Sources/Container-Compose/Commands/Compose+ArgsStorage.swift  # expect 2
```

**Commit:** `feat(args): warn-and-skip --device / --sysctl (CHAOS-1373)`

#### 2.4 — CHAOS-1374: `--ip` / `--ip6` / `--mac-address`

**Files to modify:** `Sources/Container-Compose/Commands/Compose+ArgsNetworking.swift:54-62, 124`, `Tests/Container-Compose-StaticTests/NetworkArgsTests.swift`.

- [ ] For `--ip` and `--ip6` (currently emitted from `service.networks.<n>.ipv4_address` / `ipv6_address`): replace emission with `warnUnsupportedRuntimeFieldOnce`. Keep the field-name granularity in the warning (e.g., `"service.networks.<name>.ipv4_address"`).
- [ ] For `--mac-address` (line 124): replace standalone emission with `warnUnsupportedRuntimeFieldOnce`. **NOTE**: apple/container DOES support mac-address inside `--network <name>,mac=...`. A future Tier 1 wireup could compose into the network arg; for now, just warn-skip.
- [ ] Update tests.
- [ ] Coverage flip.

**QA per CHAOS-1374:**

```sh
swift test --filter NetworkArgsTests 2>&1 | tail -5                                                # exit 0
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3                                   # exit 0
grep -cE 'args.append.*"--(ip|ip6|mac-address)"' Sources/Container-Compose/Commands/Compose+ArgsNetworking.swift   # expect 0
grep -cE 'warnUnsupportedRuntimeFieldOnce' Sources/Container-Compose/Commands/Compose+ArgsNetworking.swift          # expect >= 5 (existing 2 + new 3)
```

**Commit:** `feat(args): warn-and-skip --ip / --ip6 / --mac-address (CHAOS-1374)`

#### 2.5 — CHAOS-1375: Advanced resource flags

**Files to modify:** `Sources/Container-Compose/Commands/Compose+ArgsResource.swift:46-127`, `Tests/Container-Compose-StaticTests/ResourceArgsTests.swift`.

Flags to convert (subject to Phase 0.4 exclusions): `--memory-reservation`, `--memory-swappiness`, `--memory-swap`, `--pids-limit`, `--shm-size` *(EXCLUDE if Phase 0.4 confirmed upstream support — keep emission as-is)*, `--cpu-shares`, `--cpuset-cpus`, `--cpu-period`, `--cpu-quota`, `--cpu-rt-period`, `--cpu-rt-runtime`, `--cpu-count`, `--cpu-percent`, `--oom-kill-disable`, `--oom-score-adj`.

- [ ] For each, wrap emission in `warnUnsupportedRuntimeFieldOnce` with the matching `service.<field>` key.
- [ ] **Pre-check on `--shm-size`:** before editing, run the Phase-0.4 grep again. If `--shm-size` is in fork → leave emission. If not → include in this sweep.
- [ ] Update test cases (15 flags × at least 1 test each = ~15-20 cases).
- [ ] Coverage flips for each row.

**QA per CHAOS-1375:**

```sh
swift test --filter ResourceArgsTests 2>&1 | tail -5                                               # exit 0
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3                                   # exit 0

# Count: emissions for the 14 expected-flipped flags should be 0
EXPECTED_FLIPPED='--memory-reservation|--memory-swappiness|--memory-swap|--pids-limit|--cpu-shares|--cpuset-cpus|--cpu-period|--cpu-quota|--cpu-rt-period|--cpu-rt-runtime|--cpu-count|--cpu-percent|--oom-kill-disable|--oom-score-adj'
grep -cE "args.append.*\"($EXPECTED_FLIPPED)\"" Sources/Container-Compose/Commands/Compose+ArgsResource.swift    # expect 0

# --cpus / --memory / --ulimit emissions stay intact (these ARE upstream-supported)
grep -cE "args.append.*\"--cpus\"" Sources/Container-Compose/Commands/Compose+ArgsResource.swift                  # expect 1+
grep -cE "args.append.*\"--memory\"" Sources/Container-Compose/Commands/Compose+ArgsResource.swift                # expect 1+
grep -cE "args.append.*\"--ulimit\"" Sources/Container-Compose/Commands/Compose+ArgsResource.swift                # expect 1+

# --shm-size: depends on Phase 0.4 — if upstream supports, expect 1; else 0
grep -cE "args.append.*\"--shm-size\"" Sources/Container-Compose/Commands/Compose+ArgsResource.swift              # 1 OR 0 depending on phase 0.4
```

**Commit:** `feat(args): warn-and-skip advanced resource flags not in apple/container (CHAOS-1375)`

#### 2.6 — CHAOS-1376: `--gpus` / `--blkio-*`

**Files to modify:** `Sources/Container-Compose/Commands/Compose+ArgsResource.swift:131-173`, `Tests/Container-Compose-StaticTests/GpusBlkioTests.swift`.

Currently `--gpus` and `--blkio-*` flags are emitted with a `print("Note: ... may reject this flag.")` warning. Per Momus v1 review, this "warn-emit" pattern is ineffective — the runtime errors anyway. Convert to true `warnUnsupportedRuntimeFieldOnce` skip-emit.

- [ ] Delete the emission AND the `print(...)` warning at line 149 (`Note: 'gpus' is parsed and forwarded as --gpus...`) AND the print at line 172 (`Note: 'blkio_config' is parsed and forwarded...`).
- [ ] Replace with `warnUnsupportedRuntimeFieldOnce("service.gpus", ...)` and `warnUnsupportedRuntimeFieldOnce("service.blkio_config", ...)`.
- [ ] Update `GpusBlkioTests` (or whichever existing tests cover these — verify file existence first via `ls Tests/Container-Compose-StaticTests/ | grep -i 'gpu\|blkio'`).
- [ ] Coverage flip.

**QA per CHAOS-1376:**

```sh
swift test --filter "GpusBlkio|ResourceArgs" 2>&1 | tail -5                                       # exit 0
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3                                   # exit 0
grep -cE 'args.append.*"--(gpus|blkio-weight|blkio-weight-device|device-read-bps|device-write-bps|device-read-iops|device-write-iops)"' Sources/Container-Compose/Commands/Compose+ArgsResource.swift    # expect 0
grep -cE 'warnUnsupportedRuntimeFieldOnce.*"service\.(gpus|blkio_config)"' Sources/Container-Compose/Commands/Compose+ArgsResource.swift   # expect 2
grep -c 'may reject this flag' Sources/Container-Compose/Commands/Compose+ArgsResource.swift       # expect 0 (old warn-emit removed)
```

**Commit:** `feat(args): convert --gpus / --blkio-* from warn-emit to skip-emit (CHAOS-1376)`

#### 2.7 — CHAOS-1377: `container build` flag audit

**This is an AUDIT, not a warn-skip edit.** Different shape from 2.1-2.6. Goal: enumerate every flag Container-Compose emits to `container build` and verify each against upstream's `BuildCommand` flag set; remediate or file follow-on tickets for any silent failures.

##### Steps

- [ ] **Read upstream's `BuildCommand` source:**
  ```sh
  cat .build/checkouts/container/Sources/ContainerCommands/BuildCommand.swift
  ```
  Capture every `@Option` and `@Flag` declaration (long name + short name if any).
- [ ] **Read Container-Compose's emission:**
  ```sh
  grep -nE '"--[a-z-]+"' Sources/Container-Compose/Commands/ComposeBuild.swift
  ```
  Capture every flag string.
- [ ] **Diff:** for each Container-Compose emission, check whether it appears in upstream's BuildCommand. Produce a comparison table:

  | Container-Compose emits | Upstream BuildCommand has | Action |
  |---|---|---|
  | `--build-arg` | yes/no | keep / warn-skip |
  | `--file` | yes/no | keep / warn-skip |
  | ... | ... | ... |

- [ ] For each Tier 0 flag found (Container-Compose emits, upstream doesn't): remediate inline (warn-skip pattern from 2.1-2.6) OR file a new sub-issue under CHAOS-1370 if scope is large.
- [ ] Specifically verify: `--shm-size` on `container build` (suspected missing — Phase 0.4 only checked `container run`), `--target`, `--cache-from`, `--cache-to`, `--secret`, `--ssh`.

##### QA per CHAOS-1377

The audit step is **manual** (set comparison), not a shell one-liner — Swift ArgumentParser uses three different declaration forms (`customLong`, `.long`, `.shortAndLong`) that don't normalize cleanly. Per Momus v3 review, a naive `customLong`-only extraction misses most flags.

**Step 1 — Enumerate upstream BuildCommand flags manually:**

- [ ] Open `.build/checkouts/container/Sources/ContainerCommands/BuildCommand.swift` and enumerate every `@Option`/`@Flag` declaration. For each, record the CLI name:
  - `customLong("name")` → CLI flag is `--name`
  - `.long` paired with `var camelCase:` → CLI flag is `--camel-case` (kebab-case-conversion)
  - `.shortAndLong` paired with `var camelCase:` → CLI flag is `--camel-case` plus `-c` (first letter)
  - `[.short, .customLong("name")]` → CLI flag is `--name` plus `-<short>`
- [ ] Write the enumerated list to `docs/plans/chaos-1377-build-audit.md` as a Markdown table:
  | Upstream flag | Declaration form | Source line |

**Step 2 — Enumerate Container-Compose's emissions:**

- [ ] Run:
  ```sh
  grep -nE 'args\.append.*"--[a-z-]+"|args\s*\+=.*"--[a-z-]+"' Sources/Container-Compose/Commands/ComposeBuild.swift
  ```
- [ ] Add to the same audit doc as a second table:
  | Compose-Compose emits | Source line | Compose field source |

**Step 3 — Diff manually (set difference of Step 1 ∩ Step 2):**

- [ ] For each flag in Step 2's table, check whether it appears in Step 1's. Mark each as:
  - `OK` (upstream supports — no action)
  - `TIER 0` (upstream doesn't support — silent failure; remediate via warn-skip per Recipe A)

**Step 4 — Remediation (if any TIER 0 flags found):**

- [ ] Apply Recipe A (warn-and-skip pattern) to each TIER 0 build flag in `Sources/Container-Compose/Commands/ComposeBuild.swift`.
- [ ] Update or add tests. **NOTE:** `ComposeBuildRuntimeArgvTests` may not yet exist — verify with `ls Tests/Container-Compose-StaticTests/ | grep -i ComposeBuild` before referencing. If it doesn't exist, add tests to existing `ComposeBuildParsingTests` or create a new `ComposeBuildRuntimeArgvTests` per the test-file convention.

**QA per Step 4 (if remediation happened):**

```sh
# Adapt test filter to actual file name discovered in Step 4 prerequisite check
swift test --filter ComposeBuild 2>&1 | tail -5                                                    # exit 0
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3                                   # exit 0

# Verify each removed emission no longer present (per Tier 0 list from Step 3)
# Example for hypothetical --shm-size on build:
# grep -c 'args.append.*"--shm-size"' Sources/Container-Compose/Commands/ComposeBuild.swift   # expect 0 if remediated
```

**QA per Step 1-3 (audit-only):**

```sh
# The audit deliverable IS the comparison table at docs/plans/chaos-1377-build-audit.md
ls docs/plans/chaos-1377-build-audit.md && wc -l docs/plans/chaos-1377-build-audit.md   # file exists; non-empty
grep -c '^|' docs/plans/chaos-1377-build-audit.md                                       # expect >= 20 (at least two tables with several rows each)
```

Pass criteria: audit doc committed; if any TIER 0 found, remediation tests pass; build still green.

**Commit (if remediation needed):** `feat(build): warn-and-skip <flag-list> not in apple/container BuildCommand (CHAOS-1377)`
**Commit (if audit-only, no Tier 0 findings):** `docs(plans): document container build flag audit findings (CHAOS-1377)`

#### 2.8: Coverage notes batch update

After all sub-issues land, update each affected `coverage.html` row note ONCE:

- [ ] Replace `"... unconditionally emits --<flag> which upstream 'apple/container' does not yet accept (silent failure)..."` with `"... decoded; warn-skipped via warnUnsupportedRuntimeFieldOnce..."`.
- [ ] Run `bash scripts/regen-coverage.sh` to validate JSON.

**QA per Phase 2.8:**

```sh
bash scripts/regen-coverage.sh    # exit 0; expected aggregate counts
python3 -c "import json; d=json.load(open('coverage.json')); print('partial:', d['counts']['partial'])"   # expect same partial count as before edit
grep -c "silent failure" coverage.html   # expect significant decrease (was 25; should be <5)
```

**Exit gate Phase 2:**

1. All 7 sub-issues have their commits, each isolated PRs (or one mega PR if the user prefers).
2. `swift test --filter Container-Compose-StaticTests` exits 0; new tests assert warn-skip on every Tier 0 flag.
3. **Smoke test** on a runtime-equipped Mac: `container-compose up` against a compose file that sets `service.security_opt`, `service.ipc`, `service.devices`, etc. → should print Note warnings and proceed to `up`, NOT fail with `unknown option`. Specific test fixture: `Sample Compose Files/Tier0-smoke/docker-compose.yaml` (create it as part of the PR with one service touching every Tier 0 flag).
4. `coverage.html` regenerates clean; status bars show the same partial count (note text changed but status didn't).
5. Linear: CHAOS-1371-1377 transitioned to Done; CHAOS-1370 transitioned to Done; PR links pasted as comments.

---

### Phase 3 — Tier 1 wireup (~1-2 days)

**Goal:** Implement Tier 1 wireable items now that Tier 0 cleanup has cleared the deck.

#### 3.1 — CHAOS-1368: Named volume runtime CRUD

This is the headline Tier 1 item.

- [ ] **Smoke test first** (30 min on runtime-equipped Mac): does `container run -v <name>:<path>` resolve named volumes? Run:
  ```sh
  container volume create test-vol
  container run --rm -v test-vol:/data alpine:3 sh -c "touch /data/foo && ls /data"
  container volume rm test-vol
  ```
  - **Pass:** `foo` shown in output → upstream resolves names → proceed with replacement.
  - **Fail:** source treated as host path (creates `./test-vol` directory) → file new sub-issue under CHAOS-1378 (upstream FR for named-volume `-v` resolution); **abort Phase 3.1**, leave hardlink-dir fallback in place.
- [ ] If smoke passes:
  - Replace `~/.containers/Volumes/<project>/<name>/` hardlink-dir with `container volume create <project>-<name>` (or just `<name>` if scoping differs).
  - Files: `ComposeUp.swift:212-440` (volume creation), `ComposeUp.swift:820-880` (service volume bind), `ComposeCreate.swift` parallel logic.
  - Wire `volumes.<n>.driver_opts` → `--opt KEY=VALUE` (CHAOS-1335 partial; verifies upstream supports).
  - Wire `volumes.<n>.labels` → `--label KEY=VALUE` on volume create.
  - Update `ComposeDown.swift` to remove volumes on `down` (CHAOS-1339 was just truncation fix; this is broader).
  - Update warn-message at `ComposeUp.swift:870-871` (currently misleading).
- [ ] Tests: new `Tests/Container-Compose-StaticTests/NamedVolumeRuntimeTests.swift` covering 6+ cases (create, mount, driver_opts, labels, cleanup, cross-project sharing).
- [ ] Coverage: flip `top.volumes` partial → ok; flip `volume.driver_opts` partial → ok; flip `volume.labels` partial → ok; remove `service.volumes (named-volume short form)` row OR flip to ok.
- [ ] Docs: update `docs/feature-parity.md` Appendix B (§13) to reflect resolution; close CHAOS-1368.

**QA per CHAOS-1368:**

```sh
# Static tests
swift test --filter NamedVolumeRuntimeTests 2>&1 | tail -5     # exit 0
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3 # exit 0
# Code-state assertions
grep -c "createVolumeHardLink\|hardlink" Sources/Container-Compose/Commands/ComposeUp.swift    # expect 0 or only in deprecated comments
# Smoke (runtime-equipped only)
.build/release/container-compose up -f "Sample Compose Files/Healthchecked Redis/docker-compose.yaml"
container volume list | grep healthchecked-redis-redis-data    # expect named volume present
.build/release/container-compose down -f "Sample Compose Files/Healthchecked Redis/docker-compose.yaml"
container volume list | grep -c healthchecked-redis-redis-data # expect 0 (cleaned up)
```

Pass criteria: static tests pass; code no longer references hardlink fallback; named volume created + cleaned up correctly via runtime API.

**Commit:** `feat(volumes): replace hardlink-dir fallback with native container volume create (CHAOS-1368)`

#### 3.2 — CHAOS-1336 (deferred): `deploy.resources.reservations`

- [ ] **Verify upstream state first:**
  ```sh
  grep -E '"--memory-reservation"|customLong\("memory-reservation"\)' .build/checkouts/container/Sources/Services/ContainerAPIService/Client/Flags.swift
  ```
  - **No matches:** `--memory-reservation` still not upstream → don't wire; leave decode-only with note. Comment on CHAOS-1336 with deferral reason; transition to "Blocked" or comment-and-leave.
  - **Match:** Now landed → proceed with wireup.
- [ ] **If wireable:**
  - In `Sources/Container-Compose/Commands/Compose+ArgsResource.swift:31-48`: extend the `mem_reservation` block to also check `service.deploy?.resources?.reservations?.memory`. Same precedence pattern as `cpus`/`memory` limits (top-level wins over deploy).
  - Same for `cpus`: extend to check `service.deploy?.resources?.reservations?.cpus`.
  - Tests: `Tests/Container-Compose-StaticTests/ResourceArgsTests.swift` add 4 cases:
    1. `deploy.resources.reservations.memory` → emits `--memory-reservation` when `mem_reservation` not set.
    2. `mem_reservation` wins over `deploy.resources.reservations.memory` when both set.
    3. `deploy.resources.reservations.cpus` → emits `--cpus` (or appropriate flag).
    4. Neither set → no flag emitted.
  - Coverage: flip `deploy.resources.reservations.cpus` / `memory` partial → ok.

**QA per CHAOS-1336:**

```sh
# Pre-check (gates the rest of the work)
grep -E '"--memory-reservation"' .build/checkouts/container/Sources/Services/ContainerAPIService/Client/Flags.swift
# If pre-check passed:
swift test --filter ResourceArgsTests 2>&1 | tail -5    # exit 0; 4 new cases
swift test --filter Container-Compose-StaticTests 2>&1 | tail -3   # exit 0
grep -c "deploy?.resources?.reservations" Sources/Container-Compose/Commands/Compose+ArgsResource.swift   # expect 2 (cpus + memory)
```

Pass criteria: pre-check determines path; if proceeding, all 3 commands succeed.

**Commit:** `feat(args): wire deploy.resources.reservations runtime application (CHAOS-1336)` OR comment-only deferral.

**Exit gate Phase 3:**

1. CHAOS-1368 smoke test passed (or formally deferred with new sub-issue filed).
2. CHAOS-1336 wireup completed OR deferred with comment on Linear ticket.
3. `make build` exit 0; `swift test --filter Container-Compose-StaticTests` exit 0; `swift test --filter Container-Compose-DynamicTests` exit 0 if runtime available.
4. `lsp_diagnostics` clean.
5. Linear: CHAOS-1368/1336 closed (or commented with deferral reason).

---

### Phase 4 — Coverage + docs reconciliation (~1-2 hr)

**Goal:** Align all docs with post-Phase-3 reality.

- [ ] `coverage.html` final pass: every flipped row note now matches actual code state (no more "silent failure" for fields that have been remediated).
- [ ] `docs/feature-parity.md`:
  - §1 TL;DR: update Tier 0 count downward (was 22 sites; now ~14 since shm_size / cap-add / cap-drop / ulimit are upstream-supported and warn-skip cleanup landed).
  - §3 Tier 0: mark each remediated row with link to PR.
  - §4 Tier 1: mark CHAOS-1368 status.
  - §9.3 NEW tickets table: update statuses (CHAOS-1370 → Done if Phase 2 finished).
- [ ] `docs/upstream-fork-status.md` §1: refresh with the post-merge fork commit list.
- [ ] `AGENTS.md` §4 "Coverage vs. compose-spec": refresh totals from `bash scripts/regen-coverage.sh` output.
- [ ] `README.md`: no changes likely needed.

**QA per Phase 4:**

```sh
bash scripts/regen-coverage.sh                                  # exit 0
python3 -c "import json; d=json.load(open('coverage.json')); print(d['counts'])"   # outputs new aggregate; record in commit message
grep -c "silent failure" coverage.html                          # expect 0
grep "Tier 0" docs/feature-parity.md | head -3                  # confirm count updated
```

**Commit:** `docs: reconcile feature-parity, coverage, and AGENTS.md after Phase 0-3`

**Exit gate Phase 4:**

1. `bash scripts/regen-coverage.sh` exits 0 with new aggregate counts.
2. `python3 -c "import re,json; ..."` JSON validation passes.
3. Manual review: every row note in coverage.html accurately describes runtime state.
4. AGENTS.md §4 totals match the new aggregate.

---

### Phase 5 — Final verification + Linear hygiene (~1 hr)

- [ ] **Aggregate verification commands** (must all pass before merge of any Phase 0-4 PR):
  ```sh
  make build                                          # exit 0
  swift test --filter Container-Compose-StaticTests   # exit 0
  bash scripts/regen-coverage.sh                      # exit 0, expected count
  ```
- [ ] **Linear closure batch:**
  - **Already-shipped (close with PR/SHA reference, no code change):**
    - CHAOS-1367 → close with reference to `Compose+Pull.swift:56-61` and PR for CHAOS-1344 (already in main)
  - **Phase 1 closures:**
    - CHAOS-1366, 1369, 1363 → Done with PR links
  - **Phase 2 closures:**
    - CHAOS-1370, 1371, 1372, 1373, 1374, 1375, 1376, 1377 → Done with PR links
  - **Phase 3 closures:**
    - CHAOS-1368 → Done with PR link OR deferred comment
    - CHAOS-1336 → Done with PR link OR deferred comment
  - **Comment-and-leave (still pending fork or upstream):**
    - CHAOS-1334, 1335 → comment with current state (likely stays Backlog if fork patch needed)
    - CHAOS-1378 (FR campaign) → comment with progress; sub-issues stay open until upstream FRs filed
- [ ] **Outdated cleanup:** Per `bg_37b5fab4`, close CHAOS-1300, 1301, 1302 as duplicates of 1315/1318/1317.
- [ ] **Branch cleanup:** `git push origin --delete` any stale per-phase branches once their PRs merge.

**QA per Phase 5:**

```sh
# Build + test (full)
make build && swift test --filter Container-Compose-StaticTests
# Linear-side
linear issues list --team CHAOS --project "Container Compose" --output json | \
  jq '[.[] | select(.state == "Backlog" and (.title | test("Tier 0|silent failure")))] | length'   # expect 0
linear issues list --team CHAOS --project "Container Compose" --output json | \
  jq '[.[] | select(.state == "Backlog")] | length'                                                # expect <= 5
```

**Exit gate Phase 5:**

1. All Phase 0-4 PRs merged; main has clean build.
2. Linear backlog query shows no remaining Tier 0 / silent-failure tickets in Backlog.
3. Total open backlog (excluding Tier 5 / fork-engineering / FR campaign) is <= 5.

---

## 5. Risks & open questions

1. **Fork merge conflicts** — apple/container's recent activity (PR #1421 NetworkResource refactor, PR #1488 shm-size) may conflict with our 6 fork patches. Mitigation: do the merge in a separate branch first; if conflicts are non-trivial, file CHAOS sub-issue and consider rebasing fork's patches onto upstream main one-by-one.

2. **CHAOS-1368 smoke test outcome** — drives Phase 3.1 binary path. Until the smoke test runs, named volume CRUD work is an open question. Plan accommodates either outcome.

3. **`--shm-size` regression** — after Phase 0 fork bump, if `--shm-size` doesn't actually work end-to-end (e.g., the upstream PR has a bug or the fork merge introduced a defect), Container-Compose's emission becomes a regression. Mitigation: Phase 0 exit gate includes `swift test` and a manual smoke run.

4. **CHAOS-1377 (build flag audit)** — may surface additional Tier 0 flags I haven't quantified yet. Plan keeps it in Phase 2 but allows scope expansion.

5. **Linear hygiene drift** — the recent batch (CHAOS-1370-1385) plus existing tickets (CHAOS-1334-1369) creates ~25 active items. Phase 5 cleanup is essential to keep the backlog tractable for the next person.

6. **Smoke-test environment** — several phases assume a runtime-equipped Mac. If executor doesn't have one, mark dynamic verification as deferred-to-CI and proceed with static-test-only gates. Document in PR.

7. **Stale plan risk** — this v2 was rewritten after Momus rejected v1 for citing already-shipped work. Re-verify each "in scope" item with the QA pre-checks before starting; codebase moves fast.

---

## 6. Verification matrix (pre-merge per phase)

| Phase | Build | StaticTests | DynamicTests | Diagnostics | Linear |
|---|---|---|---|---|---|
| 0 (fork bump) | required | required | optional | required | comment on CHAOS-1325 (fork dependency); update CHAOS-1370 with newly-landed flags list |
| 1.1 (CHAOS-1366) | required | required | optional | required | close CHAOS-1366 |
| 1.2 (CHAOS-1369) | required | required | optional | required | close CHAOS-1369 |
| 1.3 (CHAOS-1363) | required | required | n/a | required | close CHAOS-1363 |
| 2.1-2.7 (Tier 0 sweep) | required | required | **required** if runtime available — smoke test for absence of `unknown option` errors | required | close CHAOS-1371-1377 + 1370 |
| 3.1 (CHAOS-1368) | required | required | **required** for smoke test | required | close CHAOS-1368 OR file new sub-issue |
| 3.2 (CHAOS-1336) | required | required | optional | required | close CHAOS-1336 OR comment deferral |
| 4 (docs) | n/a | n/a | n/a | n/a | comment on all open tickets touched |
| 5 (final) | required (full) | required (full) | required if runtime available | required (full) | batch close per §5 + close CHAOS-1367 (already shipped) |

---

## 7. Effort estimate

Total: **~3-4 dev-days** if executed sequentially by one person; **~1.5-2 days** with judicious parallelism (Phase 1 sub-tasks are independent; Phase 2 sub-issues are independent).

Reduced from v1's 4-5 days because R1, R2, and CHAOS-1367 are already shipped.

| Phase | Effort | Notes |
|---|---|---|
| 0 | 1-2 hr | Fork merge dominates |
| 1 | 2-3 hr | 3 small isolated PRs (down from 5 in v1) |
| 2 | 6-10 hr | 7 small isolated PRs (or one batch) |
| 3 | 1-2 days | CHAOS-1368 is the long pole |
| 4 | 1-2 hr | Mechanical doc reconciliation |
| 5 | 1 hr | Linear hygiene + final verification |

---

## 8. Recipe reference

This plan invokes the following playbooks from the recipe library (assembled in `bg_27b0d5bf` of the planning session):

- **Recipe A (Tier 0 Cleanup)** — Phase 2 sub-issues. Pattern reference: PR #39, CHAOS-1329/1330/1331.
- **Recipe B (Fork Patch + Wireup)** — not invoked in this plan (no new fork patches; only the merge in Phase 0).
- **Recipe C (Decode + Runtime Bind-Mount)** — partially invoked for Phase 3.1 (named volume CRUD shares the materialization-at-runtime pattern). Pattern reference: PR #46, CHAOS-1333.
- **Recipe D (Coverage Flip)** — Phase 4 batch updates. Pattern reference: PR #48, CHAOS-1338.
- **Recipe E (CLI Subcommand Addition)** — not invoked.

---

## 9. Out of scope deferrals (track for next planning cycle)

These are NOT in this plan but the user should know they exist:

- **CHAOS-1334** (network IPAM extensions) — needs fork patch. Candidate for a follow-on "Tier 2 fork-patch sweep" plan.
- **CHAOS-1335** (volume `driver_opts`) — partially addressed by CHAOS-1368 wireup but propagation requires verification.
- **CHAOS-1378 family** (Tier 3 FRs) — campaign of 7 upstream issue filings on `apple/container`. Each is ~30 min of writing + linking. Could be batched into a single half-day session.
- **`--stop-signal` (PR #1462)** — once upstream merges, fork bump in next planning cycle and wireup is trivial.
- **`extra_hosts` (PR #1340)** — once upstream merges, CHAOS-1330 unlocks (was previously remediated to warn-skip; can be re-wired to emit `--add-host` properly).

---

## 10. Rollback plan

Each phase = own commit on own branch. If anything breaks:

- **Phase 0 (fork bump)** — `git revert` the `Package.resolved` commit; the fork repo can stay merged but Container-Compose pins to the previous SHA.
- **Phases 1-3** — per-commit revert; no cross-repo coordination needed.
- **Phase 4** — pure docs; revert is cosmetic.
- **Phase 5** — Linear-only; no code revert needed. Reopen tickets if state was prematurely flipped.

---

## 11. Out-of-band: what this plan does NOT do

- Does not file new Linear tickets (the 16 tickets in CHAOS-1370/1378 families are sufficient).
- Does not modify the `coverage.html` rendering layer (the JSON tuple + JS aggregator is unchanged; this plan only adds rows / flips statuses).
- Does not introduce a new doc tier system (the proposal in `bg_40e40de2` to add `FORK`/`STUB` tiers is a future enhancement, deferred to a separate UX redesign plan).
- Does not pursue any Tier 5 (frontier) work — `service.models`, `service.provider` (CHAOS-1332) stay tracked-only.
- Does not address the architectural PRD (CHAOS-1345); separate planning cycle.
- Does not re-do R1, R2, or CHAOS-1367 — verified already shipped during planning.

---

## References

- Audit: [`docs/feature-parity.md`](../feature-parity.md)
- Public matrix updates: PR #72 (`coverage.html` Tier 0 reflection)
- Prior plan that drained the previous queue: [`docs/plans/no-upstream-refactor-and-linear.md`](./no-upstream-refactor-and-linear.md)
- Upstream PR landings: apple/container [#1488 (--shm-size)](https://github.com/apple/container/pull/1488), [#1383 (--cap-add/--cap-drop)](https://github.com/apple/container/pull/1383), [#1462 (--stop-signal in-flight)](https://github.com/apple/container/pull/1462), [#1340 (extra_hosts in-flight)](https://github.com/apple/container/pull/1340), [#1421 (NetworkResource refactor)](https://github.com/apple/container/pull/1421)
- Linear team: **CHAOS** (project: Container Compose)
- Recipe playbooks: extracted in `bg_27b0d5bf` (this session); to be promoted to `docs/plans/recipes.md` if useful long-term
- Momus review: 2026-05-01, v1 rejected with 3 blockers (R1/R2 stale, file-path errors, missing executable QA); v2 fixes all three.
