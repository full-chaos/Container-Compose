# Native API Server for container-compose

> **Status:** decisions locked 2026-04-30 (Phase 0 priors). Five additional
> decisions locked 2026-05-01 by CHAOS-1349 (daemon lifecycle, HTTP library,
> socket location). Phase 1 (CHAOS-1346) shipped 2026-05-01.
> **Date:** 2026-04-30 (initial), 2026-05-01 (CHAOS-1349 lock-in)
> **Supersedes:** the Docker-API-bridge framing in `docs/plans/socktainer-pivot-summary.md`. That document recommended adopting Socktainer; this one proposes building a native server inside container-compose instead.
> **Related Linear:** CHAOS-1340 (epic), CHAOS-1345 (architecture PRD), CHAOS-1346 (Phase 1 — shipped), CHAOS-1347 (Phase 2 — HTTP server skeleton), CHAOS-1348 (Phase 3 — MockRuntime), CHAOS-1349 (this lock-in PR).
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

### Decision #9 — POST /containers/create deferred to v2

**Choice:** `POST /containers/create` ships as a documented schema in `APISchemas.swift` but no route handler in v1.

**Rationale:** Container creation is orchestrated through `compose up` (which translates the Compose model into runtime calls). Direct `POST /create` requires expanding `RuntimeCreateConfiguration` to cover labels, networks, healthchecks, volumes — substantial scope creep. Ecosystem tools that want to drive container creation can call `compose up` via shell-out today; a first-class `/create` route is a v2 concern when use cases concretize. Schema is reserved so v2 doesn't have to revisit the wire shape.

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
