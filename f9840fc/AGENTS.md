# AGENTS.md — Container-Compose

Guidance for autonomous coding agents working in this repository.

This file is the canonical orientation for agents (and humans) joining the project.
Read it before exploring. It mirrors the structure of `CLAUDE.md` / `AGENTS.md`
conventions used in agent-driven workflows.

---

## 1. Project Summary

**Container-Compose** is a Swift 6.1 CLI that brings *limited* Docker Compose
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

| Package                | Source                                        | Purpose                          |
| ---------------------- | --------------------------------------------- | -------------------------------- |
| `swift-argument-parser`| github.com/apple/swift-argument-parser ≥1.5.1 | CLI parsing                      |
| `container`            | github.com/mcrich23/container (custom branch) | Apple Container client APIs      |
| `Yams`                 | github.com/jpsim/Yams ≥5.0.6                  | YAML decoder                     |
| `Rainbow`              | github.com/onevcat/Rainbow ≥4.0.0             | ANSI-colored per-service output  |

Note the `container` dependency points at `mcrich23/container` on branch
`add-command-option-group-function-macro` — this is an upstream-fork that
exposes the macro `Container-Compose` needs to compose subcommands. Keep this
in mind when bumping versions.

---

## 3. How the Code Is Organized

### 3.1 Codable Structs (Schema → Swift)

Every top-level Compose entity has a dedicated `Codable` struct. The decoder
goes through `Yams.YAMLDecoder().decode(DockerCompose.self, …)`.

| File                       | Type                  | Compose entity       |
| -------------------------- | --------------------- | -------------------- |
| `DockerCompose.swift`      | `DockerCompose`       | root document        |
| `Service.swift`            | `Service`             | `services.<name>`    |
| `Build.swift`              | `Build`               | `service.build`      |
| `Healthcheck.swift`        | `Healthcheck`         | `service.healthcheck`|
| `Deploy.swift`             | `Deploy`              | `service.deploy`     |
| `DeployRestartPolicy.swift`| `DeployRestartPolicy` | `deploy.restart_policy` |
| `DeployResources.swift`    | `DeployResources`     | `deploy.resources`   |
| `ResourceLimits.swift`     | `ResourceLimits`      | `…resources.limits`  |
| `ResourceReservations.swift`| `ResourceReservations`| `…resources.reservations` |
| `DeviceReservation.swift`  | `DeviceReservation`   | `…reservations.devices[]` |
| `Network.swift` / `ExternalNetwork.swift` | `Network`, `ExternalNetwork` | `networks.<name>` |
| `Volume.swift`  / `ExternalVolume.swift`  | `Volume`,  `ExternalVolume`  | `volumes.<name>`  |
| `Secret.swift`  / `ExternalSecret.swift`  | `Secret`,  `ExternalSecret`  | `secrets.<name>`  |
| `Config.swift`  / `ExternalConfig.swift`  | `Config`,  `ExternalConfig`  | `configs.<name>`  |
| `ServiceSecret.swift` / `ServiceConfig.swift` | `ServiceSecret`, `ServiceConfig` | service-level refs |

Most structs implement custom `init(from:)` to accept multiple YAML shapes
(string vs. array, scalar vs. object). `Service.init(from:)` enforces the
runtime invariant *"a service must have either `image` or `build`"*.

`Service.topoSortConfiguredServices(_:)` does a DFS topological sort over
`depends_on` and detects cycles. It also populates `dependedBy` on each
service for reverse-graph queries.

### 3.2 Commands

All subcommands conform to `AsyncParsableCommand`. There are **19 subcommands**
registered in `Application.swift`:

| Subcommand     | Purpose                                                |
| -------------- | ------------------------------------------------------ |
| `up`           | Start project containers (topo-sorted, profile-filtered, includes/extends/scale resolved) |
| `down`         | Stop and remove project containers                     |
| `start`        | Start existing stopped project containers              |
| `stop`         | Stop running project containers (reverse topo order)   |
| `restart`      | Stop + start                                           |
| `build`        | Build project images without running                   |
| `ps`           | List project containers (NAME / IMAGE / STATUS / PORTS) |
| `ls`           | List active compose projects on the host               |
| `logs`         | Stream logs from project containers (`-f`, `--tail`)   |
| `pull`         | Pull (or skip-pull / always-pull) project images       |
| `config`       | Print fully-resolved/normalized compose YAML           |
| `run`          | Spawn a one-off container with overrides              |
| `exec`         | Run a command inside an existing project container     |
| `kill`         | Send a signal to project containers (default `SIGKILL`) |
| `rm`           | Remove stopped project containers                      |
| `create`       | Provision containers without starting (capability-probed) |
| `watch`        | Polling-based file monitor honoring `develop.watch[]`  |
| `top`          | Shell out to `container exec <id> ps -ef` per running project container |
| `port`         | Resolve `<service> <private-port>` against `service.ports` |
| `events`       | 1s-polling synthetic event stream (create/start/stop/die/destroy) |
| `push`         | Shell out to `container image push <image>` per service |
| `version`      | Print tool version                                      |

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

