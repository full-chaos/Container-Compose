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
    Codable Structs/          ← Compose schema → Swift model layer (20 files)
    Commands/
      ComposeUp.swift         ← `compose up`
      ComposeDown.swift       ← `compose down`
      ComposeBuild.swift      ← `compose build`
      Version.swift           ← `compose version`

Tests/
  Container-Compose-StaticTests/   ← parsing + helper unit tests (Swift Testing)
  Container-Compose-DynamicTests/  ← integration tests against real `container` runtime
  TestHelpers/                     ← shared fixtures (DockerComposeYamlFiles.swift)

Sample Compose Files/         ← runnable example compose files
.github/                      ← CI workflows
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

All subcommands conform to `AsyncParsableCommand`. There are **15 subcommands**
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
root. Open it in a browser; the inline JSON data is also extracted to
`coverage.json` by `scripts/regen-coverage.sh`. Current totals:

| Status      | Count   | %    |
| ----------- | ------- | ---- |
| Implemented | **130** | 67%  |
| Partial     | 30      | 15%  |
| Missing     | 34      | 18%  |
| **Total**   | **194** | 100% |

The remaining "partial" and "missing" rows fall into three buckets:
1. **Apple-container-runtime limitations**  — e.g. healthcheck condition can't
   read a true health status because `ContainerSnapshot` doesn't surface a
   `health` field; `--restart` isn't accepted by `container run`; a handful of
   network flags (`--ip-range`, `--gateway`) lack CLI equivalents.
2. **Swarm-only / orchestrator features**  — `deploy.replicas`, `deploy.update_config`,
   `deploy.placement`, `endpoint_mode`, etc.
3. **Deprecated or rarely-used fields**  — `links`, `external_links`,
   `volumes_from`, `cgroup_parent`.

### Anchor section: `depends_on` (compose-spec.json L277-L310)

End-to-end status:

- ✅ list form (`depends_on: [db, redis]`) — `DependsOn.list(...)` factory
- ✅ object form (`depends_on: {db: {condition: service_healthy}}`) — `DependsOn.entries`
- ✅ `condition: service_started` — `waitForCondition(.serviceStarted)`
- ⚠️ `condition: service_healthy` — gated, but underlying fallback to `.running`
  (TODO: true health when ContainerSnapshot exposes it)
- ⚠️ `condition: service_completed_successfully` — gated to `.stopped`,
  no exit-code verification (TODO)
- ✅ `required: true|false` — `DependsOnEntry.required` controls whether
  errors propagate or are warned
- ⚠️ `restart` — parsed on `DependsOnEntry`; pending Apple container's
  restart manager exposure

---

## 5. Testing

Two test targets, both using **Swift Testing** (`@Test` macro, not XCTest).

### Static (parsing / unit)
`Tests/Container-Compose-StaticTests/` — 9 files, ~98 tests:
- `DockerComposeParsingTests` (27)
- `EnvironmentVariableTests` (12)
- `HealthcheckConfigurationTests` (10)
- `HelperFunctionsTests` (9)
- `ServiceDependencyTests` (8)  ← list-form `depends_on` only
- `ComposeBuildParsingTests` (8)
- `BuildConfigurationTests` (8)
- `EnvFileLoadingTests` (8)
- `NetworkConfigurationTests` (8)

`TestHelpers/DockerComposeYamlFiles.swift` provides shared fixture YAML.

### Dynamic (integration against `container` runtime)
`Tests/Container-Compose-DynamicTests/`:
- `ComposeUpTests` (4 active, ~6 commented `TODO: Reenable`)
- `ComposeDownTests` (2)
- `ComposeBuildTests` (5)

Dynamic tests require a working Apple `container` runtime and do **not** run
in CI by default. Verify locally before committing.

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

The big-ticket items listed in the original AGENTS.md (depends_on object
form, healthcheck-gated startup, the property block, and the missing
subcommands) all landed in Phases 1-5. The remaining work is upstream-
dependent or scope-deferred:

1. **True `service_healthy` enforcement** — depends on Apple's `container`
   package surfacing a health field on `ContainerSnapshot`. Currently
   `Compose+Wait.swift` falls back to `.running` with a one-time warning.
2. **Exit-code verification for `service_completed_successfully`** — same
   class of issue: `ContainerSnapshot` doesn't expose exit code today, so
   we wait for `.stopped` only.
3. **`restart` policy actually applied** — Apple `container run` doesn't
   support `--restart`. When the container package adds a higher-level
   restart manager, route `service.restart` through it (and the
   `DependsOnEntry.restart` field too).
4. **FSEvents-based watcher** — `compose watch` currently polls. Upgrade to
   `FSEventStream` for low-latency change detection on macOS.
5. **`compose logs --since` / `--timestamps`** — parsed but unsupported
   because `ContainerClient.logs(id:)` lacks those parameters.
6. **`compose run` / `exec` flag namespacing** — both commands use
   `--run-env`/`--exec-env`/etc. to avoid clashes with `Flags.Process`.
   When `Flags.Process` allows opt-out of those names, switch to standard
   `-e`/`-u`/`-w`.
7. **Cross-file `extends`** (`extends: { service: foo, file: ./other.yml }`)
   currently warn-and-skips. Reuse `loadAndMerge`-style cross-file loading
   to actually pull `foo` from another file.
8. **DRY pull helpers** — `ComposePull` and `ComposeCreate` each carry a
   private copy of `pullImage`. Lift to a shared internal helper.
9. **The 34 `miss` rows in coverage.html** — most are Swarm-only
   (`deploy.replicas`, `deploy.update_config`, etc.) or deprecated
   (`links`, `external_links`). A small set is genuine leftover work:
   `cgroup_parent`, `credential_spec`, `isolation`, `label_file`,
   `models`, `post_start`, `pre_stop`, `provider`, `pull_refresh_after`,
   `use_api_socket`, plus `compose top`, `compose port`, `compose events`.

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
