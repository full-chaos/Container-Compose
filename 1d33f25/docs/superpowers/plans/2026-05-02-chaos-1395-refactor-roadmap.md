# CHAOS-1395 — Refactor Roadmap

> **For agentic workers:** This is a **phased roadmap**, not a single executable plan. Each phase below is a separate PR-sized chunk with its own goal, scope, and verification. When a phase is ready to execute, generate a per-phase detailed implementation plan (use `superpowers:writing-plans` against the phase summary). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the 9 verified refactor opportunities from CHAOS-1395 in independent, low-risk PRs without coupling unrelated changes.

**Architecture:** Bottom-up. Mechanical/foundational refactors first (helpers + warning consolidation) so later, riskier decompositions land on a cleaner base. Each phase is independently shippable; phases do not depend on each other unless explicitly noted.

**Tech Stack:** Swift 6.1, SwiftPM, Swift Testing (`@Test`), per-concern argv builders, `RecordingContainerClientProvider` / `RecordingRunner` test seams.

## What's NOT in this plan

The original CHAOS-1395 had 12 findings. The verification pass on the issue (see Linear comment) determined:

| Finding | Status | Why excluded |
|---------|--------|--------------|
| #1 — env merge order P0 | **WRONG** | The reviewer misread Swift's `merging` closure parameter order. `Helper Functions.swift:114` is correct as written. No code change needed. |
| #5 — `stopOldStuff` dedup | **REPLACED by CHAOS-1396** | Verification surfaced a hidden bug in ComposeUp.stopOldStuff (ignored `container_name`). Filed and fixed separately under CHAOS-1396. The shared-helper extraction can revisit this only after the bug fix lands; ComposeUp now uses the same `effectiveContainerName` helper as ComposeDown, so a `ContainerLifecycle.stopAndRemove(...)` extraction is a 1-PR follow-up. **Phase 3.x in this roadmap.** |
| #12 — `mergeServiceEnvironment` test | **DONE** | `EnvironmentMergeTests.swift` already exists with 6 `@Test` cases covering precedence rules. No work needed. |

---

## Phase ordering & rationale

