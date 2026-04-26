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

All subcommands conform to `AsyncParsableCommand`:

| Subcommand   | Key flags / args                                               |
| ------------ | -------------------------------------------------------------- |
| `up`         | `[services...]`, `-d/--detach`, `-f/--file`, `-b/--build`, `--no-cache` |
| `down`       | `[services...]`                                                |
| `build`      | `[services...]`, `--no-cache`, `-f/--file`                     |
| `version`    | none                                                           |

`up` performs:
1. Locate compose file (`-f`, then `compose.yml` / `compose.yaml` / `docker-compose.yml` / `docker-compose.yaml`).
2. YAML decode into `DockerCompose`.
3. Load `.env` file (`process.envFile` first, else `./.env`).
4. Derive project name (explicit `name:` field, else CWD basename).
5. Topo-sort services by `depends_on`.
6. Stop + remove existing containers for those services.
7. Create top-level networks (basic; many flags warned-but-ignored).
8. Create local hard-link directories for top-level named volumes.
9. For each service in topological order: pull/build image, assemble
   `container run` argv, spawn it as a `Task`, then `waitUntilServiceIsRunning`
   (30 s timeout, 0.5 s poll), then resolve service-name placeholders in env
   to the now-running container's IP.
10. If not detached, block forever (so `^C` tears down the user session).

`down` calls `ContainerClient.stop()` (and `delete()` only when explicitly
asked) for every container matching `<project>-<service>`.

`build` re-uses the same YAML→model pipeline and invokes
`Application.BuildCommand` from the Apple `container` package.

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
root (open in a browser). The summary:

| Layer                         | Coverage |
| ----------------------------- | -------- |
| Top-level Compose keys        | 7 / 9    |
| Service properties            | 23 / 89  |
| `depends_on` schema (L277-310)| 1 / 4 sub-features (list form only) |
| Network / Volume / Secret / Config core fields | complete |
| Compose subcommands           | 4 / ~22  |

Concrete gaps relative to compose-spec **lines 277-310** (the `depends_on`
object form):

- ✅ list-of-strings form (`depends_on: [db, redis]`) — supported and topo-sorted.
- ❌ object form (`depends_on: {db: {condition: service_healthy}}`) — decoder rejects.
- ❌ `condition: service_started | service_healthy | service_completed_successfully` — none honored at runtime.
- ❌ `required` flag — unmodeled.
- ❌ `restart` flag — unmodeled.

Healthchecks are *parsed* into `Healthcheck`, but `ComposeUp` never blocks on
them — services start in topological order and immediately progress once the
container reaches `running` state, regardless of healthcheck status.

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

1. **`depends_on` object form** (compose-spec L277-310) — extend `Service`
   with a `DependsOn` enum (list / object), wire `condition` into
   `ComposeUp.waitUntilServiceIsRunning`, and add tests in
   `ServiceDependencyTests` + `HealthcheckConfigurationTests`.
2. **Healthcheck-gated startup** — `ContainerClient` exposes status; today
   `up` only waits for `running`. Wait for `healthy` when a dependent
   declares `condition: service_healthy`.
3. **More Service properties** — high-value missing ones: `cap_add`,
   `cap_drop`, `dns`, `extra_hosts`, `labels`, `logging`, `pid`,
   `security_opt`, `sysctls`, `tmpfs`, `ulimits`, `expose`, `init`,
   `network_mode`, `pull_policy`, `profiles`. (Full list in `coverage.html`.)
4. **More subcommands** — `logs`, `ps`, `restart`, `start`, `stop`, `pull`,
   `config`, `ls` would all map cleanly onto `ContainerClient` APIs.

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
