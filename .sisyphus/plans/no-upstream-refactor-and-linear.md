# Plan — No-Upstream Refactor + Linear Implementation Sweep

**Author:** Sisyphus
**Date:** 2026-04-29
**Repo:** `/Users/chris/projects/full-chaos/Container-Compose`
**Trigger:** User asked for a plan to refactor + implement remaining Linear issues that don't require apple/container upstream changes.

---

## 1. Goal

Drain the **no-upstream** backlog for Container-Compose by:
1. Finishing the refactors AGENTS.md still hints at (`pullImage` dedupe, env-merge consolidation, doc refresh).
2. Implementing the only Linear issues that explicitly do not need fork patches (CHAOS-1333, CHAOS-1338 coverage portion).
3. Producing crisp evidence that everything else is genuinely upstream-blocked, so future agents stop re-investigating.

After this plan ships, the no-upstream Linear queue for Container-Compose should be **empty**.

---

## 2. Scope decisions (with evidence)

### IN scope (will implement)

| ID | Title | Evidence it's no-upstream |
|---|---|---|
| **R1** | Replace `ComposeRun.swift:352` private `pullImage` with shared `Compose+Pull.swift:19` helper | Pure refactor; helper already exists |
| **R2** | Consolidate `.env` + env_file + environment merging | Pure refactor; logic duplicated in `ComposeUp.swift:582-601`, `ComposeCreate.swift:361-375`, `ComposeRun.swift:265-280` |
| **R3** | AGENTS.md refresh (Tier 1 fully shipped, Tier 2 fully shipped, document new no-upstream queue state) | Docs only |
| **CHAOS-1333** | Configs + secrets: full source resolution. **Configs:** `file:` ✅, `content:`, `environment:`. **Secrets:** `file:` ✅, `environment:` (no `content:` per compose-spec). Bind-mount via temp files. | Issue description: *"Container-Compose only, no fork patches."* `Compose+ConfigsAndSecrets.swift` already mounts `file:` sources via `-v hostPath:target`; we expand source resolution to cover the remaining cases |
| **CHAOS-1338 (partial)** | Flip 14 decode-only-no-equivalent coverage rows from `partial` → `miss` | Pure docs/coverage update; the umbrella ticket explicitly lists this as one of two acceptable outcomes |

### OUT of scope (upstream-blocked — documented for future reference)

| ID | Why upstream-blocked | Evidence |
|---|---|---|
| CHAOS-1332 (models/provider runtime) | apple/container has no LLM model runtime | Issue description: *"Likely no [equivalent] — may need to integrate with apple/container as a fork patch"* |
| CHAOS-1334 (network driver_opts/attachable/enable_ipv6/internal/ipam) | `container network create` has no equivalent flags | Issue description: *"Most don't have one today. Where an equivalent doesn't exist: fork-patch container to add"* |
| CHAOS-1335 (volume driver_opts + improved named-volume handling) | `container volume` API needs extension | Issue description: *"Fork-patch container if volume options API needs extension"* |
| CHAOS-1336 (deploy.resources.reservations) | `container run` only has `--cpus`/`--memory` (hard VM allocation, not reservation semantics) | `.build/checkouts/container/docs/command-reference.md:40-41` — only limits flags exist; reservations are semantically distinct |
| CHAOS-1337 (build.entitlements → `--allow`) | `container build` has no `--allow`/entitlement flag | `grep allow\|entitlement\|insecure` in `BuildCommand.swift` → no matches |
| `compose watch` `sync+restart` / `sync+exec` partial | Both need `container cp` equivalent | `ComposeWatch.swift:208-211, 220-223` literally says *"requires 'container cp' equivalent (not yet available)"* |
| CHAOS-1338 (full umbrella) | Decision-making ticket; the work portion is the coverage flip handled above | — |

---

## 3. Phases

Each phase ends with a passing `swift test --filter Container-Compose-StaticTests` and clean diagnostics. Each is a separate PR with its own CHAOS-style commit subject.

### Phase 0 — Branch + baseline (5 min)