| Phase | Focus | Risk | Dep | Est PRs |
|-------|-------|------|-----|---------|
| **1A** | Compose file path resolver (#2) | Low (mechanical) | — | 1 |
| **1B** | Inline warnings → `warnUnsupportedRuntimeFieldOnce` (#4) | Low (mechanical) | — | 1 |
| **2A** | `ComposeRun` `-p` filtering via `NetworkingArgs.build(includePorts:)` (#3) | Low | — | 1 |
| **2B** | `Runtime.listByProjectName(_:)` helper (#10) | Low | — | 1 |
| **3A** | Split `ComposeUp.configService` (#6) | Med | After 1B | 1–2 |
| **3B** | `ComposeServe.run()` → `validate()` extraction (#11) | Low–Med | — | 1 |
| **3C** | `ComposeWatch.dryRun(message:run:)` helper (#7) | Low | — | 1 |
| **3X** | `ContainerLifecycle.stopAndRemove(...)` (#5 replacement) | Low | After CHAOS-1396 lands | 1 |
| **4** | Wire `--no-interpolate` in `ComposeConfig` (#8) | Med (real feature) | — | 1 |
| **5** | `Service.swift` decoder refactor (#9) | High (deep) | — | 1+ |

Phases 1A, 1B, 2A, 2B, 3B, 3C, 4 are all parallelizable — no cross-dependencies. Phase 3A has the warning consolidation (1B) as a soft dep because `configService` contains 14 inline warnings that 1B should sweep first; otherwise 3A does the sweep itself.

---

# Phase 1A — Extract shared compose file path resolver (#2)

**Verified scope correction:** The original CHAOS-1395 finding said 8 commands. Verification found **22 files** with the same `supportedComposeFilenames` constant + `composePath` computed property:

ComposeUp, ComposeDown, ComposeBuild, ComposeRun, ComposeExec, ComposePs, ComposeWatch, ComposeConfig, ComposePort, ComposeTop, ComposeKill, ComposePush, ComposeRm, ComposeLogs, ComposeStart, ComposeRestart, ComposeCreate, ComposePull, ComposeStop, ComposeEvents (+ ComposePort partial).

**Goal:** One source of truth for compose-file path resolution, called by every subcommand.

**Files:**
- Create: `Sources/Container-Compose/ComposeFileResolver.swift` (or a function in `Helper Functions.swift` next to `resolveProjectDirectory`)
- Modify: 22 command files in `Sources/Container-Compose/Commands/`
- Test: `Tests/Container-Compose-StaticTests/ComposeFileResolverTests.swift` (new)

**Tasks:**
- [ ] Pick the helper home — recommend a free function `resolveComposeFilePath(explicit:cwd:)` in `Helper Functions.swift` to match `resolveProjectName` / `resolveProjectDirectory` siblings.
- [ ] **RED:** Write 4 unit tests: explicit absolute path, explicit relative path, no explicit + first supported filename present, no explicit + no file (returns canonical default).
- [ ] **GREEN:** Implement `resolveComposeFilePath(explicit: String?, cwd: String) -> String`.
- [ ] Replace `composePath` computed property in each of the 22 files with a single-line call to the helper. Prefer a sed-assisted sweep; verify each file's output with `git diff --stat`.
- [ ] Verify suite: `swift test --filter "Compose"` — every per-command parsing test still passes.
- [ ] Commit per-batch (e.g. group of 5 commands per commit) so the diff stays reviewable.

**Watch for:**
- Some commands may have minor variations (e.g. `ComposePort` only has the property, not the constant). Verify each file's exact pre-state before sweeping.
- `ComposeConfig`'s `composePath` may interact with the `--no-interpolate` work in Phase 4 — leave behavior unchanged, just relocate.

**Verification:** All static tests pass; `git grep "supportedComposeFilenames"` returns ≤ 1 result (the helper itself).

---

# Phase 1B — Consolidate inline warnings to `warnUnsupportedRuntimeFieldOnce` (#4)

**Verified scope correction:** ComposeResourceArgs was already migrated (16 calls, 0 inline). Sites the reviewer missed:

- `Sources/Container-Compose/Commands/ComposeUp.swift:148`, `:589-628` (12 sites for cgroup_parent, credential_spec, isolation, label_file, post_start, pre_stop, pull_refresh_after, use_api_socket, annotations, attach, cgroup, plus the `didWarn…` boolean pattern for service.models / service.provider — also worth migrating), `:661`, `:741`
- `Sources/Container-Compose/Commands/Compose+ArgsStorage.swift:56,61,66`
- `Sources/Container-Compose/Commands/Compose+ConfigsAndSecrets.swift:55,65,86,96`
- `Sources/Container-Compose/Commands/ComposeCreate.swift:457`
- `Sources/Container-Compose/Commands/ComposeRm.swift:183`

**Goal:** Every "Note: X is detected but not supported" line goes through `warnUnsupportedRuntimeFieldOnce` so first-occurrence dedup works across a single compose file.

**Files:**
- Modify: `Compose+UnsupportedWarnings.swift` (only if API extension needed for new warning shapes)
- Modify: 5 command files listed above
- Test: `Tests/Container-Compose-StaticTests/UnsupportedWarningsTests.swift` (new or extend existing)

**Tasks:**
- [ ] Audit `git grep -nE "print\(\"(Note|Warning):" Sources/Container-Compose/Commands/` and confirm the list above is complete.
- [ ] **RED:** For each unique warning key not yet covered, add a `@Test` asserting it dedupes within a single compose run (use `RecordingRunner` to capture stderr / use a captured-output test seam if one exists).
- [ ] **GREEN:** Replace each `print("Note: ...")` site with a `warnUnsupportedRuntimeFieldOnce(key: <field>)` call. Migrate the `didWarnServiceModelsUnsupported` / `didWarnServiceProviderUnsupported` boolean flags to the helper.
- [ ] Run: `swift test --filter "Compose"` — confirm no behavior regressions.

**Watch for:**
- Some inline warnings carry per-field detail (e.g. service name, value) — the helper signature may need a `details:` parameter or the message construction stays at the call site.
- Phase 3A (`configService` split) overlaps with the 12 warnings at ComposeUp:589-628. If 3A runs first, those move with the extracted method; if 1B runs first, 3A's split is cleaner. Recommend 1B first.

**Verification:** `git grep -nE "print\(\"Note:" Sources/Container-Compose/Commands/ | wc -l` returns 0.

---

# Phase 2A — `ComposeRun` `-p` flag filtering via `NetworkingArgs.build(includePorts:)` (#3)

**Goal:** Replace the fragile `skipNext` boolean filter (`ComposeRun.swift:244-265`) with an explicit parameter on `NetworkingArgs.build(...)`.

**Files:**
- Modify: `Sources/Container-Compose/Commands/Compose+ArgsNetworking.swift:25` (signature change)
- Modify: `Sources/Container-Compose/Commands/ComposeRun.swift:244-265` (call site)
- Modify: any other `NetworkingArgs.build(ctx)` call sites that exist (audit via grep)
- Test: `Tests/Container-Compose-StaticTests/NetworkArgsTests.swift` (extend)

**Tasks:**
- [ ] Audit: `git grep -n "NetworkingArgs.build" Sources/`. Confirm the signature change ripple.
- [ ] **RED:** Add `@Test` asserting `NetworkingArgs.build(ctx, includePorts: false)` returns a flag list with no `-p` pairs.
- [ ] **GREEN:** Add `includePorts: Bool = true` parameter to `NetworkingArgs.build`. Default is `true` so existing call sites are unchanged. In `ComposeRun`, pass `includePorts: !servicePorts` (or whatever the inverse boolean is — verify) and delete the `skipNext` filter.
- [ ] Verify: existing NetworkArgsTests + ComposeRun tests still pass.

**Verification:** No `skipNext` boolean remains in `ComposeRun.swift`; `NetworkingArgs.build` takes `includePorts` parameter.

---

# Phase 2B — `Runtime.listByProjectName(_:)` helper (#10)

**Verified scope correction:** Manual prefix filter exists in 3 files: `ComposePs.swift:138`, `ComposeTop.swift`, `ComposeEvents.swift`. The reviewer's framing ("Runtime is only wired through `compose ps`") is wrong — ComposePs itself does the manual filtering on top of the Runtime call.

**Goal:** Add a convenience method on `Runtime` so the `<project>-` prefix filter logic lives in one place.

**Files:**
- Modify: `Sources/Container-Compose/Runtime/Runtime.swift` (protocol + default implementation)
- Modify: `ComposePs.swift`, `ComposeTop.swift`, `ComposeEvents.swift`
- Test: `Tests/Container-Compose-StaticTests/RuntimeArgvTests.swift` or new `RuntimeListByProjectNameTests.swift`

**Tasks:**
- [ ] **RED:** Test `Runtime.listByProjectName("foo")` returns containers whose names start with `"foo-"` and excludes others. Use `MockRuntime` from `Tests/TestHelpers/`.
- [ ] **GREEN:** Add a default-implementation extension method on `Runtime` calling `list(filters:)` then filtering by `name.hasPrefix("\(project)-")`.
- [ ] Migrate the 3 manual call sites to use the helper.
- [ ] Verify: `swift test --filter "ComposePs|ComposeTop|ComposeEvents|Runtime"` passes.

**Watch for:**
- The `effectiveContainerName` helper (CHAOS-1396) means containers can have non-prefix names. The new helper should still work — it's a project-default filter, not a guarantee. Document that explicit `container_name` containers won't match.

**Verification:** `git grep -n 'hasPrefix("\\\\(projectName)-' Sources/` returns ≤ 1 hit (the helper).

---

# Phase 3A — Split `ComposeUp.configService` (#6)

**Verified scope:** 234 lines (562-795). Per-concern argv builders are already extracted (Phase 1.1 in AGENTS.md). What's left in `configService` is orchestration + inline parity warnings + image build/pull + volume config + env merge + network diagnostic + Task spawn.

**Goal:** Decompose `configService` into named helper methods so the orchestration is readable. Aim for `configService` to be < 80 lines, primarily a sequence of calls.

**Recommended decomposition:**
- `prepareImageAndBuild(service:serviceName:)` — pull/build with `pull_policy` semantics (lines 638-655)
- `buildEnvironment(service:dockerCompose:)` — env merge + substitution + service-IP rewriting (lines 689-708)
- `assembleRunArgs(service:context:)` — wraps the per-concern `*Args.build` calls (lines 723-729)
- `spawnServiceTask(serviceName:argv:)` — Task spawn + color assignment + entrypoint tail (lines 747-787)
- `awaitServiceReady(serviceName:explicitContainerName:)` — wait + IP update (lines 789-794)

**Files:**
- Modify: `Sources/Container-Compose/Commands/ComposeUp.swift` (split into multiple methods, possibly split file as `ComposeUp+ConfigService.swift`)
- Test: `Tests/Container-Compose-StaticTests/RuntimeArgvTests.swift` should still pass without changes.

**Tasks:**
- [ ] Snapshot existing test pass set (record argv outputs from the current end-to-end ComposeUp tests in `RuntimeArgvTests`).
- [ ] Extract `prepareImageAndBuild` first (smallest, most isolated). Verify tests pass.
- [ ] Extract `buildEnvironment`. Verify.
- [ ] Extract `assembleRunArgs`. Verify.
- [ ] Extract `spawnServiceTask`. Verify.
- [ ] Extract `awaitServiceReady`. Verify.
- [ ] Confirm `configService` is now an orchestration shell.

**Watch for:**
- `configService` is `private mutating` — extracted helpers may need to remain `mutating` if they touch `self.environmentVariables` / `self.containerIps` / `self.containerConsoleColors`. Avoid pulling state out unnecessarily.
- Inline warnings at lines 588-628 — sweep these to `warnUnsupportedRuntimeFieldOnce` first (Phase 1B) for a cleaner extraction.

**Verification:** `configService` body < 80 lines; all `RuntimeArgvTests` still pass.

---

# Phase 3B — `ComposeServe.run()` → `validate()` extraction (#11)

**Verified scope:** `ComposeServe.swift:113-206` has 8 numbered steps in `run()`: mutex enforcement, address resolution, TCP validation, TLS path resolution, idempotence detection, unix-specific setup, warning emission, daemon launch.

**Note:** AGENTS.md lists 19 subcommands but `serve` is the 20th. **Doc bug** — file as a follow-up.

**Goal:** Extract a `validate()` method that returns a struct of resolved values, leaving `run()` as: `let resolved = try validate(); try await launch(resolved)`.

**Files:**
- Modify: `Sources/Container-Compose/Commands/ComposeServe.swift`
- Test: `Tests/Container-Compose-StaticTests/ComposeServeTests.swift` (likely exists; extend with direct `validate()` tests)

**Tasks:**
- [ ] Read `ComposeServe.swift:113-206`, identify the resolved-values struct shape (address, TLS paths, idempotence flag, unix socket path).
- [ ] **RED:** Test `validate()` with valid and invalid input combinations (mutex violation, missing TLS file, etc.).
- [ ] **GREEN:** Define `ServeValidationResult` struct, extract pure validation logic into `validate()`. `run()` becomes the thin orchestrator.
- [ ] Update AGENTS.md subcommand count: 19 → 20 (include `serve`).

**Verification:** Existing ComposeServe tests pass; `validate()` is independently callable.

---

# Phase 3C — `ComposeWatch.dryRun(message:run:)` helper (#7)

**Verified scope correction:** The 5 cases in `ComposeWatch.swift:172-238` do NOT have identical dryRun branches — each prints different fields (`rule.path`, `rule.target`, `rule.exec?.command`). 3 of 5 `else` branches are placeholder diagnostics, not shell commands. **The reviewer's "dictionary of handlers" recommendation would NOT help.** A small helper is the right tool.

**Goal:** Replace 5x `if dryRun { print "..." } else { ... }` with `dryRun(message: "...") { ... }` helper.

**Files:**
- Modify: `Sources/Container-Compose/Commands/ComposeWatch.swift`
- Test: `Tests/Container-Compose-StaticTests/ComposeWatchTests.swift` (extend)

**Tasks:**
- [ ] **RED:** Test `dryRun(message: "test", run: { fail("should not run") })` when dryRun is true — only the message should print.
- [ ] **GREEN:** Add the helper. Migrate the 5 cases.
- [ ] Verify: existing ComposeWatch tests pass; visual diff of dryRun output unchanged.

**Watch for:**
- The 3 placeholder diagnostic cases (`.sync`, `.syncRestart`, `.syncExec`) print "not yet available" — preserve those messages exactly.

**Verification:** All `ComposeWatch` switch cases use the helper; no inline `if dryRun {` remains.

---

# Phase 3X — `ContainerLifecycle.stopAndRemove(...)` (#5 follow-up)

**Status:** Blocked on CHAOS-1396 landing. After CHAOS-1396, both `ComposeUp.stopOldStuff` and `ComposeDown.stopOldStuff` use `effectiveContainerName(...)` to resolve container names. The remaining duplication is the stop-then-delete loop itself.

**Goal:** Extract `ContainerLifecycle.stopAndRemove(projectName:services:remove:)` so the loop logic lives in one place. Both call sites become 1-liners.

**Files:**
- Create: `Sources/Container-Compose/Runtime/ContainerLifecycle.swift`
- Modify: `Sources/Container-Compose/Commands/ComposeUp.swift` (replace `stopOldStuff` body with helper call)
- Modify: `Sources/Container-Compose/Commands/ComposeDown.swift` (same)
- Test: `Tests/Container-Compose-StaticTests/ContainerLifecycleTests.swift` (new)

**Tasks:**
- [ ] **RED:** Test `ContainerLifecycle.stopAndRemove` with a recording provider — assert correct sequence of `.stop` / `.delete` calls.
- [ ] **GREEN:** Extract the loop. Use `effectiveContainerName` for name resolution.
- [ ] Both `stopOldStuff` methods become 1-liners delegating to the helper.
- [ ] Existing `ComposeUpContainerNameTests` + `ComposeDownConfigsSecretsCleanupTests` still pass.

**Verification:** Both `stopOldStuff` bodies < 5 lines; behavior unchanged.

---

# Phase 4 — Wire `--no-interpolate` in `ComposeConfig` (#8)

**Verified scope correction:** The reviewer said "just wire in `resolveVariable`". The file's own TODO at `ComposeConfig.swift:108` says the real fix requires walking the model and substituting on `image`, `command`, `environment` values, etc. **Larger scope than the original finding implied.**

**Goal:** When `--no-interpolate` is set, emit raw values; otherwise walk the resolved model and apply `${VAR}` substitution to every interpolatable field.

**Files:**
- Modify: `Sources/Container-Compose/Commands/ComposeConfig.swift`
- Modify: possibly `Sources/Container-Compose/Helper Functions.swift` if a model-walk helper makes sense
- Test: `Tests/Container-Compose-StaticTests/ComposeConfigTests.swift` (extend)

**Tasks:**
- [ ] Inventory which compose-spec fields are interpolatable (consult `compose-spec.json`). Examples: `image`, `command`, `entrypoint`, `environment` values, `labels` values, `volumes` source paths.
- [ ] **RED:** Test `compose config` output with `--no-interpolate` against a compose YAML containing `${USER}`. Expect raw `${USER}` in output.
- [ ] **RED:** Test `compose config` output WITHOUT `--no-interpolate` against the same YAML. Expect resolved value.
- [ ] **GREEN:** Implement model-walk substitution. Possibly add a `resolveModel(_:with:)` recursive function.
- [ ] Verify: existing ComposeConfig tests still pass; new tests pass.

**Watch for:**
- Substitution must NOT happen during YAML decoding (the model decoder is shared with `up`/`down`/etc., which interpolate at a later, runtime-aware stage). The walk must happen post-decode, only in the `config` command path.
- The `${VAR:?error}` form should NOT exit if `--no-interpolate` is set — it's a print-only command.

**Verification:** New tests pass; manual smoke test: `container-compose config --no-interpolate` on a compose file with `${VAR}` shows the literal token.

---

# Phase 5 — `Service.swift` decoder refactor (#9) — OPTIONAL

**Verified scope correction:** The reviewer claimed `init(from:)` is ~380 lines. Verified: it's **~224 lines** (582→805). Memberwise init is ~200 lines. The refactor is defensible but smaller than implied.

**Goal:** Reduce repetition in `Service.init(from: Decoder)`. Two approaches:

1. **Extraction:** Group decode calls by category (image/build, networking, security, resources, volumes/mounts) into private static helpers. ~50 lines saved.
2. **Codable-via-key-paths:** Use a custom `CodingKeys` macro or a property-wrapper-driven decoding helper. Significant code reduction; higher risk and Swift version sensitivity.

**Recommend (1)** — incremental, low-risk. Defer (2) until the codebase has a clear reason to invest.

**Files:**
- Modify: `Sources/Container-Compose/Codable Structs/Service.swift`
- Test: `Tests/Container-Compose-StaticTests/Service*ParsingTests.swift` should pass without changes (decoder behavior preserved).

**Tasks:**
- [ ] Audit existing parsing tests cover all field categories (image, build, networking, etc.).
- [ ] Extract one category at a time (e.g. `decodeNetworking(from container: KeyedDecodingContainer<CodingKeys>)`).
- [ ] Verify each extraction with the parsing-test suite.
- [ ] Repeat for remaining categories.

**Watch for:**
- The decoder enforces `image OR build` invariant (per AGENTS.md). Don't remove this guard.
- Many fields accept multi-shape input (string vs array). Preserve the existing tolerance.

**Verification:** Decoder behavior unchanged across all `Service*ParsingTests`; `init(from:)` body < 130 lines.

---

# Out-of-scope follow-ups (file as separate tickets)

While verifying CHAOS-1395, these surfaced and deserve their own tickets:

- **AGENTS.md drift** — subcommand count is 19, actual is 20 (`serve` missing). Tests dynamic count says "11 @Test cases" — verify if still true. Update during Phase 3B.
- **`container_name` + `scale: N > 1` collision** — if both are set, ComposeUp produces N replicas with the same name; runtime rejects duplicates. Docker Compose errors early. Should we validate in the decoder or up-runner? File as a P3 if anyone hits it.
- **`RuntimeAvailability.isAvailable()` doesn't probe apiserver** — currently only checks `container --version`. Dynamic test suites still get enabled even when apiserver is down, then time out for 60s × N suites at setup. Should be fixed to ping the apiserver too.

---

## Self-review

Spec coverage check (against the 9 verified-keep findings):
- #2 → Phase 1A ✓
- #3 → Phase 2A ✓
- #4 → Phase 1B ✓
- #6 → Phase 3A ✓
- #7 → Phase 3C ✓
- #8 → Phase 4 ✓
- #9 → Phase 5 ✓
- #10 → Phase 2B ✓
- #11 → Phase 3B ✓
- #5 (replacement) → Phase 3X ✓

No placeholders. No "TODO" / "TBD" markers. Type/method names consistent with the verified codebase state at HEAD as of 2026-05-02.
