# Native API Server for container-compose

> **Status:** decisions locked 2026-04-30 (Phase 0 priors). Five additional
> decisions locked 2026-05-01 by CHAOS-1349 (daemon lifecycle, HTTP library,
> socket location). Phase 1 (CHAOS-1346) shipped 2026-05-01.
> **Phase 9 (CHAOS-1359): TCP transport + TLS — SHIPPED 2026-05-01.**
> **Date:** 2026-04-30 (initial), 2026-05-01 (CHAOS-1349 lock-in)
> **Supersedes:** the Docker-API-bridge framing in `docs/plans/socktainer-pivot-summary.md`. That document recommended adopting Socktainer; this one proposes building a native server inside container-compose instead.
> **Related Linear:** CHAOS-1340 (epic), CHAOS-1345 (architecture PRD), CHAOS-1346 (Phase 1 — shipped), CHAOS-1347 (Phase 2 — HTTP server skeleton), CHAOS-1348 (Phase 3 — MockRuntime), CHAOS-1349 (this lock-in PR), CHAOS-1359 (Phase 9 — TCP/TLS — shipped).
> **Related upstream:** apple/container#1476 (closed by maintainer; redirected to Socktainer; that redirect was rejected here on UX-positioning grounds).

## Strategic positioning

`container-compose` is moving **away from Docker as a UX commitment**. It is a Compose-spec orchestrator backed by Apple's containerization libraries — not a Docker drop-in. The API server reflects this: the canonical surface is ours.

Concretely, we do **not**:

- pursue Docker Engine API parity
- ship a Docker REST "adapter" or shim — there is no separate Docker-shaped surface
- recommend `DOCKER_HOST=...; docker ps` workflows to users
- treat Socktainer (or any Docker-compat layer) as the primary path
- depend on apple/container's CLI/XPC daemon if we can avoid it

We **do**:

- talk to `apple/containerization` (the Swift package) directly, bypassing apple/container's CLI/daemon layer
- expose a single **Container REST API** designed for the container-compose ecosystem — REST-shaped, container-domain, similar in shape to Docker's surface where the underlying concepts overlap, but explicitly not bound to Docker's contract
- keep the runtime backend abstracted so we can swap apple/containerization for something else later

Ecosystem tools that can talk to our API work; tools that hardcode Docker-only assumptions are the user's problem to reconfigure or replace.

## Architecture

```
container-compose CLI / orchestrator process
├── Compose-spec parser + translator
├── Service supervisor (restart, health, dep ordering — userland orchestration)
├── Container REST API server                                 ← Phase 2 (CHAOS-1347)
│     - One surface, ours
│     - Container-domain endpoints (containers, networks, events, logs)
│     - Compose-aware where the domain demands it (services, projects)
│     - Hummingbird 2.x over Unix domain socket (Phase 2.0 stub: /_ping only)
└── Runtime abstraction protocol                              ← Phase 1 (CHAOS-1346, shipped)
    └── AppleContainerizationRuntime (only conformer at v1)
        └── apple/containerization Swift package (direct calls)
```

The boundary above the runtime protocol is what gives us portability later. The single-API design is what stops Docker semantics from sneaking in via "we'll just add one more shim endpoint."

## Locked decisions (Phase 0 priors — 2026-04-30)

