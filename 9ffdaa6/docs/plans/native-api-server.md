# Native API Server for container-compose

> **Status:** decisions locked 2026-04-30 (priors accepted as-is). Phase 0 feasibility spike kicked off — see "Execution sketch" below.
> **Date:** 2026-04-30
> **Supersedes:** the Docker-API-bridge framing in `docs/plans/socktainer-pivot-summary.md`. That document recommended adopting Socktainer; this one proposes building a native server inside container-compose instead.
> **Related Linear:** CHAOS-1340 (epic — needs reframing), CHAOS-1345 (architecture PRD — partially incorporated below), CHAOS-1341/1342/1343 (likely close or recast).
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
├── Container REST API server                                 ← new component
│     - One surface, ours
│     - Container-domain endpoints (containers, networks, events, logs)
│     - Compose-aware where the domain demands it (services, projects)
└── Runtime abstraction protocol                              ← new boundary
    └── AppleContainerizationRuntime (only conformer at v1)
        └── apple/containerization Swift package (direct calls)
```

The boundary above the runtime protocol is what gives us portability later. The single-API design is what stops Docker semantics from sneaking in via "we'll just add one more shim endpoint."

## Four decisions (locked 2026-04-30)

| # | Decision | My weak prior | Alternatives | Why this decision matters |
|---|---|---|---|---|
| 1 | API transport | **HTTP-over-Unix-socket** as primary; HTTP-over-TCP opt-in via flag | gRPC; raw TCP; HTTP/2 only | Unix socket is the lowest-friction integration for native consumers in the same compose stack. TCP opt-in handles cross-host or container-internal use. gRPC has stricter contracts but loses ecosystem reach. |
| 2 | Daemon model | **Long-running `container-compose serve`** (option b) | Per-`up` lifecycle (a); leader-elect-from-CLI (c) | Long-running daemon survives across compose-up/down cycles and gives ecosystem tools a stable endpoint. Per-project (a) is hermetic but breaks cross-project tooling. Leader-elect (c) is clever but a debugging nightmare. |
| 3 | API shape | **Container-domain endpoints first, with Compose-aware extensions where the domain demands it** (services, projects, deps surface as their own resources) | Pure container primitives with project labels; pure Compose primitives | Container-domain endpoints give ecosystem tools a recognizable shape; Compose extensions reflect our actual abstractions where containers-alone are insufficient. Pure-container (Socktainer's path) leaks Docker's mental model; pure-Compose makes integration unnecessarily different from familiar shapes. |
| 4 | Backend abstraction | **Define `protocol Runtime` boundary at v1**, even with one conformer | Monolithic v1, retrofit later | Cheap now (one indirection layer + minimal API surface). Expensive later (every call site must change). Designing for portability is the freedom you asked for. |

## Execution sketch

### Phase 0 — feasibility spike (1–2 days)

- Stand up a minimal Swift project that imports `apple/containerization` directly
- Verify we can: list containers, inspect, start, stop, follow logs, subscribe to events
- Document any gap in the apple/containerization public API that blocks us
- Output: a yes/no on "is direct-from-containerization viable for our needs?"

### Phase 1 — runtime abstraction + apple/containerization integration

- Define `protocol Runtime` (decision #4)
- Implement `AppleContainerizationRuntime` against the spike findings
- Wire container-compose CLI to use the runtime protocol instead of shelling to `container`
- Validate against the existing coverage matrix (no regressions)

### Phase 2 — Container REST API server

- Choose Swift HTTP server library (probably swift-nio + Hummingbird; see Open Questions)
- Implement `container-compose serve` daemon with the API endpoints (decision #3)
- Unix socket transport (decision #1)
- API version string explicitly identifies as `container-compose`, not Docker — discourages tooling that fingerprints `/version` from drawing wrong conclusions

### Phase 3 — runtime portability proof (when motivated)

- Implement a second `Runtime` conformer (containerd? a stub `MockRuntime` for tests?) to validate the abstraction holds
- This phase exists to verify the boundary, not because we need a second backend immediately

## Implications for the existing CHAOS-1340 family

| Ticket | New disposition |
|---|---|
| CHAOS-1340 (epic) | Reframe as "Container REST API server for container-compose ecosystem" |
| CHAOS-1341 (read-only MVP) | Close as obsolete — there is no separate Docker-shaped surface to MVP |
| CHAOS-1342 (streaming) | Close as obsolete — streaming endpoints (logs follow, events) become part of the native API in Phase 2, not a separate Docker-streaming workstream |
| CHAOS-1343 (upstream advocacy) | Close complete; "no upstream advocacy" is now a project rule |
| CHAOS-1345 (architecture PRD) | Update with the "stay AWAY from Docker" stance, the direct-from-containerization architectural shift, and the dropping of any Docker-adapter framing |
| New ticket | Phase 0 spike: direct-from-containerization feasibility |
| New ticket | Phase 1: runtime abstraction + apple/containerization integration |
| New ticket | Phase 2: Container REST API server skeleton |

## Open questions

1. **apple/containerization library readiness.** We don't yet know what's in the public API surface — Phase 0 spike answers this. If critical primitives are missing (e.g. event subscription, log following), we work around them in container-compose's userland.
2. **HTTP server library.** Hummingbird vs swift-nio raw vs Vapor. Probably Hummingbird (Apple-Swift-shop tone, light dep, async-first) but worth a 30-minute survey before committing.
3. **API schema language.** Hand-written `Codable` types? OpenAPI-generated from our own spec? The "stay away from Docker" stance argues against borrowing Docker's swagger; argues for hand-rolling or owning a small spec.
4. **Unix socket location.** `$HOME/.container-compose/api.sock`? `/var/run/container-compose.sock`? First is hermetic; second matches `/var/run/docker.sock` familiarity — but the second undermines the "AWAY from Docker" positioning.
5. **Process model when run as part of `container-compose up` (no separate `serve`).** Should `up` auto-spawn the daemon if not running, or refuse and require explicit `serve`? Auto-spawn is convenient; refuse is explicit.

## What this is NOT

- **Not a Docker daemon replacement.** We do not aspire to be `dockerd`-compatible.
- **Not a Docker REST adapter or shim.** There is one API surface — ours.
- **Not Socktainer.** Socktainer's design centers Docker UX. This server centers container-compose UX.
- **Not a fork of apple/container.** We bypass apple/container entirely; no fork patches against its CLI/daemon layer remain in scope. (`full-chaos/container` may still hold patches consumed during transition, but the long-term direction is no fork dependency.)
- **Not a multi-tenant API.** Single-user, single-machine. No auth model needed at v1.

## References

- CHAOS-1345 (architecture PRD): https://linear.app/fullchaos/issue/CHAOS-1345
- CHAOS-1340 (epic): https://linear.app/fullchaos/issue/CHAOS-1340
- apple/container#1476 (closed; rejection rationale informs the "no upstream advocacy" rule): https://github.com/apple/container/issues/1476
- Socktainer's design we're explicitly diverging from: https://github.com/socktainer/socktainer
- apple/containerization (the direct backend target): https://github.com/apple/containerization
- Prior planning doc this supersedes: `docs/plans/socktainer-pivot-summary.md`
