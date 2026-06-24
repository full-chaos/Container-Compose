# AGENTS.md — Container-Compose

Guidance for autonomous coding agents working in this repository.

This file is the canonical orientation for agents (and humans) joining the project.
Read it before exploring. It mirrors the structure of `CLAUDE.md` / `AGENTS.md`
conventions used in agent-driven workflows.

linear project: 'Container Compose'
github: full-chaos/container-compose

---

## 1. Project Summary

**Container-Compose** is a Swift 6.1 CLI that brings _limited_ Docker Compose
support to [Apple Container](https://github.com/apple/container). It parses
`docker-compose.yml` and orchestrates services via Apple's `container` runtime
on macOS.

- **Language / toolchain:** Swift 6.1, SwiftPM, macOS 15+ (best on macOS 26 Tahoe).
- **CLI entry:** `container-compose <subcommand>` (driven by `swift-argument-parser`).
- **Distribution:** Homebrew (`brew install container-compose`) or `make build && make install`.
- **License:** MIT.

The project is **not** a Docker / Docker Compose wrapper. It directly
interprets the Compose schema and translates a (large) subset to
`container run` / `container build` / `container network create` invocations.

### Linear Issues and Project Commands

```bash
# output json for issues to parse faster, pipe to JQ.
linear issues list --project 'Container Compose' --output json
```

### Good to know

```bash
# Get all urgent issues and extract just identifiers
linear issues list --priority 1 --output json | jq -r '.[].identifier'

# Find all issues in a project
linear issues list --team ENG --output json | \
  jq '.[] | select(.projectName == "Q1 Release")'

# Count issues by state
linear issues list --team ENG --output json | \
  jq 'group_by(.state) | map({state: .[0].state, count: length})'

# Get all unassigned high-priority issues
linear issues list --priority 2 --output json | \
  jq '.[] | select(.assignee == null) | {identifier, title, state}'

# Export cycle velocity data to CSV
linear cycles analyze --team ENG --output json | \
  jq -r '.cycles[] | [.number, .completedPoints, .plannedPoints] | @csv'

# Find all issues created in the last 7 days
linear issues list --team ENG --output json | \
  jq --arg date "$(date -u -v-7d +%Y-%m-%d)" \
  '.[] | select(.createdAt >= $date) | {identifier, title, createdAt}'

# Bulk update: Get all backlog items for processing
BACKLOG_IDS=$(linear search --state Backlog --team ENG --output json | jq -r '.[].identifier')
for id in $BACKLOG_IDS; do
  echo "Processing $id..."
  # Add your automation here
done

# Generate weekly status report
cat << 'EOF' > weekly-report.sh
#!/bin/bash
TEAM="ENG"
echo "=== Weekly Status Report ==="
echo ""
echo "High Priority In Progress:"
linear issues list --team $TEAM --priority 1 --state "In Progress" --output json | \
  jq -r '.[] | "  - \(.identifier): \(.title) (@\(.assignee // "unassigned"))"'
echo ""
echo "Blocked Issues:"
linear search --has-blockers --team $TEAM --output json | \
  jq -r '.[] | "  - \(.identifier): \(.title)"'
EOF
chmod +x weekly-report.sh
```

```bash
# Monitor high-priority issues every 30 seconds
watch -n 30 "linear issues list --priority 1 --output json | jq '.[] | {id: .identifier, title: .title, state: .state}'"
```

```bash
# Export single issue and its dependencies
linear tasks export CEN-123 ./my-tasks/

# Export directly to Claude Code session
linear tasks export CEN-123 ~/.claude/tasks/a5721284-f64e-4705-8983-b7d6c4e032aa/

# Preview without writing files
linear tasks export CEN-123 ./my-tasks/ --dry-run
```

---

## 2. Repository Map

```
Sources/
  ContainerComposeApp/        ← thin executable target (just calls Application)
    application.swift
  Container-Compose/          ← library target `ContainerComposeCore`
    Application.swift         ← root AsyncParsableCommand wiring subcommands
    Errors.swift              ← YamlError, ComposeError enums
    Helper Functions.swift    ← env loading, var substitution, port parsing, paths
    PreSubcommandFlagPromotion.swift  ← global flag normalization
    ProjectFlags.swift        ← shared @OptionGroup for project flags
    Codable Structs/          ← Compose schema → Swift model layer (36 files)
    Commands/                 ← AsyncParsableCommand + per-concern argv builders (31 files)
    Runtime/                  ← ContainerClientProvider + RunCommandRunner seams

Tests/
  Container-Compose-StaticTests/   ← parsing + argv-shape tests (53 files, 724 @Test cases)
  Container-Compose-DynamicTests/  ← integration tests against real `container` runtime (11 @Test cases)
  TestHelpers/                     ← shared fixtures, RecordingRunner, RecordingContainerClientProvider

Sample Compose Files/         ← runnable example compose files
scripts/regen-coverage.sh     ← extracts coverage.json from coverage.html
.github/workflows/            ← CI workflows (Tests, gh-pages, CodeQL via default-setup)
coverage.html                 ← canonical compose-spec coverage matrix (source of truth)
coverage.json                 ← derived from coverage.html, gitignored
Package.swift                 ← SwiftPM manifest
Package.resolved              ← pinned deps
Makefile                      ← build, install, clean targets
```

### Dependencies (`Package.swift`)

| Package                 | Source                                                | Purpose                                                      |
| ----------------------- | ----------------------------------------------------- | ------------------------------------------------------------ |
| `swift-argument-parser` | github.com/apple/swift-argument-parser ≥1.5.1         | CLI parsing                                                  |
| `container`             | github.com/mcrich23/container (transitional fork pin) | Apple Container client APIs; transitional compatibility only |
| `Yams`                  | github.com/jpsim/Yams ≥5.0.6                          | YAML decoder                                                 |
| `Rainbow`               | github.com/onevcat/Rainbow ≥4.0.0                     | ANSI-colored per-service output                              |

Note the `container` dependency currently points at `mcrich23/container` on
branch `add-command-option-group-function-macro`. That fork stays pinned only
for transitional compatibility (including the macro surface container-compose
still needs today). **Canonical remote:** `apple/container` is the only
upstream that should receive new runtime work. The fork is frozen — do not plan
or file further fork patches when evaluating feature gaps.

---

## 3. How the Code Is Organized

### 3.1 Codable Structs (Schema → Swift)

Every top-level Compose entity has a dedicated `Codable` struct. The decoder
goes through `Yams.YAMLDecoder().decode(DockerCompose.self, …)`.

| File                                          | Type                             | Compose entity            |
| --------------------------------------------- | -------------------------------- | ------------------------- |
| `DockerCompose.swift`                         | `DockerCompose`                  | root document             |
| `Service.swift`                               | `Service`                        | `services.<name>`         |
| `Build.swift`                                 | `Build`                          | `service.build`           |
| `Healthcheck.swift`                           | `Healthcheck`                    | `service.healthcheck`     |
| `Deploy.swift`                                | `Deploy`                         | `service.deploy`          |
| `DeployRestartPolicy.swift`                   | `DeployRestartPolicy`            | `deploy.restart_policy`   |
| `DeployResources.swift`                       | `DeployResources`                | `deploy.resources`        |
| `ResourceLimits.swift`                        | `ResourceLimits`                 | `…resources.limits`       |
| `ResourceReservations.swift`                  | `ResourceReservations`           | `…resources.reservations` |
| `DeviceReservation.swift`                     | `DeviceReservation`              | `…reservations.devices[]` |
| `Network.swift` / `ExternalNetwork.swift`     | `Network`, `ExternalNetwork`     | `networks.<name>`         |
| `Volume.swift` / `ExternalVolume.swift`       | `Volume`, `ExternalVolume`       | `volumes.<name>`          |
| `Secret.swift` / `ExternalSecret.swift`       | `Secret`, `ExternalSecret`       | `secrets.<name>`          |
| `Config.swift` / `ExternalConfig.swift`       | `Config`, `ExternalConfig`       | `configs.<name>`          |
| `ServiceSecret.swift` / `ServiceConfig.swift` | `ServiceSecret`, `ServiceConfig` | service-level refs        |

Most structs implement custom `init(from:)` to accept multiple YAML shapes
(string vs. array, scalar vs. object). `Service.init(from:)` enforces the
runtime invariant _"a service must have either `image` or `build`"_.

`Service.topoSortConfiguredServices(_:)` does a DFS topological sort over
`depends_on` and detects cycles. It also populates `dependedBy` on each
service for reverse-graph queries.

### 3.2 Commands

All subcommands conform to `AsyncParsableCommand`. There are **19 subcommands**
registered in `Application.swift`:

| Subcommand | Purpose                                                                                   |
| ---------- | ----------------------------------------------------------------------------------------- |
| `up`       | Start project containers (topo-sorted, profile-filtered, includes/extends/scale resolved) |
| `down`     | Stop and remove project containers                                                        |
| `start`    | Start existing stopped project containers                                                 |
| `stop`     | Stop running project containers (reverse topo order)                                      |
| `restart`  | Stop + start                                                                              |
| `build`    | Build project images without running                                                      |
| `ps`       | List project containers (NAME / IMAGE / STATUS / PORTS)                                   |
| `ls`       | List active compose projects on the host                                                  |
| `logs`     | Stream logs from project containers (`-f`, `--tail`)                                      |
| `pull`     | Pull (or skip-pull / always-pull) project images                                          |
| `config`   | Print fully-resolved/normalized compose YAML                                              |
| `run`      | Spawn a one-off container with overrides                                                  |
| `exec`     | Run a command inside an existing project container                                        |
| `kill`     | Send a signal to project containers (default `SIGKILL`)                                   |
| `rm`       | Remove stopped project containers                                                         |
| `create`   | Provision containers without starting (capability-probed)                                 |
| `watch`    | Polling-based file monitor honoring `develop.watch[]`                                     |
| `top`      | Shell out to `container exec <id> ps -ef` per running project container                   |
| `port`     | Resolve `<service> <private-port>` against `service.ports`                                |
| `events`   | 1s-polling synthetic event stream (create/start/stop/die/destroy)                         |
| `push`     | Shell out to `container image push <image>` per service                                   |
| `version`  | Print tool version                                                                        |

`up` performs:

1. Locate compose file (`-f`, then `compose.yml` / `compose.yaml` / `docker-compose.yml` / `docker-compose.yaml`).
2. `DockerCompose.loadAndMerge(...).resolvingExtends()` — recursively merge `include:` files (cycle-detected) and resolve `extends:`.
3. Load `.env` file (`process.envFile` first, else `./.env`).
4. Derive project name (explicit `name:` field, else CWD basename).
5. Filter services by `--profile` (or `COMPOSE_PROFILES` env). Topo-sort by `dependsOn`.
6. Expand `service.scale > 1` into N named replicas.
7. Stop + remove existing containers.
8. Create top-level networks (driver / IPAM `--subnet` honored where Apple `container` accepts).
9. Create local hard-link directories for top-level named volumes (warn for non-`local` drivers).
10. For each service: wait on **per-dep `condition`** before starting (Phase 1.4), pull/build image (`pull_policy`-aware), assemble argv via per-concern `*Args.build` builders, spawn as a `Task`, then `waitUntilServiceIsRunning`, then resolve service-name → container-IP in env.
11. If not detached, block forever.

`down` calls `ContainerClient.stop()` (and `delete()` for `up`'s tear-down) for every container matching `<project>-<service>`.

`build` re-uses the same YAML→model pipeline and invokes
`Application.BuildCommand` with the full set of build sub-features (target,
dockerfile_inline, cache_from/to, labels, network, ssh, secrets, platforms,
shm_size).

### 3.3 Per-concern argv builders (Phase 1.1 split)

`ComposeUp.configService` no longer inlines argv emission. Each concern is in
its own extension file under `Sources/Container-Compose/Commands/`:

| File                              | Owns                                                                                                                         |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `Compose+ArgsBase.swift`          | `ArgsContext` struct                                                                                                         |
| `Compose+ArgsLifecycle.swift`     | platform, name, detach, stdin/tty, init, stop_signal/grace_period, runtime, restart-warn, logging                            |
| `Compose+ArgsSecurity.swift`      | user, privileged, read_only, cap_add/drop, security_opt, userns_mode, group_add                                              |
| `Compose+ArgsResource.swift`      | cpus, memory, mem*\*, pids/shm/oom/cpu*\*, ulimits, gpus, blkio_config                                                       |
| `Compose+ArgsNetworking.swift`    | ports, networks (list+map+aliases), hostname, dns, extra_hosts, domainname, expose, mac_address, network_mode, ipc, pid, uts |
| `Compose+ArgsStorage.swift`       | working_dir, tmpfs, devices, sysctls, warn-skip volumes_from/storage_opt/device_cgroup_rules                                 |
| `Compose+ArgsLabels.swift`        | service.labels                                                                                                               |
| `Compose+ConfigsAndSecrets.swift` | service-level configs/secrets bind-mounts                                                                                    |
| `Compose+Wait.swift`              | `waitForCondition(_:condition:)` for depends_on object form                                                                  |

Each builder takes `ArgsContext` and returns `[String]`. Side-effects (volume
dir creation, env merging) stay inline in `configService`.

### 3.3 Helpers (`Helper Functions.swift`)

Re-used across commands:

- `loadEnvFile(path:)` — robust `.env` parser (skips comments, blanks).
- `resolveVariable(_:with:)` — `${VAR}`, `${VAR:-default}`, `${VAR:?error}`.
- `resolvedPath(for:relativeTo:)` — handles `~`, relative, absolute.
- `deriveProjectName(cwd:)` — sanitizes CWD basename for container names.
- `composePortToRunArg(_:)` — Compose port spec → `container run -p` argv.

---

## 4. Coverage vs. compose-spec

The full feature-coverage matrix lives in **`coverage.html`** at the repo
root (canonical source of truth). The inline JSON data is also extracted
to `coverage.json` by `scripts/regen-coverage.sh` for downstream tooling.
`coverage.json` is gitignored — regenerate it locally if your tooling
needs it.

Current totals (post Tier 0 honesty sweep + post-CHAOS-1368 volume CRUD):

| Status      | Count   | %     |
| ----------- | ------- | ----- |
| Implemented | **119** | 60.4% |
| Partial     | 60      | 30.5% |
| Missing     | 18      | 9.1%  |
| **Total**   | **197** | 100%  |

Recent shifts:

- **Tier 0 honesty sweep (PRs #71–83)** demoted ~22 rows from `ok` to `partial` —
  Container-Compose was emitting flags `apple/container` does not accept
  (`--ipc`, `--pid`, `--uts`, `--device`, `--userns`, `--security-opt`, all
  `--blkio-*`, `--shm-size`, `--pids-limit`, `--memory-reservation`/`-swap`/
  `-swappiness`, `--cpu-shares`/`-period`/`-quota`/`-rt-*`/`-count`/`-percent`,
  `--oom-*`, `--sysctl`, `--ip`/`-6`, `--mac-address`, `--gpus`). All have
  been converted to warn-and-skip; the percentage drop reflects honest
  reality, not a regression. See `docs/feature-parity.md` Tier 0 section.
- **CHAOS-1368 / PR #85** flipped 4 volume rows from `partial` back to `ok`:
  top-level `volumes`, top-level `volumes.driver_opts`, top-level
  `volumes.labels`, and service-level `volumes (named-volume short form)`.
  apple/container's `container volume create` registry is now wired through
  `RuntimeVolumeClient`; `container run -v <name>:<path>` resolves named
  volumes via upstream `Parser.volume(...)` (Phase 0 audit GREEN).
- **Phase 3** added inline-content + env-var sources for top-level `configs`
  and env-var sources for `secrets`, promoting those rows from `partial` to
  `ok`. **Phase 4** reclassified 14 decode-only service fields with no
  apple/container equivalent (`annotations`, `attach`, `cgroup`,
  `cgroup_parent`, `credential_spec`, `device_cgroup_rules`, `isolation`,
  `label_file`, `post_start`, `pre_stop`, `pull_refresh_after`,
  `storage_opt`, `use_api_socket`, `volumes_from`) from `partial` to `miss`
  for honesty.

The remaining "partial" rows fall into two buckets:

1. **Swarm-only / orchestrator features** — `deploy.replicas`,
   `deploy.update_config`, `deploy.rollback_config`,
   `deploy.placement`, `endpoint_mode`, `mode`. Decoded as stubs;
   runtime semantics belong in a different orchestrator class.
2. **Newer compose-spec features pending wiring** — `top.models`,
   `service.models`, `service.provider` (LLM/AI provider plumbing).

`miss` rows split into two intentional buckets: deprecated compose-spec
fields (`service.external_links`, `service.links`) and the 14
decode-only service fields above plus a small set of network/volume
options where apple/container has no equivalent flag yet.

### Anchor section: `depends_on` (compose-spec.json L277-L310)

End-to-end status:

- ✅ list form (`depends_on: [db, redis]`) — `DependsOn.list(...)` factory
- ✅ object form (`depends_on: {db: {condition: service_healthy}}`) — `DependsOn.entries`
- ✅ `condition: service_started` — `waitForCondition(.serviceStarted)`
- ✅ `condition: service_healthy` — `waitForCondition(.serviceHealthy)`
  reads `ContainerSnapshot.health` from the fork (CHAOS-1319). Falls back
  to `.running` only when no healthcheck is configured on the service.
- ✅ `condition: service_completed_successfully` — gated to `.stopped`
  with `lastExitCode == 0` verification (CHAOS-1320). Throws
  `ComposeWaitError.nonZeroExitCode` on non-zero exit.
- ✅ `required: true|false` — `DependsOnEntry.required` controls whether
  errors propagate or are warned
- ✅ `restart` — parsed on `DependsOnEntry`; emitted as `--restart`
  via fork-only `container run` support today (CHAOS-1321)

---

## 5. Testing

Two test targets, both using **Swift Testing** (`@Test` macro, not XCTest).

### Static (parsing / unit / argv-shape)

`Tests/Container-Compose-StaticTests/` — **53 files, 724 `@Test` cases**.
Covers schema decoding, command flag parsing, per-concern argv emission,
and runtime seams (`RecordingRunner`, `RecordingContainerClientProvider`).
Categorical breakdown:

- **Compose-schema parsing**: `DockerComposeParsingTests`, `*ParsingTests`,
  `BuildConfigurationTests`, `HealthcheckConfigurationTests`,
  `NetworkConfigurationTests`, `DeployStubsParsingTests`,
  `ServicePropertiesParsingTests`, `DependsOnParsingTests`, etc.
- **Per-concern argv builders**: `LifecycleArgsTests`, `SecurityArgsTests`,
  `ResourceArgsTests`, `NetworkArgsTests`, `StorageArgsTests`,
  `LabelsArgsTests`, `LoggingArgsTests`, `GpusBlkioTests`.
- **Subcommand parsing + argv shape**: `Compose<Name>ParsingTests`
  - `RuntimeArgvTests` + per-command `Compose<Name>RuntimeArgvTests`.
- **Helpers**: `HelperFunctionsTests`, `EnvironmentVariableTests`,
  `EnvFileLoadingTests`, `WaitForConditionTests`,
  `PreSubcommandFlagPromotionTests`, `LineBufferTests`,
  `ProfilesTests`, `ScaleTests`, `IncludeTests`, `ExtendsTests`.

`TestHelpers/` provides:

- `DockerComposeYamlFiles.swift` — shared fixture YAML
- `RecordingRunner.swift` — captures `container <…>` argv for assertion
- `RecordingContainerClientProvider.swift` — synthetic `ContainerClient`
- `RuntimeAvailability.swift` — gates dynamic tests off when Apple
  `container` is not installed (CI-safe)

### Dynamic (integration against `container` runtime)

`Tests/Container-Compose-DynamicTests/` — 11 `@Test` cases:

- `ComposeUpTests`, `ComposeDownTests`, `ComposeBuildTests`

Dynamic tests self-skip on hosts without the Apple `container` runtime
(via `RuntimeAvailability.isAvailable()`), so `swift test` is safe to
run in CI. Verify locally with the runtime installed before committing
schema changes that ripple into `up`/`down`/`build`.

### Agent-friendly test invocations

Prefer `make test-json` over raw `swift test` when an agent (or any
automation) is parsing results. From the [Makefile](./Makefile):

- Runs the static suite via `swift test --filter Container_Compose_StaticTests`
  (underscore form — Swift 6.3.1 normalizes the dashed target name and the
  legacy `Container-Compose-StaticTests` filter matches **zero tests**).
  See PR #170 + the CHAOS-1507 follow-up.
- The previous JSONL + `swift run test-report` pipeline was removed because
  `--experimental-event-stream-output` now hangs indefinitely under Swift
  6.3.1 when no socket reader is attached. Plain swift-testing stdout is the
  canonical agent-readable surface again.
- `make test-json` still runs without `--parallel` for deterministic logs, but
  the static suite itself is now safe under `swift test --parallel` thanks to
  `CapturedOutput` serializing the global dup2 capture window. Keep the
  existing `.serialized` suites in place for the warning-capture tests.
- Exit code is the plain `swift test` exit code (0 = pass, non-zero = fail).
- **Silent-skip guard.** Both `make test-json` and the CI workflow assert that
  the static suite executes **>= 1500 tests** (current count: ~1806). If the
  filter typo'd back to a zero-match form (e.g. the dashed `Container-Compose-StaticTests`)
  the guard prints an `ERROR: filter executed only N tests` message and exits
  2 — defending against the same footgun that caused CI to be a silent no-op
  between the Swift 6.3.1 upgrade and the CHAOS-1507 follow-up.

Previously, `VolumeMountIntegrationTests` could leak real Docker Hub pulls when its environment wraps missed `RunnerEnvironment.$current`. Fixed by wrapping `RecordingRunner()` in every test. All test `projectName` values are now prefixed `cc-test-` (e.g. `cc-test-vol-up-<uuid>`) to make test-originated container names unambiguous. When sweeping this convention to other static-suite test files, use the same `cc-test-` prefix. Leaving this note as a defensive reminder.


### Resolved CI flake

CHAOS-1326 isolated the `swiftpm-testing-helper` signal-10/SIGBUS flake
to `LineBufferTests` under parallel Swift Testing. That suite now carries
`@Suite(.serialized)`, allowing CI to run plain `swift test` again without
the broad `--no-parallel` workaround from CHAOS-1314.

### Sample compose files

- `Sample Compose Files/Healthchecked Redis/docker-compose.yaml` — single-service,
  healthcheck (string form), restart policy, volume, port.

---

## 6. Conventions for Agents

- **Branch first.** Always create a branch before edits — and a worktree if
  you're parallelizing with other agents.
- **Parallel-safe scopes.** `Codable Structs/`, `Commands/`, and `Tests/` are
  largely independent — multiple agents can work in different folders without
  conflicts. Schema changes (Service, DockerCompose) ripple everywhere; serialize.
- **Tests before edits.** Add a Swift Testing `@Test` for any new schema field
  or behavior in the matching `Tests/Container-Compose-StaticTests/<Topic>Tests.swift`.
- **Build invariants.** A `Service` must have `image` _or_ `build` — the
  decoder asserts this. Don't bypass the assertion; add a fixture if you're
  testing edge cases.
- **Decoder shape-tolerance.** Many fields accept both string-and-array (e.g.
  `command`, `entrypoint`, `depends_on` list-form). Preserve this when
  extending.
- **`#warning` / "Detected, But Not Supported".** The codebase uses
  `#warning(...)` and `print("X Detected, But Not Supported")` to flag known
  gaps. When you implement one of these, remove the warning and add a test.
- **Don't break the topo sort.** `Service.topoSortConfiguredServices` is on
  the hot path of `up`. Cycle detection there must keep throwing.
- **Commits.** Small, focused commits. Rebuild with `make build` and run
  `make test-json` (which is `swift test --filter Container_Compose_StaticTests`
  under Swift 6.3.1; see PR #170 / CHAOS-1507) or full `swift test` if your
  change touches dynamics before pushing.
- **Background agents for long-running tasks.** Always dispatch test runs
  (prefer `make test-json` for structured, agent-parseable output; raw
  `swift test` only when you need the full run including
  `Container-Compose-DynamicTests`), full builds, large multi-file
  searches, and anything with a timeout/loop to a background agent
  (`task(... run_in_background=true ...)`). The agent absorbs the verbose
  output; only a structured pass/fail summary comes back to the
  orchestrator. Reserve direct `swift test --filter <Suite>` calls in the
  main context for single-suite, sub-30-second runs. Don't poll
  `background_output` — wait for the `<system-reminder>`.

### High-leverage open work

The canonical, cross-cutting view of compose-spec gaps is
[`docs/feature-parity.md`](./docs/feature-parity.md). Read it before
opening any feature ticket. It splits every gap into:

- **Tier 0 — Silent failure**: ~22 flags Container-Compose emits that
  apple/container doesn't accept. **Top priority cleanup**; pattern matches
  CHAOS-1329/1330/1331. Filed as a sweep umbrella with sub-issues.
- **Tier 1 — Wireable now**: 6 fields where runtime support exists; we
  just haven't wired or enforced. Includes CHAOS-1336, CHAOS-1368,
  partial CHAOS-1335.
- **Tier 2 — Fork-patch path (DEPRECATED)**: historical bucket only. The fork
  is frozen, so items previously parked here now reclassify to Tier 3.
- **Tier 3 — Upstream FR**: 19 features needing real apple/container
  engineering, including the old Tier 2 items. Filed as a separate FR-campaign
  umbrella.
- **Tier 4 — Won't do**: 21 fields (deprecated, Swarm-only, Linux/Windows-
  specific). Decoded → warn-skipped → `coverage.html miss`.
- **Tier 5 — Frontier**: 3 AI/LLM fields, track only (CHAOS-1332).

Fork-only features still present via the transitional pin (all reopened pending
apple/container parity):

- ⏸️ **CHAOS-1319** — fork-only impl; reopened, blocked on apple/container upstream
- ⏸️ **CHAOS-1320** — fork-only impl; reopened, blocked on apple/container upstream
- ⏸️ **CHAOS-1321** — fork-only impl; reopened, blocked on apple/container upstream
- ⏸️ **CHAOS-1322** — fork-only impl; reopened, blocked on apple/container upstream
- ⏸️ **CHAOS-1323** — fork-only impl; reopened, blocked on apple/container upstream
- ⏸️ **CHAOS-1324** — fork-only impl; reopened, blocked on apple/container upstream

For the full ticket map (existing + newly proposed) and the verified
apple/container CLI surface (Appendix A), see
[`docs/feature-parity.md`](./docs/feature-parity.md). For fork
maintenance state, see [`docs/upstream-fork-status.md`](./docs/upstream-fork-status.md).

---

## 7. Build & Run

```sh
# Build
make build           # release config, copies binary to .build/release/

# Install globally
make install         # symlinks into /usr/local/bin (sudo may be required)

# Run tests
make test-json                                     # static suite only (Swift 6.3.1 underscore filter; preferred for agents)
swift test                                         # full run including Container-Compose-DynamicTests
swift test --filter LifecycleArgsTests             # single suite (replace with target)
# Equivalent to `make test-json` if you need to invoke directly:
swift test --filter Container_Compose_StaticTests  # underscore form — dashes match 0 tests under Swift 6.3.1 (see PR #170)

# Use locally
.build/release/container-compose up -f path/to/docker-compose.yml
```

CI lives under `.github/workflows/`. Treat any failure there as blocking.

---

## 8. References

- Compose spec (canonical):
  <https://github.com/compose-spec/compose-go/blob/main/schema/compose-spec.json>
- `depends_on` schema anchor (lines 277-310): defines list vs. object form
  with `condition`, `required`, `restart`.
- Apple Container: <https://github.com/apple/container>
- This repo's coverage report: `./coverage.html`

## Linear

This project uses **Linear** for issue tracking.
Default team: **CHAOS**

### Creating Issues

```bash
# Create a simple issue
linear issues create "Fix login bug" --team CHAOS --priority high

# Create with full details and dependencies
linear issues create "Add OAuth integration" \
  --team CHAOS \
  --description "Integrate Google and GitHub OAuth providers" \
  --parent CHAOS-100 \
  --depends-on CHAOS-99 \
  --labels "backend,security" \
  --estimate 5

# List and view issues
linear issues list
linear issues get CHAOS-123
```

### Fetching private Linear images

`uploads.linear.app` URLs in issue descriptions require authentication.
Do **NOT** use `WebFetch` or `curl` — they will 401.

```bash
linear attachments download "https://uploads.linear.app/..."
# → /tmp/linear-img-<hash>.png
```

Then `Read` that path to view the image.

### Claude Code Skills

Available workflow skills (install with `linear skills install --all`):

- `/prd` - Create agent-friendly tickets with PRDs and sub-issues
- `/triage` - Analyze and prioritize backlog
- `/cycle-plan` - Plan cycles using velocity analytics
- `/retro` - Generate sprint retrospectives
- `/deps` - Analyze dependency chains

Run `linear skills list` for details.