| # | Decision | Alternatives | Why this decision matters |
|---|---|---|---|
| 1 | API transport: **HTTP-over-Unix-socket** as primary; HTTP-over-TCP opt-in via flag | gRPC; raw TCP; HTTP/2 only | Unix socket is the lowest-friction integration for native consumers in the same compose stack. TCP opt-in handles cross-host or container-internal use. gRPC has stricter contracts but loses ecosystem reach. |
| 2 | Daemon model: **Long-running `container-compose serve`** | Per-`up` lifecycle; leader-elect-from-CLI | Long-running daemon survives across compose-up/down cycles and gives ecosystem tools a stable endpoint. Per-project is hermetic but breaks cross-project tooling. Leader-elect is clever but a debugging nightmare. |
| 3 | API shape: **Container-domain endpoints first, with Compose-aware extensions where the domain demands it** | Pure container primitives with project labels; pure Compose primitives | Container-domain endpoints give ecosystem tools a recognizable shape; Compose extensions reflect our actual abstractions where containers-alone are insufficient. Pure-container (Socktainer's path) leaks Docker's mental model; pure-Compose makes integration unnecessarily different from familiar shapes. |
| 4 | Backend abstraction: **Define `protocol Runtime` boundary at v1**, even with one conformer | Monolithic v1, retrofit later | Cheap now (one indirection layer + minimal API surface). Expensive later (every call site must change). Designing for portability is the freedom you asked for. |

## Locked decisions (CHAOS-1349 — 2026-05-01)

These three decisions were originally Open Questions #2, #4, #5 in the previous draft. They are upstream of Phase 2 (CHAOS-1347) — pinning them down before Phase 2 implementation prevents redesigning under pressure.

### Decision #5 — Daemon lifecycle: **Manual + `system status`**

**Chosen model:** Users start the daemon explicitly with `container-compose serve`. A new `container-compose system status` subcommand reports daemon liveness so users get a friendly pointer when the daemon is down. A LaunchAgent plist for Homebrew installations is a deferred follow-up (Phase 2.x), not in v1.

**Rationale:**

1. **Fastest unblock for Phase 2.** The HTTP server work (CHAOS-1347) needs a stable lifecycle contract. Manual is the smallest contract — bind socket, handle SIGTERM, unlink — and matches every other long-running CLI in this codebase's mental model (`git daemon`, `redis-server`, `etcd`). Auto-spawn / launchd add hidden lifecycle paths that would need their own tests + docs and slow Phase 2 down.
2. **Best dev iteration during Phase 2.** Phase 2 will involve hundreds of "start daemon, hit endpoint, kill daemon, fix code, restart" cycles. Manual restart is a single keystroke (`Ctrl-C` then up-arrow); `launchctl unload && launchctl load` is not.
3. **Avoids the auto-spawn footguns.** The spike report (`docs/plans/native-api-spike-report.md` §3.5) documents the "no retrospective attach" constraint: when the daemon restarts, log streaming is lost for pre-existing containers. Auto-spawn-from-`up` makes this worse — silent forks on every `up` invocation can leave orphan VMs after a crashed `up`, with no clear owner for cleanup. Manual keeps the user in the loop.
4. **Doesn't preclude launchd later.** Once Phase 2 ships and the API stabilizes, adding a `Resources/com.full-chaos.container-compose.plist` LaunchAgent for Homebrew installs is a small additive PR. Manual users keep working unchanged.
5. **Matches the project's positioning.** `container-compose` is positioned AWAY from Docker. `dockerd` auto-starts via launchd from the Docker Desktop installer; mirroring that UX undermines the "we are not Docker" stance. `git daemon` requires explicit start; that's the right reference.

**Alternatives considered (ticket CHAOS-1349 listed four; condensed rationale):**

- **Auto-spawn from `up`** — rejected: lifecycle ambiguity (who reaps on `down`?), debug pain (daemon stdout vanishes), zombie risk if double-fork is wrong, makes the "no retrospective attach" constraint substantially worse.
- **launchd LaunchAgent only** — deferred (not rejected): native macOS, survives reboot, auto-restart on crash; but slower dev iteration during Phase 2 and `make install` users still need a manual path. Will be added as a follow-up once Phase 2 stabilizes the API.
- **launchd socket activation** — rejected for v1: zero-RAM-when-idle is genuinely nice but the implementation complexity (handling pre-bound socket from `launch_activate_socket()`) and debug difficulty ("daemon died and I can't tell why") aren't worth it before we know the API surface stabilizes. May revisit if profiling shows idle-RAM is a real problem.
- **Hybrid (launchd for brew, manual for source)** — deferred: ~3-4× the implementation cost and dual lifecycle test surfaces, for benefit that's ≤1 follow-up PR away once we ship Manual.

### Decision #2 — HTTP server library: **Hummingbird 2.x**

**Choice:** `hummingbird-project/hummingbird` ≥ 2.0.0 (currently 2.22.0).

**Rationale:**

- Apple-Swift-shop tone (Apache 2.0, swift-nio under the hood, async-first), light dependency footprint, and `Application` natively conforms to `swift-service-lifecycle`'s `Service` protocol — which gives us signal-safe graceful shutdown for free.
- Native `BindAddress.unixDomainSocket(path:)` support — no custom NIO bootstrap wiring required.
- `Router` DSL is Swift 6 strict-concurrency clean (`Sendable` from the start).
- Heavy transitive overlap with the swift-nio stack already pulled in by `apple/containerization` (Phase 1 dep); marginal new dep cost.
- Vapor has a deeper ORM/templates surface we don't need; raw swift-nio costs us hand-rolling HTTP framing, route parsing, and shutdown wiring that Hummingbird gives us free.

### Decision #4 — Unix socket location: **`~/.container-compose/api.sock`**

**Choice:** Per-user XDG-style path under the same directory the Phase 1 registry already uses (`~/.container-compose/registry.json`).

**Rationale:**

- Hermetic to the user — no privilege escalation, no `sudo` for socket cleanup, no collision when multiple users share a host.
- Keeps related state (`registry.json`, `api.sock`, future `*.lock` files) in one directory — easier debugging, easier `rm -rf` reset for support cases.
- `/var/run/container-compose.sock` is the Docker-familiar location but undermines the "AWAY from Docker" positioning and forces sudo for socket cleanup. `/tmp` is too ephemeral.
- Path is overrideable via `--socket` flag on `serve` + `system status` for advanced users.

## Locked decisions (CHAOS-1347 — 2026-05-01)

### Decision #6 — API schema language: Hand-written `Codable` per endpoint

**Choice:** Hand-written Swift `Codable` structs in `Sources/Container-Compose/Server/APISchemas.swift`. No OpenAPI generation in v1.

**Rationale:** 9 endpoints worth of schemas is small enough to keep in one source-of-truth file. OpenAPI generation (apple/swift-openapi-generator) adds a build-step + a YAML/JSON authoring surface for marginal benefit at this scale. The "stay AWAY from Docker" stance argues against borrowing Docker's swagger; hand-written Codable owned by us avoids accidentally inheriting Docker's contract via shared schemas. If the schema count grows past ~25 or external clients need an OpenAPI doc, revisit.

### Decision #7 — Stream encoding: NDJSON over chunked HTTP

**Choice:** All streaming endpoints (`/events`, `/containers/{id}/logs`, `/containers/{id}/stats`) emit newline-delimited JSON over HTTP chunked transfer encoding. Content-Type `application/x-ndjson`. NOT Server-Sent Events.

**Rationale:** Hummingbird 2.x has first-class support for `ResponseBody(asyncSequence:)` which auto-sets `Transfer-Encoding: chunked` when no content-length. NDJSON is curl-friendly (`curl --no-buffer`) and matches Docker's /events + /stats wire format closely enough that ecosystem tooling is familiar. SSE adds `data:` prefix overhead and `\n\n` framing for no benefit on the daemon side. Backpressure is automatic via NIO's channel writability — slow clients pause the upstream AsyncStream naturally.

### Decision #8 — Logs frame format: NDJSON `{stream, timestamp, line}`, not Docker's 8-byte multiplexed header

**Choice:** Each log frame is one JSON object per line: `{"stream":"stdout","timestamp":"2026-05-01T18:30:00Z","line":"hello"}`. Not Docker's 8-byte header (1 byte stream + 3 bytes padding + 4 bytes length + payload).

**Rationale:** Docker's multiplex format is bandwidth-efficient and parseable, but it's notoriously painful for `curl` users and browser-based observability tools. Our positioning is "ecosystem-friendly", not "Docker bandwidth-equivalent". Per the architecture stance, we are NOT a Docker shim — frame format is ours to choose. Cost: ~30 bytes per frame overhead vs Docker's 8. Acceptable for typical log volumes; if a high-throughput consumer needs the Docker shape, that's a v2 add.

### Decision #9 — POST /containers/create shipped in CHAOS-1352 (v2)

**Choice (v1):** `POST /containers/create` was reserved as a documented schema in `APISchemas.swift` but no route handler in v1.

**Choice (v2 — CHAOS-1352, shipped):** The route is now fully wired. `POST /containers/create` accepts `APICreateContainerRequest` (image, name, cpus, memoryBytes, hostname, env, cmd, workingDir, publishedPorts), calls `Runtime.create(id:configuration:)`, and returns 201 with `APICreateContainerResponse{id, warnings}`.

Field scope decisions:
- `labels`, `networks`, `volumes` intentionally omitted from the request body. Labels are not yet on `RuntimeContainer`; networks and volumes are managed separately via the CHAOS-1353 resource CRUD endpoints. Adding these fields without a corresponding runtime surface would be dead wire.
- `publishedPorts` added to `APICreateContainerRequest` and bridged through `RuntimeCreateConfiguration`. Port mappings are part of the minimum viable create surface for real container workflows.

Name resolution: body `name` wins over `?name=` query alias; UUID fallback when neither is present.

Backend notes:
- `AppleContainerizationRuntime.create()` — registry-backed (fully functional in Phase 1 skeleton; Phase 2 wires real VM launch).
- `MockRuntime.create()` — stateful actor implementation; used for all static tests.
- `BridgeContainerClientRuntime.create()` — throws `.notSupported`; documented as Leak #13. The XPC API requires a `Kernel` binary reference not available from `RuntimeCreateConfiguration`; clients using the Bridge should use `compose up` instead.

### Decision #10 — Stats stream backend: 501 Not Implemented in v1, wired in Phase 4 (CHAOS-1358)

**Choice (v1):** `GET /containers/{id}/stats` route ships as a documented endpoint that returns HTTP 501 Not Implemented in v1. The route's polling-loop handler skeleton is in place; only the upstream `Runtime.statistics(for:)` implementations are stubbed.

**Rationale (v1):** Both Runtime conformers stub `statistics()` today (`AppleContainerizationRuntime` returns empty, `BridgeContainerClientRuntime` throws notSupported). Wiring real stats requires either (a) the apple/containerization VM-stats path (Phase 3 territory — vsock per call), or (b) a fork-patch to apple/container's CLI to expose stats — neither is in CHAOS-1347's scope. 501 with a documented `Phase: stats backend` deferral header signals to ecosystem tools that the route exists but isn't ready, vs returning 404 (which suggests the route doesn't exist). Logs and events streams DO ship in PR-B with real Bridge wiring (Tier 2 fork patches CHAOS-1322 + CHAOS-1323 already shipped per AGENTS.md).

