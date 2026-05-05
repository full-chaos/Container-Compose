# Socktainer pivot — CHAOS-1340 Docker API compatibility

> **Date:** 2026-04-30
> **Trigger:** apple/container#1476 closed by maintainer (jglogan), redirected to https://github.com/socktainer/socktainer
> **Tracking:** Linear CHAOS-1340 epic (CHAOS-1341, CHAOS-1342, CHAOS-1343)
> **Status:** Pre-pivot; Linear/branch updates pending user direction (A/B/C below)

## Maintainer rationale (apple/container#1476 closing comment)

> A full dockerd to container API bridge (while it would be incredibly useful to have for the reasons you mention) isn't in the scope of this GitHub project at present. Even if we could wave a wand and make it appear, it would make more sense to maintain it as a separate service plugin project. It's just that big and that different from the core container tool.
>
> Also, there is such an effort that's been underway for a while: https://github.com/socktainer/socktainer

Translation: scope rejection, not idea rejection. The maintainer agreed the surface is useful, agreed the right shape is "separate plugin project" — exactly the design we'd been debating — and pointed at a community project that's been doing this since July 2025.

## Socktainer reality

| | |
|---|---|
| **Status** | 211 stars, v0.12.0 released 2026-04-28, pushed 2026-04-28 |
| **Architecture** | CLI/daemon, Unix socket at `$HOME/.socktainer/container.sock`, clients use `DOCKER_HOST=unix://...` |
| **Compat target** | Docker Engine API v1.51 (matches moby v28.5.2 swagger) |
| **Stack** | 95% Swift, Apache-2.0, built on Apple's Containerization framework |
| **Already adopted by** | Podman Desktop's Apple Container extension (`benoitf/extension-apple-container`) |
| **Endpoint coverage** | Read-only MVP (CHAOS-1341 scope) appears done; **`/containers/{id}/stats` route exists but handler is literally `NotImplemented.respond(...)`** in `Sources/socktainer/Routes/Containers/ContainerStatsRoute.swift` — i.e. CHAOS-1342's stats stream is a stubbed-out contribution opportunity sitting in the canonical repo |

## Key insights

- **The `NotImplemented` stats handler is a gift.** Socktainer has already wired the route registration in `Sources/socktainer/Routes/Containers/ContainerStatsRoute.swift` and `configure.swift`; the open work is the body of `static func handler(_ req: Request) async throws -> Response`. That's a focused 5–10 line meaningful contribution: data-source choice (poll vs subscribe), cadence (Docker spec says ~1s), schema fidelity (full Docker stats vs minimal), and backpressure on client disconnect.
- **The maintainer pointing us at Socktainer, not just declining, is the strongest possible signal.** It says (a) Apple knows Socktainer exists, (b) Apple is comfortable with it being the de facto plugin path, and (c) effort spent on Socktainer compounds across the ecosystem (Podman Desktop already benefits) rather than only us. ~10x leverage shift over a fork-only XPC helper.
- **The "container compose" parallel is consistent.** jglogan referenced "as with `container compose`" — meaning compose itself was scoped out of core and lives as a separate project (this repo, `full-chaos/container-compose`). The architectural rule is now load-bearing with evidence: anything that turns `container` into a Docker-equivalent lives as a community plugin, not core.

## Recommended pivot

**Adopt Socktainer immediately for dev-health/signoz/alloy. Contribute the streaming endpoints (CHAOS-1342 work) upstream to socktainer/socktainer.** The CHAOS-1341 read-only surface is likely already covered — validate that with a 30-minute smoke test before committing to broader contributions.

## What this collapses

| Old | New |
|---|---|
| **CHAOS-1341 (MVP)** — build endpoints in `full-chaos/container` XPC helper | Validate Socktainer covers our consumer needs; close as "delivered upstream by Socktainer" if confirmed |
| **CHAOS-1342 (streaming)** — build streaming endpoints in fork | Reframe as "Contribute `/containers/{id}/stats?stream=true` and `/containers/{id}/logs?follow=true` to socktainer/socktainer" |
| **CHAOS-1343 (upstream advocacy)** — track apple/container engagement | Mark complete: rejected with redirect, redirect was actionable |
| **CHAOS-1340 epic framing** — "build Docker API in fork" | "Adopt Socktainer + contribute gaps" |
| **Branch `feat/xpc-api-docker-draft`** in container fork | Delete — wrong repo for the new plan |
| **Four architectural decisions** (launch model, framework, schema, naming) | Mostly moot — Socktainer already chose: daemon, looks like Vapor (route DSL `try routes.registerVersionedRoute(.GET, pattern: ...)`), hand-written Codable, `Sources/socktainer/Routes/...` |

## Decisions for next session

These shape the next concrete steps; pick before touching Linear or the branch.

1. **Adoption strategy** (A / B / C):
   - **A — Adopt-only:** install Socktainer, point compose at it, ship features as our consumers need them. Zero contributions.
   - **B — Adopt + contribute the gaps that block us:** stats stream + logs follow, since those block signoz/alloy. *Recommendation.*
   - **C — Adopt + become a regular contributor:** treat Socktainer as an upstream we co-maintain. Larger commitment, larger leverage.

2. **Validate before committing** (yes / no): run a 30-min smoke test first. `brew install socktainer/tap/socktainer` (assuming a Homebrew tap exists), point Traefik at `unix://$HOME/.socktainer/container.sock`, confirm dev-health stops erroring. Answers "is CHAOS-1341 actually closeable?" before we touch Linear.

3. **Linear hygiene** (after #1 + #2): (a) update CHAOS-1340 description; (b) close CHAOS-1341 with Socktainer attribution if validated; (c) reframe CHAOS-1342 as a Socktainer contribution ticket with the `NotImplemented` line as the entry point; (d) close CHAOS-1343; (e) delete the local branch `feat/xpc-api-docker-draft` from the container fork clone.

## References

- Closing comment: https://github.com/apple/container/issues/1476#issuecomment-4349314491
- Original (replaced) issue: https://github.com/apple/container/issues/1475 (closed)
- Socktainer repo: https://github.com/socktainer/socktainer
- Socktainer homepage: https://socktainer.github.io
- Stats handler stub: `socktainer/socktainer/Sources/socktainer/Routes/Containers/ContainerStatsRoute.swift` (handler body is `NotImplemented.respond("/containers/{id}/stats", req.method.rawValue)`)
- Linear epic: CHAOS-1340 (https://linear.app/fullchaos/issue/CHAOS-1340/docker-api-compatibility-for-full-chaoscontainer-runtime-http-bridge)
- Local branch to delete: `feat/xpc-api-docker-draft` in `/Users/chris/projects/full-chaos/container/container/`
- Canonical fork doc requiring update: `docs/upstream-fork-status.md` §2.E (currently says "tracked via CHAOS-1341/1342" — needs Socktainer attribution)