| File | Owns |
| ---- | ---- |
| `Compose+ArgsBase.swift` | `ArgsContext` struct |
| `Compose+ArgsLifecycle.swift` | platform, name, detach, stdin/tty, init, stop_signal/grace_period, runtime, restart-warn, logging |
| `Compose+ArgsSecurity.swift` | user, privileged, read_only, cap_add/drop, security_opt, userns_mode, group_add |
| `Compose+ArgsResource.swift` | cpus, memory, mem_*, pids/shm/oom/cpu_*, ulimits, gpus, blkio_config |
| `Compose+ArgsNetworking.swift` | ports, networks (list+map+aliases), hostname, dns, extra_hosts, domainname, expose, mac_address, network_mode, ipc, pid, uts |
| `Compose+ArgsStorage.swift` | working_dir, tmpfs, devices, sysctls, warn-skip volumes_from/storage_opt/device_cgroup_rules |
| `Compose+ArgsLabels.swift` | service.labels |
| `Compose+ConfigsAndSecrets.swift` | service-level configs/secrets bind-mounts |
| `Compose+Wait.swift` | `waitForCondition(_:condition:)` for depends_on object form |

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

Current totals (post no-upstream-sweep):

| Status      | Count   | %     |
| ----------- | ------- | ----- |
| Implemented | **142** | 73.2% |
| Partial     | 34      | 17.5% |
| Missing     | 18      | 9.3%  |
| **Total**   | **194** | 100%  |

Recent shifts: Phase 3 added inline-content + env-var sources for
top-level `configs` (file / content / environment) and env-var sources
for `secrets` (file / environment), promoting those rows from `partial`
to `ok`. Phase 4 reclassified 14 decode-only service fields with no
apple/container equivalent (`annotations`, `attach`, `cgroup`,
`cgroup_parent`, `credential_spec`, `device_cgroup_rules`, `isolation`,
`label_file`, `post_start`, `pre_stop`, `pull_refresh_after`,
`storage_opt`, `use_api_socket`, `volumes_from`) from `partial` to
`miss` for honesty — they're decoded with a runtime warn-and-skip but
will not be wired further without an upstream change.

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
  via fork-patched `container run` support (CHAOS-1321)

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
  + `RuntimeArgvTests` + per-command `Compose<Name>RuntimeArgvTests`.
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
- **Build invariants.** A `Service` must have `image` *or* `build` — the
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
  `swift test` before pushing.

### High-leverage open work

CHAOS-1299 closed the four missing CLI subcommands (`top`, `port`,
`events`, `push`). Recent B-sweep PRs (#19–#23) decoded a pile of
service/healthcheck/deploy/secret/config niche fields. Remaining work
sorts into three tiers:

All Tier 1 items shipped (CHAOS-1314 through CHAOS-1318 series); see the new "Currently no-upstream-actionable" subsection below for active work.

#### Currently no-upstream-actionable

The no-upstream queue is mostly drained. Active items include:
- **CHAOS-1333** — Compose configs + secrets: runtime bind-mount support
- **CHAOS-1338** — [Tracked tech debt] Compose fields with no apple/container equivalent (coverage portion only)

All other open Linear issues (CHAOS-1332, CHAOS-1334, CHAOS-1335, CHAOS-1336, CHAOS-1337) are upstream-blocked and tracked separately in Tier 2 and Tier 3.

#### Tier 2 — Upstream-dependent (apple/container)

The `full-chaos/container` fork closes the original Tier 2 backlog. All
six items below shipped via fork patches + Container-Compose wiring; the
fork itself is *ahead* of `apple/container`, not where new platform
features come from.

- ✅ **CHAOS-1319** — `service_healthy` enforcement via
  `ContainerSnapshot.health`
- ✅ **CHAOS-1320** — `service_completed_successfully` exit-code
  verification via `ContainerSnapshot.lastExitCode`
- ✅ **CHAOS-1321** — `restart` policy emitted as `--restart` flag on
  `container run`
- ✅ **CHAOS-1322** — `compose logs --since` / `--timestamps` via
  `ContainerLogOptions`
- ✅ **CHAOS-1323** — `compose events` native streaming via
  `ContainerClient.events()`
- ✅ **CHAOS-1324** — standard `-e`/`-u`/`-w`/`-d` flags on
  `compose run` / `exec` via `Flags.ProcessBase`

#### Tier 3 — Scope-deferred / won't-do

7. **Swarm-only deploy fields** — `replicas`, `update_config`,
   `rollback_config`, `placement`, `endpoint_mode`, `mode`. Decoded as
   stubs; runtime semantics belong to a different orchestrator class.
8. **Deprecated fields** — `links`, `external_links`, `volumes_from`.
   Either decoded as no-op or intentionally skipped.

---

## 7. Build & Run

```sh
# Build
make build           # release config, copies binary to .build/release/

# Install globally
make install         # symlinks into /usr/local/bin (sudo may be required)

# Run tests
swift test                                  # both targets
swift test --filter Container-Compose-StaticTests  # parsing only

# Use locally
.build/release/container-compose up -f path/to/docker-compose.yml
```

CI lives under `.github/workflows/`. Treat any failure there as blocking.

---

## 8. References

- Compose spec (canonical):
  https://github.com/compose-spec/compose-go/blob/main/schema/compose-spec.json
- `depends_on` schema anchor (lines 277-310): defines list vs. object form
  with `condition`, `required`, `restart`.
- Apple Container: https://github.com/apple/container
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