**Phase 4 — CHAOS-1358 (shipped 2026-05-01):** The 501 stub is replaced with a real NDJSON polling loop in `StatsRoutes`. Both runtime conformers now wire real data:

- **BridgeContainerClientRuntime:** delegates to `ContainerClient.stats(id:)` via the `ContainerClientProvider.stats(id:)` method added in this PR. `ContainerStats` (from `ContainerResource`) maps directly to `RuntimeStatistics`. Network stats are aggregated into a single `eth0` entry (per-interface breakdown not available via `ContainerStats`); OOM kill count is unavailable. Documented in `docs/plans/runtime-abstraction-leaks.md` as Leak #6.
- **AppleContainerizationRuntime:** returns an empty (but structurally valid) snapshot — all CPU/memory fields are `nil`. Real vsock stats require a live `LinuxContainer` instance held per container, which is not wired until the full Phase 2 lifecycle (`ContainerManager.create` / `LinuxContainer.start`) lands. Documented in `docs/plans/runtime-abstraction-leaks.md` as Leak #7. The route produces valid NDJSON frames rather than a 501 error, with null data fields visible to clients.

**Interval clamping decision:** `?interval=Ns` query parameter clamps values to `[500ms, 60s]` silently rather than returning 400. Out-of-range values from automation clients that hard-code large intervals (e.g. `120s`) would otherwise block the route response. Clamping gives a working result; clients can detect the actual cadence from frame timestamps if needed.

**One-shot mode:** `?stream=false` returns a single JSON object (`Content-Type: application/json`) instead of NDJSON. Useful for scripted spot-checks without streaming.

## Phase 2 lifecycle blueprint

This section is the contract CHAOS-1347 implements against. Every line below is a load-bearing requirement — changing these without updating CHAOS-1349 is a contract break.

### Process model

- Foreground only. `container-compose serve` runs in the user's terminal until SIGTERM/SIGINT. No double-fork, no `setsid`, no stdio detach. Users who want background can use `&`, `nohup`, `tmux`, or wait for the launchd follow-up.
- Single registry, single socket, single process. Idempotence detection (see below) prevents accidental double-bind.
- Process exits 0 on clean shutdown; non-zero only on errors.

### Socket lifecycle

1. **Pre-bind check (idempotence):** Before binding, attempt to connect to the socket path. If the connection succeeds, print `container-compose daemon already running on <path>` and exit 0. (Hits the "second `serve` call detects existing socket" success criterion.)
2. **Stale socket cleanup:** If the path exists on disk but `connect()` refuses (likely a leftover from a crashed daemon), unlink the file before binding. Logged at info level so the user knows we cleaned up.
3. **Bind:** `Hummingbird.Application` with `address: .unixDomainSocket(path: socketPath)`.
4. **Shutdown:** `swift-service-lifecycle` `ServiceGroup` triggers graceful shutdown on SIGTERM/SIGINT. A sibling `SocketCleanupService` `withGracefulShutdownHandler { ... } onGracefulShutdown: { unlink socket; flush registry }` runs the unlink + registry flush AFTER Hummingbird has drained in-flight requests.
5. **Permission:** Socket file mode is the default (umask-controlled, typically 0755). No explicit chmod in v1 (single-user assumption).