- [ ] Create branch `feat/no-upstream-sweep` off `main`.
- [ ] `make build` to confirm clean baseline.
- [ ] `swift test --filter Container-Compose-StaticTests` to confirm green baseline.

**Exit gate:** Both succeed. If either fails, stop and triage before proceeding.

### Phase 1 — R1 + R3 quick wins (~1 hr)

#### 1.1 — R1: Remove `ComposeRun` `pullImage` duplicate

- [ ] Read `Compose+Pull.swift:19` to confirm signature parity with `ComposeRun.swift:352`.
- [ ] If signatures differ, adapt the shared helper (it already serves `ComposePull` + `ComposeCreate`; keep changes additive).
- [ ] Delete `ComposeRun.swift:350-398` (the `// MARK: - Pull image helper` block).
- [ ] Update the callsite earlier in `ComposeRun.swift` (search for `try await pullImage(`) to call the shared helper.
- [ ] `lsp_diagnostics` clean on `ComposeRun.swift`.
- [ ] `swift test --filter ComposeRun` (and any pull-related tests) green.

**Commit:** `refactor: drop ComposeRun's private pullImage in favor of shared helper (CHAOS-1315 follow-up)`

#### 1.2 — R3: AGENTS.md refresh

- [ ] In §6 "High-leverage open work":
  - Remove the entire Tier 1 numbered list (items 1-6 all shipped). Replace with a one-liner pointing at the no-upstream queue.
  - Remove the Tier 2 "Shipped" list duplication; the sentence above already says "All six items below shipped".
  - Add a new "Currently no-upstream-actionable" subsection listing CHAOS-1333 + CHAOS-1338-coverage and noting all others need fork patches.
- [ ] In §1 "Project Summary": no change.
- [ ] In §4 "Coverage": after Phase 4 lands, totals will shift; defer any number changes to Phase 4's commit.

**Commit:** `docs: refresh AGENTS.md — Tier 1/2 fully shipped, document no-upstream queue`

**Exit gate for Phase 1:**

1. **R1 verification** — `swift build -c release` exits 0; `lsp_diagnostics` on `ComposeRun.swift` returns zero error-severity entries; `grep -c "private func pullImage" Sources/Container-Compose/Commands/ComposeRun.swift` prints `0` (the duplicate is gone); `grep -c "func pullImage" Sources/Container-Compose/Commands/Compose+Pull.swift` still prints `1` (the shared helper survives).
2. **R3 verification (concrete content checks on AGENTS.md)** — run all four greps; each must produce the expected exit code:
   ```sh
   # The Tier 1 numbered list header was removed
   ! grep -q "^#### Tier 1 — Actionable now" AGENTS.md
   # The new "Currently no-upstream-actionable" subsection was added
   grep -q "Currently no-upstream-actionable" AGENTS.md
   # CHAOS-1333 is now mentioned in §6
   grep -q "CHAOS-1333" AGENTS.md
   # The Tier 2 "Shipped:" duplicate list was removed (the bullet headers gone)
   ! grep -q "^Shipped:$" AGENTS.md
   ```
   All four must exit 0 with the negation semantics shown (`!` lines). Any failure means the doc edit is incomplete.
3. **CI** — both commits pushed; the GitHub Actions workflow is green for the branch.

### Phase 2 — R2: Consolidate env merging (~2-3 hr)

**Scope clarification:** This is a **pure refactor** with no schema or behavior change. The current model and merge precedence stay exactly as they are today; we are only lifting duplicated code into one shared function. If a model change (e.g. supporting null-value environment keys per compose-spec) becomes desirable, it goes into a separate follow-up issue, not this phase.

Exact current types (verified at planning time):
- `Service.environment` is `[String: String]?` — `Sources/Container-Compose/Codable Structs/Service.swift:48`.
- `service.env_file` decodes into `[EnvFileEntry]?` — `Sources/Container-Compose/Codable Structs/EnvFileEntry.swift:22-46`.
- The merge in `ComposeUp.swift:582-602` starts from `environmentVariables` (a `[String: String]` already populated upstream from the `.env` file) — process env is **not** part of the merge today; do not introduce it.