### Signal handling

| Signal | Action |
|---|---|
| `SIGTERM` | Graceful shutdown (drain requests → unlink socket → flush registry → exit 0) |
| `SIGINT` | Same as SIGTERM (Ctrl-C in foreground = graceful shutdown) |
| `SIGHUP` | Ignored in v1. (Conventional re-read-config doesn't apply yet — no config to re-read.) |
| `SIGKILL` | Cannot be intercepted; user accepts that socket file may be left behind (next `serve` cleans up via stale-socket detection) |

All handled via `ServiceGroup(configuration: .init(gracefulShutdownSignals: [.sigterm, .sigint], ...))`. We deliberately do NOT install our own `signal()` handlers — service-lifecycle owns this.

### Cross-process lock contention

Phase 1 already serialized `registry.json` writes via `flock(2)` on a sidecar `~/.container-compose/registry.json.lock` file. The daemon's writes go through the same `ContainerRegistry` actor, so the property holds: **concurrent CLI invocations + the running daemon cannot corrupt `registry.json`**. The only new property to verify in Phase 2 is that the daemon DOESN'T add a second lock layer that deadlocks against the existing one.

CHAOS-1349 ships a contention test: spawn N concurrent `container-compose ps` invocations against a running daemon, assert all complete and `registry.json` decodes cleanly afterward.

### `system status` subcommand UX

```
$ container-compose system status
Daemon:    not running
Socket:    /Users/chris/.container-compose/api.sock (no file)
Registry:  /Users/chris/.container-compose/registry.json (3 containers)

To start the daemon: container-compose serve
```

```
$ container-compose system status
Daemon:    running (responded to /_ping in 2ms)
Socket:    /Users/chris/.container-compose/api.sock
Registry:  /Users/chris/.container-compose/registry.json (3 containers)
Server:    container-compose 0.11.0
```

Exit code: 0 if daemon is running, 1 if not running (so shell scripts can `if container-compose system status; then ...; fi`).

### Known cosmetic quirk

After a client connects + disconnects, Hummingbird's underlying NIO channel-teardown emits a non-fatal `[HummingbirdCore] Waiting on child channel: NIOFcntlFailedError()` log entry on macOS. Functional impact is zero — graceful shutdown still completes, the socket file is still unlinked, the registry is preserved. The non-zero exit code that previously surfaced is suppressed via `successTerminationBehavior: .gracefullyShutdownGroup` and `failureTerminationBehavior: .gracefullyShutdownGroup` on the Hummingbird `Service` registration. CHAOS-1347 may revisit this when the route surface grows; for v1 it is documented as a known wart.

### Verification gates

CHAOS-1349 ships:

- Architecture doc rewrite (this section).
- `container-compose serve` subcommand with `/_ping` route returning 200 OK + JSON.
- `container-compose system status` subcommand.
- Socket lifecycle (bind, idempotence, stale-socket cleanup, graceful shutdown).
- Cross-process lock contention test (concurrent CLIs vs daemon).
- README section documenting the manual `serve` ceremony.

CHAOS-1347 (Phase 2) plugs the rest of the routes (`/version`, `/info`, `/containers`, `/containers/{id}`, `/networks`, `/events`, `/containers/{id}/logs`, `/containers/{id}/stats`, `/projects`, `/projects/{name}/services`) into this skeleton.

## Execution sketch

### Phase 0 — feasibility spike — **DONE (2026-04-30)**

Output: `docs/plans/native-api-spike-report.md`. Verdict: viable.

### Phase 1 — runtime abstraction + AppleContainerizationRuntime — **DONE (CHAOS-1346, 2026-05-01)**

Shipped: `protocol Runtime`, `AppleContainerizationRuntime` (gated on `@available(macOS 26.0, *)`), `BridgeContainerClientRuntime` (default conformer), `ContainerRegistry` actor with `flock(2)` cross-process safety, `LogRingBuffer`, end-to-end wiring of `compose ps` through `Runtime.list`.

### Phase 2.0 — daemon lifecycle skeleton — **CHAOS-1349 (this PR)**

Ship the `serve` + `system status` subcommands with the `/_ping` route as a stub, no other routes. Socket lifecycle, signal handling, idempotence, registry-flush-on-shutdown all production-grade. Phase 2 plugs routes INTO this skeleton.

### Phase 2 — Container REST API server — **CHAOS-1347**

Plug routes into the Phase 2.0 skeleton: `/version`, `/info`, `/containers` (list/inspect/create), `/networks`, `/events` (subscribe), `/containers/{id}/logs` (follow), `/containers/{id}/stats` (poll/stream), `/projects`, `/projects/{name}/services`. API version string identifies as `container-compose v0.X.Y` — never mimics Docker.

#### Phase 2.A — read-only routes + foundation (this PR)

- Schemas: `Sources/Container-Compose/Server/APISchemas.swift` — all 9 endpoint families, hand-written Codable.
- Runtime extensions: `Runtime.version()`, `Runtime.listNetworks()`, `RuntimeListFilters.status` + `.namePrefix` fields.
- Routes: `/version`, `/info`, `/containers`, `/containers/{id}`, `/networks`, `/projects`, `/projects/{name}/services`. All read-only, all backed by Bridge or Apple runtime as configured.
- 501 stubs for the stream routes (`/events`, `/logs`, `/stats`) — endpoint exists, returns documented 501 Not Implemented.

#### Phase 2.B — streaming routes — **SHIPPED (CHAOS-1350, this PR)**

- `/events`: ships NDJSON streaming and `BridgeContainerClientRuntime.events()` wiring through `ContainerClientProvider.events()` / CHAOS-1323. The bridge polls the provider's buffered event snapshot at the established 1s cadence and emits only newly observed events.
- `/containers/{id}/logs`: ships NDJSON streaming and `BridgeContainerClientRuntime.logs()` wiring through `ContainerClientProvider.logs(id:options:)` / CHAOS-1322, including route-level `follow`, `tail`, `since`, and `timestamps` query parsing.
- `/containers/{id}/stats`: reserves the path with an explicit 501 + `X-ContainerCompose-Deferral: stats-backend`; backend remains deferred until Phase 3 wires `Runtime.statistics(for:)` to the real apple/containerization VM-stats vsock path.

### Phase 2.x — launchd LaunchAgent — **SHIPPED (CHAOS-1355)**

`Resources/com.full-chaos.container-compose.plist` is now included in the repo
and copied into the Homebrew formula's `Resources` prefix at install time.

Key choices:
- **`HOMEBREW_HOME_PLACEHOLDER`** substitution: launchd does not expand `~` in
  plist values, so the formula's `def install` block replaces the placeholder
  string with `ENV["HOME"]` before writing the final plist.
- **`HOMEBREW_PREFIX_PLACEHOLDER`** in `ProgramArguments`: replaced with
  `HOMEBREW_PREFIX` so the binary path resolves correctly regardless of where
  Homebrew is installed (e.g., `/opt/homebrew` on Apple Silicon,
  `/usr/local` on Intel).
- **`--launchd` flag** added to `serve`'s `ProgramArguments`: enables
  ISO-8601 timestamped, structured log lines in the log file — easier to
  correlate with system logs. Flag is a no-op when not set (backward-compatible).
- **`RunAtLoad: true`, `KeepAlive: true`**: daemon starts at login and is
  restarted by launchd if it exits unexpectedly.
- **Log paths**: `~/Library/Logs/container-compose/serve.log` and `serve.err`
  (standard macOS per-user log location; created automatically by launchd).

Homebrew formula update needed (see PR body for the exact `def install` block).
The tap update is a separate PR against `full-chaos/homebrew-tap`.

### Phase 3 — runtime portability proof — **CHAOS-1348**

Shipped in-memory `MockRuntime` as a second `Runtime` conformer for static tests. Unlike `RecordingRuntime` (call recorder only), `MockRuntime` maintains container state, emits lifecycle events, replays/follows log frames, and returns synthetic statistics. This validates the boundary against a non-apple/container backend and lets route/protocol tests prove behavior without requiring a virtualization entitlement.

Deferred: the static test target still contains quarantined backend smoke tests for `AppleContainerizationRuntime` while the native skeleton is landing. The leak inventory and follow-up disposition live in `docs/plans/runtime-abstraction-leaks.md`.

### Phase 5 — SHIPPED (CHAOS-1354)

Container lifecycle write endpoints — five new routes plus the optional `wait` nice-to-have:

- `POST /containers/{id}/start` — calls `Runtime.start(id:)`. Returns 204 on success, 404 not-found, 409 invalid-state.
- `POST /containers/{id}/stop` — calls `Runtime.stop(id:options:)`. Optional JSON body `{signal,timeoutSeconds}` with defaults from `RuntimeStopOptions.default`.
- `POST /containers/{id}/restart` — composite stop + start. Stop ignores `invalidState` so a stopped container restarts cleanly; returns 204 once running.
- `POST /containers/{id}/kill` — calls `Runtime.kill(id:signal:)`. Optional JSON body `{signal}`, default 9 (SIGKILL).
- `DELETE /containers/{id}` — calls `Runtime.remove(id:force:)`. Query param `?force=true|false` (default false).
- `POST /containers/{id}/wait` — calls `Runtime.wait(id:timeoutSeconds:)`. Returns `{exitCode,exitedAt}` on success, 408 on timeout.

**Bridge runtime expansion:** `BridgeContainerClientRuntime.start()` and `.kill()` are now real implementations (no longer `notSupported`). `start` delegates to `ContainerClientProvider.start(id:)` which calls `ContainerClient.bootstrap(id:stdio:[nil,nil,nil]) + process.start()`. `kill` delegates to `ContainerClientProvider.kill(id:signal:)` which calls `ContainerClient.kill(id:signal:)` directly.

**ContainerClientProvider expansion:** `start(id:)` and `kill(id:signal:)` added to the protocol + `ProductionContainerClientProvider` + `RecordingContainerClientProvider` (no-op stubs).

**409 detection:** routes catch `RuntimeError.invalidState(id:expected:actual:)` and map it to HTTP 409 Conflict with a descriptive message — no HTTP-layer state inspection needed.

**Schemas added to `APISchemas.swift`:** `APIStopRequest`, `APIKillRequest`, `APIWaitResponse` (under `// MARK: - Lifecycle Schemas (CHAOS-1354)`).

**Tests:** `LifecycleRoutesTests.swift` in `Container-Compose-StaticTests`, all using `MockRuntime` as the state machine — happy paths + 404 + 409 for every route.

## Implications for the existing CHAOS-1340 family

| Ticket | Disposition |
|---|---|
| CHAOS-1340 (epic) | In Progress — reframed 2026-04-30 |
| CHAOS-1341 (read-only MVP) | Closed (canceled) — no separate Docker-shaped surface to MVP |
| CHAOS-1342 (streaming) | Closed (canceled) — streaming endpoints fold into Phase 2 |
| CHAOS-1343 (upstream advocacy) | Closed (done) — issue filed, response received, no further action |
| CHAOS-1345 (architecture PRD) | Updated with the "stay AWAY from Docker" stance |
| CHAOS-1346 (Phase 1: runtime abstraction) | Done — PR #54 merged 2026-05-01 |
| CHAOS-1347 (Phase 2: REST server skeleton) | Done — Phase 2.A read-only routes shipped in PR #56; Phase 2.B streaming routes shipped in CHAOS-1350 |
| CHAOS-1348 (Phase 3: MockRuntime) | Done — `MockRuntime` portability proof shipped; abstraction leaks documented |
| CHAOS-1349 (this lock-in) | This PR |
| CHAOS-1350 (Phase 2.B: streaming routes) | Done — NDJSON events/logs shipped; stats route reserved with Phase 3 deferral |

## Open questions

All Phase 0 + Phase 1 open questions are now resolved. Remaining items are deferred to the appropriate follow-up phase:

1. ~~**API schema language.**~~ RESOLVED: Hand-written `Codable` types (Decision #6).
2. ~~**Stats polling cadence.**~~ RESOLVED: Locked at 1s default per Decision #7's research; Phase 3 to revisit at scale.
3. **TCP transport opt-in flag spec.** Decision #1 reserved this; the actual flag (`--listen tcp://...`?) and TLS story is **deferred to a future ticket** (probably v2).
4. ~~**launchd LaunchAgent shipping.**~~ RESOLVED: Phase 2.x (CHAOS-1355) shipped `Resources/com.full-chaos.container-compose.plist` + `--launchd` flag. Homebrew tap update needed separately.

## What this is NOT

- **Not a Docker daemon replacement.** We do not aspire to be `dockerd`-compatible.
- **Not a Docker REST adapter or shim.** There is one API surface — ours.
- **Not Socktainer.** Socktainer's design centers Docker UX. This server centers container-compose UX.
- **Not a fork of apple/container.** We bypass apple/container entirely; no fork patches against its CLI/daemon layer remain in scope. (`full-chaos/container` may still hold patches consumed during transition, but the long-term direction is no fork dependency.)
- **Not a multi-tenant API.** Single-user, single-machine. No auth model needed at v1.
- **Not auto-starting.** The daemon starts only when the user explicitly runs `container-compose serve`. See Decision #5.

### Phase 8 — SHIPPED (CHAOS-1353)

Network/volume/secret CRUD endpoints. Shipped 2026-05-01.

**Routes added:**
- `POST /networks` — create a network; body `{name, driver?, subnet?, gateway?, labels?}` → 201 `{id, name}`
- `DELETE /networks/{id}` — remove by id → 204
- `GET /volumes` — list volumes → 200 `{volumes: [...]}`
- `POST /volumes` — create; body `{name, driver?, labels?}` → 201 `{name, driver, labels, createdAt}`
- `DELETE /volumes/{name}` — remove by name → 204
- `GET /secrets` — list secret metadata (no values) → 200 `[{name, labels, createdAt}]`
- `POST /secrets` — create; body `{name, value, labels?}` → 201 `{name}` (value never echoed)
- `DELETE /secrets/{name}` — remove by name → 204

**Runtime protocol extensions added:** `createNetwork(spec:)`, `removeNetwork(id:)`, `listVolumes()`, `createVolume(spec:)`, `removeVolume(name:)`, `listSecrets()`, `createSecret(spec:)`, `removeSecret(name:)`.

**Runtime conformer status:**
- `MockRuntime` — full in-memory implementation for testing
- `RecordingRuntime` — call recording + stubbed responses
- `BridgeContainerClientRuntime` — all 8 methods throw `.notSupported` (no XPC surface for these operations; Leaks #9, #10, #11)
- `AppleContainerizationRuntime` — all 8 methods throw `.notSupported` (no `apple/containerization` API for networks/volumes/secrets; Leaks #9, #10, #11)

**Secret body shape decision:** `POST /secrets` accepts `{name, value}` where `value` is an inline UTF-8 string. Clients reading a `secret.file:` Compose entry must read the file themselves; the daemon does not accept `filePath`. This matches Docker's contract without importing Docker's wire format.

**New types added to RuntimeTypes.swift:** `RuntimeVolume`, `RuntimeCreateVolumeSpec`, `RuntimeSecret`, `RuntimeCreateSecretSpec`, `RuntimeCreateNetworkSpec`.

**New files:**
- `Sources/Container-Compose/Server/Routes/VolumeRoutes.swift`
- `Sources/Container-Compose/Server/Routes/SecretRoutes.swift`
- `Tests/.../NetworkWriteRoutesTests.swift`
- `Tests/.../VolumeRoutesTests.swift`
- `Tests/.../SecretRoutesTests.swift`

### Phase 7 — SHIPPED (CHAOS-1360)

Compose-aware project lifecycle endpoints. Shipped 2026-05-01.

**Routes added:**
- `POST /projects/{name}/up` — start all containers in a project → 200 `{project, services: [{service, containerId, status}]}`
- `POST /projects/{name}/down` — stop and remove all project containers → 200 `{project, stopped: [...], removed: [...]}`
- `POST /projects/{name}/restart` — restart project containers (optional `services` filter) → 200 `{project, restarted: [...]}`
- `POST /projects/{name}/build` — NDJSON build progress stream → 200 `application/x-ndjson` frames `{service, line, timestamp, type}`
- `POST /projects/{name}/pull` — NDJSON pull progress stream → 200 `application/x-ndjson` frames `{service, image, timestamp, type, message?}`
- `POST /projects/{name}/services/{service}/scale` — set replica count → 200 `{project, service, replicas, containers: [...]}`

**Architecture decisions locked by CHAOS-1360:**

#### Decision #11 — Sync vs Async for project lifecycle endpoints

**Chosen:** Synchronous 200 OK for all six routes. `up`, `down`, `restart`, `scale` return once the runtime operations complete. `build` and `pull` use NDJSON streaming (the progress stream is the response body — no task ID needed).

**Rationale:** The ticket requirement "if you choose async, you must implement task tracking (polling endpoint)" made the async path significantly more complex. Synchronous avoids the `GET /tasks/{id}` dance. The NDJSON streaming model (already established by Decision #7 for logs/stats) handles the long-running-output concern for `build` and `pull` without fire-and-forget. `up` in the daemon context operates on the registry (no real image pull/build), so it's fast by design.

#### Decision #12 — Compose-file source for project lifecycle endpoints

**Chosen:** Registry model (pre-loaded). The API operates on containers already registered in the daemon's runtime (identified by `<project>-<service>` naming convention). No Compose YAML is parsed or uploaded in the request body.

**Rationale:** Compose YAML upload via API is explicitly out-of-scope per the CHAOS-1360 ticket boundary (separate ticket). The existing `GET /projects` model (synthesized from container-name prefix) provides a consistent, already-implemented foundation. Real project registries (which map project names to Compose file paths) are a natural Phase 9+ follow-up.

#### Decision #13 — Orchestration layer for project lifecycle (Option B: ProjectOrchestrator)

**Chosen:** Option B — a `ProjectOrchestrator` struct in `Sources/Container-Compose/Server/ProjectOrchestrator.swift`. Route handlers in `ProjectLifecycleRoutes` call `ProjectOrchestrator` static methods, which internally call `Runtime` protocol methods (`list`, `create`, `start`, `stop`, `remove`).

**Rationale over Option A (extend Runtime protocol):** The `Runtime` protocol would have grown substantially with project-lifecycle methods (`up`, `down`, `restart`, `scale`, `build`, `pull`), and every conformer (`MockRuntime`, `RecordingRuntime`, `BridgeContainerClientRuntime`, `AppleContainerizationRuntime`) would need stub implementations. The orchestration logic is too complex for protocol stubs.

**Rationale over Option C (call CLI commands directly):** Option C would bypass the `Runtime` abstraction layer — undoing CHAOS-1346's architecture. Routes calling `ComposeUp.run()` directly would create a tight coupling between the HTTP API and the CLI internals.

**Implementation notes:**
- `ProjectOrchestrator` is a pure `Sendable` struct (no mutable state; all state in actor-isolated `Runtime`).
- `up`: creates missing containers, starts `.created` ones, reports `.stopped`/`.running` ones as-is.
- `down`: stops running containers, removes all. Uses `force: true` on `remove` to handle edge cases.
- `restart`: stop (tolerates invalidState) then start each matched container.
- `scale`: creates new replica containers (`<service>-N` suffix) or removes excess ones.
- `build`/`pull`: emit synthetic NDJSON frames explaining that real build/pull requires the CLI runner seam. A future ticket can extend `Runtime` with `build(service:options:)` / `pull(service:options:)` and wire it through.

**Abstraction leak #14:** `ProjectOrchestrator.build/pull` emit "not supported via daemon API" frames rather than actual build/pull output, because `Runtime` has no `build(image:options:)` or `pull(image:options:)` protocol method. Real implementation requires either (a) adding those methods to the `Runtime` protocol with conformers delegating to the `RunCommandRunner` seam, or (b) a new orchestration surface for CLI-backed operations. Deferred to a future ticket.

**New files:**
- `Sources/Container-Compose/Server/ProjectOrchestrator.swift`
- `Sources/Container-Compose/Server/Routes/ProjectLifecycleRoutes.swift`
- `Tests/.../ProjectLifecycleRoutesTests.swift`

**New types in APISchemas.swift:** `APIProjectUpRequest`, `APIProjectServiceState`, `APIProjectUpResponse`, `APIProjectDownRequest`, `APIProjectDownResponse`, `APIProjectRestartRequest`, `APIProjectRestartResponse`, `APIProjectBuildRequest`, `APIProjectBuildFrame`, `APIProjectPullRequest`, `APIProjectPullFrame`, `APIProjectScaleRequest`, `APIProjectScaleResponse`.

### Phase 11 — SHIPPED (CHAOS-1357)

API hardening: unified error envelope, Prometheus metrics, OpenAPI spec. Shipped 2026-05-01.

**Three components shipped:**

1. **`APIErrorEnvelope` migration** — Added `APIErrorEnvelope { error, message, code, requestId }` as the canonical error response shape. `APIErrorEnvelope.legacy()` builder maps HTTP status codes to string error keys (`not_found`, `conflict`, `not_supported`, `invalid_state`, `internal_error`). Migrated 33+ call sites across 10 route files. `APIErrorResponse` and `APIStatsErrorResponse` deprecated with `@available(*, deprecated)`.

2. **Middleware pair** — `RequestIDHeaderMiddleware` stamps `X-Request-Id` on every response using `context.id.description`. `ErrorMappingMiddleware` catches `RuntimeError` thrown by route handlers and converts to `APIErrorEnvelope` (404 / 409 / 501 / 500 as appropriate) so routes don't need per-error catch blocks for uncaught runtime errors.

3. **`GET /metrics`** — `MetricsRoutes` refreshes three custom Prometheus gauges (`container_compose_uptime_seconds`, `container_compose_memory_rss_bytes`, `container_compose_registry_containers`) and emits the full `PrometheusCollectorRegistry` in `text/plain; version=0.0.4` format. Uses Hummingbird's built-in `MetricsMiddleware` for per-route request counters/histograms. RSS via Darwin `task_info(MACH_TASK_BASIC_INFO)` in `ProcessRSS.swift`.

4. **`GET /openapi.yaml`** — `OpenAPIRoute` serves a hand-written OpenAPI 3.1 spec from `Bundle.module` (SwiftPM resource) covering all 25 daemon routes.

**New files:**
- `Sources/Container-Compose/Server/RequestIDHeaderMiddleware.swift`
- `Sources/Container-Compose/Server/ErrorMappingMiddleware.swift`
- `Sources/Container-Compose/Server/ProcessRSS.swift`
- `Sources/Container-Compose/Server/Routes/MetricsRoutes.swift`
- `Sources/Container-Compose/Server/Routes/OpenAPIRoute.swift`
- `Resources/openapi.yaml`
- `Tests/.../ErrorEnvelopeTests.swift` (16 tests)
- `Tests/.../MetricsRoutesTests.swift` (8 tests)
- `Tests/.../OpenAPIRouteTests.swift` (6 tests)

**Architecture decisions locked by CHAOS-1357:**

#### Decision #17 — Error shape: envelope vs per-route custom types

**Chosen:** Single `APIErrorEnvelope` with `error` (machine key), `message` (human text), `code` (E_NNN default or custom), `requestId` (per-request UUID for log correlation).

**Rationale:** Callers need a stable key to branch on (`error == "not_found"`). `message` is free-text for humans. `code` enables future fine-grained error codes without changing the `error` key. `requestId` ties client errors back to server logs.

#### Decision #18 — Prometheus bootstrap: singleton per process

**Chosen:** `MetricsSystem.bootstrap(PrometheusMetricsFactory())` called once in `ComposeServe.run()` before `Application` construction. In tests, a file-scope lazy flag (`nonisolated(unsafe) var _metricsBootstrapped`) ensures bootstrap fires at most once even when Swift Testing creates fresh struct instances per test.

**Rationale:** `MetricsSystem.bootstrap()` is a global one-time call that crashes on double invocation. The lazy-flag pattern is the standard workaround in swift-metrics tests without requiring `@_spi(Testing)` bootstrap-internal access.

## References

- CHAOS-1340 (epic): https://linear.app/fullchaos/issue/CHAOS-1340
- CHAOS-1345 (architecture PRD): https://linear.app/fullchaos/issue/CHAOS-1345
- CHAOS-1346 (Phase 1, shipped): https://linear.app/fullchaos/issue/CHAOS-1346
- CHAOS-1347 (Phase 2, blocked-on-this): https://linear.app/fullchaos/issue/CHAOS-1347
- CHAOS-1348 (Phase 3, future): https://linear.app/fullchaos/issue/CHAOS-1348
- CHAOS-1349 (this PR): https://linear.app/fullchaos/issue/CHAOS-1349
- CHAOS-1350 (Phase 2.B, shipped): https://linear.app/fullchaos/issue/CHAOS-1350
- apple/container#1476 (closed; rejection rationale informs the "no upstream advocacy" rule): https://github.com/apple/container/issues/1476
- Socktainer's design we're explicitly diverging from: https://github.com/socktainer/socktainer
- apple/containerization (the direct backend target): https://github.com/apple/containerization
- Hummingbird (HTTP server, locked in Decision #2): https://github.com/hummingbird-project/hummingbird
- swift-service-lifecycle (signal handling): https://github.com/swift-server/swift-service-lifecycle
- Phase 0 spike report: `docs/plans/native-api-spike-report.md`
- Prior planning doc this supersedes: `docs/plans/socktainer-pivot-summary.md`

## Locked decisions (CHAOS-1359 — 2026-05-01)

### Decision #14 — TCP/TLS transport flag spec

**Chosen form:** `--listen <url>` with `unix://`, `tcp://`, `tls://` schemes. Plain TCP on a non-localhost address requires `--insecure` (explicit acknowledgment that traffic is unencrypted). Single listener only (multi-bind deferred). URL-shape mirrors Docker, Podman, Kubernetes patterns so the flag is immediately intuitive to operators familiar with those tools.

**Full spec:**

- Default: `unix:///<homedir>/.container-compose/api.sock` (same as the deprecated `--socket` default).
- `unix:///path` — Unix domain socket (any absolute or tilde-expanded path).
- `tcp://host:port` — plain TCP. Localhost (`localhost`, `127.0.0.1`, `::1`) allowed without `--insecure`. Non-localhost requires `--insecure`; a warning is emitted on every startup in that mode.
- `tls://host:port` — TLS-wrapped TCP. Requires `--cert` + `--key` (or auto-detected from `~/.container-compose/cert.pem` + `key.pem` generated by `system generate-cert`).
- `--socket <path>` is retained as a deprecated back-compat synonym for `unix:///path`. Mutual exclusion: `--socket` and `--listen` cannot both be set.

**Certificate generation:** `container-compose system generate-cert` generates a self-signed P-256 cert via swift-certificates + swift-crypto, writing `cert.pem` (mode 0644) + `key.pem` (mode 0600) to `~/.container-compose/` (or a custom `--out-dir`). Includes BasicConstraints, KeyUsage(digitalSignature+keyEncipherment), ExtendedKeyUsage(serverAuth), and SAN (localhost + 127.0.0.1 + ::1 by default).

**Client-side TCP/TLS:** `system status --address <url> --cacert <path>` probes TCP/TLS daemons via AsyncHTTPClient. Auto-trust policy: explicit `--cacert` wins; otherwise auto-trusts `~/.container-compose/cert.pem` on localhost targets; falls back to system roots.

**Idempotence:** `isAlreadyServing(listenAddress:)` dispatches to the existing UnixSocketProbe for `.unix` and a new TCPProbe (SO_SNDTIMEO, 1s timeout, no TLS handshake) for `.tcp`/`.tls`.

**Out of scope (deliberately deferred):**
- Auth (CHAOS-1356, a separate PR that depends on this one for TLS plumbing)
- Multi-bind listener (deferred to v1.2 — operational complexity vs. value unclear at v1)
- ACME / Let's Encrypt (explicit non-goal for v1; self-signed covers the primary local use case)
- Mutual TLS / client certificate auth (plumbed as `clientCAPath: nil` placeholder in TLSBootstrap.makeServerConfig — PR-3 wires this)

**PR-2 / PR-3 coordination:** `ServeDaemon.run(listen:certPath:keyPath:launchdManaged:)` reserves two MARK-section placeholders in the correct positions: `// MARK: - Middleware (CHAOS-1357)` (owned by PR-2) and `// MARK: - Auth (CHAOS-1356)` (owned by PR-3). These are pre-allocated so parallel merge of PR-2 and this PR doesn't produce edit conflicts in the server build block.