**Exact current precedence (from `ComposeUp.swift:584-602`, `ComposeCreate.swift:361-377`, `ComposeRun.swift:265-282` — all three are identical):**

```swift
var combinedEnv: [String: String] = environmentVariables  // baseline
if let envFiles = service.env_file {
    for entry in envFiles {
        // … skip non-existent + non-required …
        combinedEnv.merge(loadEnvFile(path: resolved)) { current, _ in current }
        //                                                ^^^^^^^^^^^^^^^^^^^^^^ baseline wins on conflict
    }
}
if let serviceEnv = service.environment {
    combinedEnv.merge(serviceEnv) { old, new in
        guard !new.contains("${") else { return old }
        return new  // service.environment overrides ONLY when new value has no `${`
    }
}
// then `${VAR}` substitution applied to .mapValues
```

Resulting rules the refactor MUST preserve **exactly**:
- **Baseline beats env_file on conflict** (`{ current, _ in current }`). The baseline is whatever the caller passes (today: vars loaded from the project's `.env` file).
- **Earlier env_file entries beat later env_file entries** (same closure — first write wins).
- **`service.environment` overrides previous keys** when the new value is a literal — but it **keeps the previous value** when the new value contains `${` (the merge defers `${VAR}` resolution to the post-merge substitution step).
- `${VAR}` substitution runs **after** the merge in the caller (NOT inside the helper).

#### 2.1 — Identify the duplication

- [ ] Re-read the three callsites verbatim and confirm they implement the rules above:
  - `ComposeUp.swift:584-608`
  - `ComposeCreate.swift:361-377`
  - `ComposeRun.swift:265-282`
- [ ] Note per-callsite **post-merge** transforms (these stay outside the helper): ComposeUp also runs `${VAR}` substitution + service-name→IP rewrite; ComposeRun layers `--env` CLI overrides last.

#### 2.2 — Lift to a shared helper

- [ ] Add to `Helper Functions.swift` (or a new `Compose+Environment.swift`):
  ```swift
  /// Merge service env preserving current Container-Compose precedence:
  ///   1. Start from `baseline` (caller-provided, typically loaded from the
  ///      project's `.env` file).
  ///   2. For each entry in `serviceEnvFile` (in declared order), load the file
  ///      and merge with **first-writer-wins** semantics — baseline values and
  ///      earlier env_file entries are NEVER overridden. `entry.required == false`
  ///      with a missing file is silently skipped.
  ///   3. Merge `serviceEnvironment` on top: a key is overridden ONLY when the
  ///      service.environment value does NOT contain `${`. Values with `${` are
  ///      treated as references and the existing key is kept (the caller is
  ///      expected to run `${VAR}` substitution AFTER calling this helper).
  /// The helper does NOT perform substitution, runtime overrides, or service-name
  /// → IP rewriting. Those stay in the caller.
  static func mergeServiceEnvironment(
      baseline: [String: String],
      serviceEnvFile: [EnvFileEntry]?,
      serviceEnvironment: [String: String]?,
      projectDirectory: String
  ) -> [String: String]
  ```
- [ ] Replace the 3 callsites. Per-callsite post-merge transforms (substitution, IP rewrite, `--env` overrides) stay inline in their respective commands — only the duplicated merge body moves into the helper.
- [ ] Add unit tests in `Tests/Container-Compose-StaticTests/EnvironmentMergeTests.swift` (new file) covering exactly these 6 cases (matching current behavior):
  1. Empty inputs return the baseline unchanged.
  2. env_file value does **not** override a baseline key with the same name (baseline wins).
  3. Earlier `env_file` entries beat later `env_file` entries on conflict.
  4. `service.environment` with a literal value overrides a key from baseline / env_file.
  5. `service.environment` with a value containing `${...}` does **not** override the existing key (substitution is the caller's job).
  6. Missing env_file with `required: false` is silently skipped; merge result is unchanged. (`required: true` enforcement is out of scope of this refactor — current behavior is also silent skip.)

#### 2.3 — Verify

- [ ] `lsp_diagnostics` clean on all four touched files.
- [ ] `swift test --filter EnvironmentMergeTests` green.
- [ ] `swift test --filter Container-Compose-StaticTests` green (regression check).

**Commit:** `refactor: consolidate service environment merging into shared helper`

**Exit gate for Phase 2:** Tests green, no behavior change in existing snapshot tests.

### Phase 3 — CHAOS-1333: Configs + secrets full source resolution (~3-5 hr)

#### 3.1 — Design temp-file strategy

- [ ] Decide temp dir location: `~/.containers/Compose/<project>/configs-secrets/` (parallels existing `~/.containers/Volumes/<project>/`).
- [ ] Decide cleanup: full-project `compose down` (no service args) removes the project's temp dir — see §3.4 for the partial-down safety rule.
- [ ] Decide naming: **`<config|secret>-<name>-<sha256short>`** where `<sha256short>` is the first 12 hex chars of the SHA-256 of the resolved content bytes. Single dash separator throughout. Single-source-of-truth examples: `config-inline_cfg-7a9b1c8d4e2f`, `secret-env_secret-3f0a55e7d8b9`. Identical content collides on the same filename so two services referencing the same `content:`/`environment:` source reuse one file. **The smoke-test glob in §3 Phase 3 exit gate item 3 (`config-inline_cfg-*`) and the §3.5 reuse test depend on this exact format — keep them in sync.**

#### 3.2 — Extend Codable structs (already decoded — verification step)

Verified at planning time, no decoding work needed:
- `Sources/Container-Compose/Codable Structs/Config.swift:75-76` decodes both `content` and `environment`.
- `Sources/Container-Compose/Codable Structs/Secret.swift:71-72` decodes `environment`. (Compose-spec does not define `secret.content`; do not add one.)

- [ ] Re-confirm via `grep` immediately before starting Phase 3 (catches any model regression that landed between plan-write and execution):
  ```sh
  grep -n 'content = try' "Sources/Container-Compose/Codable Structs/Config.swift"
  grep -n 'environment = try' "Sources/Container-Compose/Codable Structs/Config.swift" "Sources/Container-Compose/Codable Structs/Secret.swift"
  ```
  Each command must print at least one matching line. If any are missing, expand 3.2 to actually add the field; otherwise skip the rest of 3.2.
- [ ] If any parsing-test additions become necessary (none expected), they go into the existing file `Tests/Container-Compose-StaticTests/SecretConfigNicheTests.swift` (which already covers niche secret/config decoding fields). Do not create new `*ParsingTests.swift` files for this — there is no such file in the suite today.

#### 3.3 — Expand `Compose+ConfigsAndSecrets.swift`

- [ ] In the `guard let sourceFile = topLevel.file else { ... }` block (lines 52, 86), replace warn-skip with a switch:
  - `topLevel.file != nil` → existing path (resolve tilde, bind-mount).
  - `topLevel.content != nil` → write content to temp file, bind-mount that path.
  - `topLevel.environment != nil` → read host env var, write value to temp file, bind-mount.
  - All-nil → keep warn-skip but route through a single `print("Warning: …")` at the bottom.
- [ ] Same logic mirrored for secrets (lines 71-103).
- [ ] Extract the temp-file write into a small helper function so configs and secrets share it.

#### 3.4 — Cleanup hook in `compose down` (full-project only)

`ComposeDown` accepts a service-list argument (`ComposeDown.swift:38-39`) and filters down to just those services + their reverse-dep tree (`ComposeDown.swift:129-134`). Because temp-file names are content-addressed (sha256 of inline content / env-var value, see §3.1), two services CAN share the same temp file. Therefore: deleting the project's `configs-secrets/` directory on every `down` call is unsafe — a partial down could remove files still mounted by sibling services that remain up.

**Cleanup policy:**

- Only clean when `self.services.isEmpty` (full-project `down`). The plain `container-compose down` invocation hits this case; `container-compose down web` does not.
- Implementation in `ComposeDown.run()`, after `stopOldStuff(services, remove: false)`:
  ```swift
  if self.services.isEmpty, let projectName {
      let secretsDir = URL(fileURLWithPath: NSString(string: "~/.containers/Compose/\(projectName)/configs-secrets").expandingTildeInPath)
      try? FileManager.default.removeItem(at: secretsDir)
  }
  ```
- If the directory doesn't exist, `removeItem` throws → swallowed by `try?`. No-op silent.
- Add inline doc-comment explaining the partial-down safety rule so future readers don't "improve" this into a per-service cleanup that breaks shared temp files.

**Test for the safety property** (add to Phase 3.5 list):
- New unit test: `ComposeDownConfigsSecretsCleanupTests` — given a populated `configs-secrets/` dir, `compose down` (no args) removes it; `compose down web` leaves it intact.

#### 3.5 — Tests

- [ ] In `Tests/Container-Compose-StaticTests/ConfigsAndSecretsArgsTests.swift` (new or existing):
  - Test `file:` source still emits expected `-v` arg (regression).
  - Test `content:` source writes temp file + emits `-v <tempPath>:<target>`.
  - Test `environment:` source resolves env var + writes temp file + emits `-v`.
  - Test missing env var produces a clear warning, not a crash.
  - Test multiple services referencing the same content reuse the same temp file.

#### 3.6 — Coverage update

Per the actual rows in `coverage.html` (group `id: "config"` lines 1257-1303, group `id: "secret"` lines 1203-1255), flip the following:

**Partial → Ok** (5 rows, gain "Implemented"):
- `config.file` (line 1261) — already mounted today; row note is stale ("Parsed; not mounted")
- `config.content` (line 1285) — newly mounted via temp file
- `config.environment` (line 1291) — newly mounted via temp file
- `secret.file` (line 1207) — already mounted today; row note is stale ("Parsed; not mounted at runtime")
- `secret.environment` (line 1213) — newly mounted via temp file

**Partial → Miss** (2 rows, won't-fix):
- `config.template_driver` (line 1297) — no templating engine; warn-skip stays
- `secret.template_driver` (line 1249) — no templating engine; warn-skip stays

Each flip = update the row's `status` string and rewrite the trailing note string. The header counters re-compute automatically from the data (verified at `coverage.html:1488-1507`); no manual counter edit needed.

**Commit:** `feat: configs + secrets full source resolution (file/content/environment) (CHAOS-1333)`

**Exit gate for Phase 3:**

1. **Static tests** — `swift test --filter Container-Compose-StaticTests` exits 0. The exact new `@Test` cases this phase adds (8 total, distributed as noted):
   - `ConfigsSecretsRuntimeTests` (extend the existing file at `Tests/Container-Compose-StaticTests/ConfigsSecretsRuntimeTests.swift` with these 6 cases, on top of the 4 already there at planning time):
     1. `file:` source still emits expected `-v` arg (regression on the existing path).
     2. `content:` source on a config writes a temp file under `~/.containers/Compose/<project>/configs-secrets/` and emits `-v <tempPath>:<target>`.
     3. `environment:` source on a config resolves the host env var, writes its value to a temp file, and emits `-v`.
     4. `environment:` source on a secret resolves the host env var, writes its value to a temp file, and emits `-v <tempPath>:/run/secrets/<source>`.
     5. Missing host env var produces a clear warning (printed, not thrown) and skips the mount.
     6. Two services sharing the same `content:` (or same env var value) reuse a single temp file (sha256-named so the second `build` call is a no-op write).
   - `ComposeDownConfigsSecretsCleanupTests` (new file at `Tests/Container-Compose-StaticTests/ComposeDownConfigsSecretsCleanupTests.swift` — 2 cases):
     7. `compose down` with no service args removes the project's `configs-secrets/` directory (positive case).
     8. `compose down web` (one service argument) leaves the project's `configs-secrets/` directory intact (partial-down safety per §3.4).

   The "+8" delta covers all required cases listed in §3.4 and §3.5.
2. **Diagnostics** — `lsp_diagnostics` returns no errors on `Compose+ConfigsAndSecrets.swift`, `ComposeDown.swift`, `ConfigsSecretsRuntimeTests.swift`.
3. **Manual smoke test** — One consistent working directory (the repo root) and one consistent binary path (the freshly-built release binary, no global install assumed).

   a. Build the release binary first:
   ```sh
   make build   # produces .build/release/container-compose at repo root
   BIN="$PWD/.build/release/container-compose"   # absolute path; reused below
   test -x "$BIN" || { echo "FAIL: release binary missing"; exit 1; }
   ```

   b. Create fixture `Sample Compose Files/Configs and Secrets/docker-compose.yaml` with one service that mounts each kind of source. Compose-spec requires a `services:` block, so:
   ```yaml
   services:
     smoke:
       image: docker.io/library/alpine:3
       command: ["sh", "-c", "cat /run/secrets/env_secret; cat /etc/inline_cfg; cat /etc/env_cfg; sleep 2"]
       configs:
         - source: inline_cfg
           target: /etc/inline_cfg
         - source: env_cfg
           target: /etc/env_cfg
       secrets:
         - source: env_secret
   configs:
     inline_cfg:
       content: "hello-from-content"
     env_cfg:
       environment: SMOKE_CFG_VAR
   secrets:
     env_secret:
       environment: SMOKE_SECRET_VAR
   ```

   c. Run from the **repo root** (path stays valid):
   ```sh
   FIXTURE="Sample Compose Files/Configs and Secrets"
   PROJECT="configs-and-secrets"   # = sanitized basename of FIXTURE per deriveProjectName
   SECRETS_DIR="$HOME/.containers/Compose/$PROJECT/configs-secrets"

   SMOKE_CFG_VAR=cfg-from-env SMOKE_SECRET_VAR=secret-from-env \
     "$BIN" up -d -f "$FIXTURE/docker-compose.yaml" --project-directory "$FIXTURE" --project-name "$PROJECT"
   ```

   **Pass criteria** (all four must hold; check with the SAME `$BIN` and the SAME absolute `$SECRETS_DIR`):
   - The `up` command exits 0.
   - `ls "$SECRETS_DIR"` lists exactly 3 files (one per source: `inline_cfg`, `env_cfg`, `env_secret`).
   - `cat "$SECRETS_DIR"/config-inline_cfg-*` prints exactly `hello-from-content`.
   - After `"$BIN" down -f "$FIXTURE/docker-compose.yaml" --project-directory "$FIXTURE" --project-name "$PROJECT"` exits 0, `ls "$SECRETS_DIR" 2>/dev/null | wc -l` returns `0` (cleanup verified per §3.4).

   If the `container` runtime is not available on the dev host, document this in the PR description and mark the smoke test as deferred to CI on a runtime-capable host. Do NOT skip the unit-test cases (those run without the runtime).
4. **Linear** — comment on CHAOS-1333 with PR link; transition state to In Review.

### Phase 4 — CHAOS-1338: Coverage honesty for decode-only fields (~1 hr)

For these 14 fields, flip `coverage.html` rows from `partial` → `miss` with a note column citing the upstream-equivalent absence:

```
service.annotations          — labels variant; no apple/container equivalent
service.attach               — Docker attach mode; no equivalent
service.cgroup               — Linux cgroup config; no equivalent
service.cgroup_parent        — Linux cgroup config; no equivalent
service.credential_spec      — Windows-only; no equivalent
service.device_cgroup_rules  — Linux cgroup rules; no equivalent
service.isolation            — Windows-only; no equivalent
service.label_file           — file-based labels; no equivalent
service.post_start           — lifecycle hook; no equivalent
service.pre_stop             — lifecycle hook; no equivalent
service.pull_refresh_after   — pull-policy timing; no equivalent
service.storage_opt          — Linux storage opts; no equivalent
service.use_api_socket       — Docker API socket forwarding; no equivalent
service.volumes_from         — deprecated; no equivalent
```

- [ ] In `coverage.html`, for each of the 14 fields above, locate the row in the `"id": "service"` group (rows array spans roughly lines 322-876). Change the second element from `"partial"` to `"miss"` and rewrite the trailing note string to match the §3 Phase 4 evidence column ("…; no apple/container equivalent").
- [ ] Do **not** edit any header counter — the counters are computed by JS at runtime from the data array (see `coverage.html:1488-1507`). Editing them would create drift; the assertions in the exit gate below verify the JS-derived counts are correct.
- [ ] Regenerate `coverage.json` locally via `scripts/regen-coverage.sh` to confirm the extractor still parses (file is gitignored — do not commit).
- [ ] Skip README screenshot update (out of scope; opens its own follow-up if needed).

**Commit:** `docs: flip 14 decode-only no-equivalent rows from partial → miss (CHAOS-1338)`

**Exit gate for Phase 4:**

Baseline (per AGENTS.md §4 + `coverage.html:1488-1507` aggregator): **137 ok / 55 partial / 2 miss / 194 total** (70.6% / 28.4% / 1.0%).

Expected after Phase 3 + Phase 4 land together (Phase 3 contributes +5 ok, −5 partial, +2 miss; Phase 4 contributes −14 partial, +14 miss):
- **142 ok** (73.2%)
- **34 partial** (17.5%)
- **18 miss** (9.3%)
- **194 total** (unchanged)

Verification uses the dedicated extractor `scripts/regen-coverage.sh`, which parses the inline JSON `<script id="coverage-data">` block (it does NOT match the JS `labels` object on `coverage.html:1488` — that's regular code, not the data block). Naive `grep '"ok"' coverage.html` overcounts because of that labels object; do not use grep for aggregate counts. All four checks below must pass before opening the PR:

1. **Regen + aggregate count** — exits 0 and prints the expected line:
   ```sh
   bash scripts/regen-coverage.sh
   ```
   Expected stdout (exact): `wrote /…/coverage.json — 194 rows (ok=142, partial=34, miss=18)`.
   The script's print at `scripts/regen-coverage.sh:72-77` is the source of truth for this format.

2. **Per-row assertion: the 14 service fields are `miss`** — using `jq` on the regenerated JSON:
   ```sh
   jq -e '
     (.groups[] | select(.id == "service") | .rows
        | map(select(.[0] as $f
            | ["annotations","attach","cgroup","cgroup_parent","credential_spec",
               "device_cgroup_rules","isolation","label_file","post_start","pre_stop",
               "pull_refresh_after","storage_opt","use_api_socket","volumes_from"]
              | index($f)))
        | length == 14 and all(.[1] == "miss"))
   ' coverage.json
   ```
   Expected: exit 0, prints `true`. Length check guards against any field being accidentally renamed or removed.

3. **Per-row assertion: Phase-3 partial→ok flips landed correctly** — verifies the 5 rows updated by Phase 3.6 have status `ok`:
   ```sh
   jq -e '
     ((.groups[] | select(.id=="config") | .rows
        | map(select(.[0] as $f | ["file","content","environment"] | index($f)))
        | length == 3 and all(.[1] == "ok"))
      and
      (.groups[] | select(.id=="secret") | .rows
        | map(select(.[0] as $f | ["file","environment"] | index($f)))
        | length == 2 and all(.[1] == "ok")))
   ' coverage.json
   ```
   Expected: exit 0, prints `true`.

4. **Linear** — `linear i comment CHAOS-1338` with a body containing the PR link and the literal string "coverage portion complete; umbrella stays open as fork-patch decision tracker for the 14 fields above" (use stdin `-b -` form per the linear skill's piping section if posting from a file).

### Phase 5 — Final verification + Linear hygiene (~30 min)

> Note: an earlier draft of this plan included an "R4 — `Service.cpus_top` audit" phase. Verification at planning time (`grep cpus_top Sources/`) shows the field is already wired: `Codable Structs/Service.swift:211` declares it, `Codable Structs/Service.swift:356` aliases it to YAML key `cpus`, `DockerCompose.swift:501` participates in `extends` merge, and `Compose+ArgsResource.swift:32` consumes it to emit `--cpus`. R4 is therefore dropped — no code change needed.

**Tasks:**

- [ ] On the merged branch run, in order, and require each to pass before the next:
  1. `make build` — exit 0.
  2. `swift test --filter Container-Compose-StaticTests` — exit 0; expected total test count = pre-plan baseline + 8 (Phase 3: 6 in `ConfigsSecretsRuntimeTests` + 2 in `ComposeDownConfigsSecretsCleanupTests`) + 6 (Phase 2: the six `EnvironmentMergeTests` cases enumerated in §3 Phase 2.2). Net new `@Test` cases = +14.
  3. `lsp_diagnostics` over each file changed in the plan — zero `error`-severity entries; warnings allowed only if pre-existing.
- [ ] Update AGENTS.md §4 "Coverage vs. compose-spec" totals to **142 / 34 / 18 / 194** (matches Phase 4 expected counts); update the prose paragraph to state Phase 3 added inline-content + env-var sources for configs and env-var sources for secrets.
- [ ] Linear:
  - `linear i update CHAOS-1333 --state Done` and `linear i comment CHAOS-1333 -b "<PR link + summary>"`.
  - CHAOS-1338: leave Backlog (umbrella tracker); `linear i comment CHAOS-1338 -b "<PR link>; coverage portion complete; 14 partial→miss flips listed"`.
  - For each upstream-blocked open issue (1332, 1334, 1335, 1336, 1337): post a comment containing the evidence captured in §2 above so the next person doesn't re-investigate. Use `linear i comment CHAOS-XXXX -b -` with stdin from a per-issue snippet.

**Exit gate for Phase 5:**

1. All three commands above exited 0 with the expected outputs.
2. AGENTS.md §4 totals match the post-plan numbers (142 / 34 / 18 / 194).
3. `linear i list --project "Container Compose" --output json | jq '[.[] | select(.state == "Backlog")] | length'` returns ≤ 6 (the 5 upstream-blocked issues plus the umbrella; CHAOS-1333 dropped to Done).

---

## 4. Risks & open questions

1. **R2 env-merging precedence** may have subtle per-command differences I missed. Mitigation: snapshot tests on existing fixtures before refactor; diff after.
2. **CHAOS-1333 temp-file lifecycle** — if a user runs `compose up` then crashes the host, temp files leak. Acceptable for v1; could later add `compose up` to clean stale temp dirs, but out of scope here.
3. **CHAOS-1333 `environment:` source** — compose-spec is ambiguous about whether the env var is read from the host or the container. Going with host (matches Docker Compose behavior).
4. **AGENTS.md drift between phases** — Phase 1.2 refreshes the high-level Tier sections; Phases 3/4 shift coverage numbers; Phase 5 finalizes the §4 totals. Prefer per-phase commits to keep each PR self-contained.
5. **Should each phase be its own PR or one big PR?** Recommendation: separate PRs (matches recent repo convention of CHAOS-XXXX micro-PRs). Confirm with user before opening.

---

## 5. Verification matrix (pre-merge)

| Phase | Build | StaticTests | DynamicTests | Diagnostics | Other |
|---|---|---|---|---|---|
| 1 (R1+R3) | required | required | optional | required | n/a |
| 2 (R2) | required | required | optional | required | n/a |
| 3 (CHAOS-1333) | required | required | **required** if runtime available | required | smoke test fixture in `Sample Compose Files/Configs and Secrets/` (commands + pass criteria in §3 Phase 3 exit gate) |
| 4 (CHAOS-1338 cov) | n/a | n/a | n/a | n/a | `scripts/regen-coverage.sh` stdout matches expected line; jq-based per-row + aggregate assertions (commands in §3 Phase 4 exit gate) |
| 5 (cleanup) | required (final pre-merge full build) | required (final full StaticTests) | optional | required (final pass over all touched files) | Linear comments on CHAOS-1332/1334/1335/1336/1337 with §2 evidence |

---

## 6. Rollback plan

Each phase = own commit on own branch. If anything breaks:
- `git revert <sha>` the offending commit.
- Phase 3 has the most surface area (writes temp files); if rollback needed, also `rm -rf ~/.containers/Compose/<project>/` on test hosts.
- No upstream fork changes in this plan, so no cross-repo rollback coordination needed.
