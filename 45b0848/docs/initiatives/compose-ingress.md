# Initiative: compose-ingress

> Status: Planned — parent Linear ticket
> [**CHAOS-1500**](https://linear.app/fullchaos/issue/CHAOS-1500/compose-ingress-traefik-style-http-routing-docker-engine-api-surface).
>
> See also: [`docs/upstream-fork-status.md`](../upstream-fork-status.md) — the
> strategic stance on fork freeze + upstream relationship that motivates this
> initiative living compose-side rather than as an apple/container ask.

## Goal

Build a **Traefik-style HTTP routing/ingress capability** inside
container-compose, plus (in scope, sequenced after the routing core) a
**Docker-Engine-API-compatible read surface** so ecosystem tools (Traefik
docker provider, OpenTelemetry `dockerstats`, Grafana Alloy
`loki.source.docker`) can attach to a compose project the same way they attach
to a Docker daemon.

## Why this lives in compose, not upstream

[`apple/container#1476`](https://github.com/apple/container/issues/1476) — the
upstream FR titled _"[Request]: HTTP REST surface compatible with the Docker
Engine API for ecosystem tools (Traefik, OTel, Alloy)"_ — was **closed**.
Apple declined to host that surface in `apple/container` itself.

Rather than re-litigate the upstream conversation, container-compose owns the
capability:

- Compose already models all the inputs the ecosystem tools want (services,
  networks, ports, labels) — that's the shape Traefik / OTel / Alloy already
  know how to consume.
- Compose controls the lifecycle (`compose up` / `compose down`), so a
  sidecar-managed router or HTTP surface fits naturally next to the existing
  embedded DNS sidecar.
- We can iterate on the surface freely without coordinating with upstream
  cadence.

This is consistent with the broader strategy captured in
`docs/upstream-fork-status.md`: forward motion happens in compose; only
foundational, easy-to-accept refactors (the URL → `SystemPackage.FilePath`
migration, DNS alias FRs, IPAM enrichment) are tickled upstream as
trust-builders.

## Architectural shape

### Pattern: compose-resident sidecar

The existing
[`EmbeddedDNSSidecar`](../../Sources/Container-Compose/Runtime/EmbeddedDNSSidecar.swift)
is the architectural template:

- Lives as a sibling container in the compose project network.
- Lifecycle is bound to `compose up` / `compose down`.
- Configured via well-known labels written onto compose-managed containers
  (`compose.dns.resolvers.<network>=<sidecar-ip>`).
- Probe-then-adopt for idempotent re-runs (CHAOS-1493).

`compose-ingress` follows the same shape:

- Optional sidecar started by `compose up` when any service declares ingress
  intent.
- Reads compose service / network / port / label state to compute the routing
  table.
- Updates routes dynamically as services come/go.

### Surface: label-driven routing

Likely a `compose.ingress.*` label namespace (compose-native, not literal
Traefik labels — but spiritually equivalent), e.g.:

```yaml
services:
  api:
    image: my-api:latest
    labels:
      compose.ingress.enable: "true"
      compose.ingress.routers.api.rule: "Host(`api.localhost`)"
      compose.ingress.routers.api.service: "api"
      compose.ingress.services.api.loadbalancer.server.port: "8080"
```

The exact grammar is a design question; the principle is **compose-native
labels, Traefik-shaped semantics**.

### Optional: Docker Engine API read surface

For ecosystem tools that already speak `/var/run/docker.sock`, expose a
read-only subset of the Docker Engine API scoped to a compose project:

- `GET /containers/json`
- `GET /containers/{id}/json`
- `GET /networks`
- `GET /events` (streaming)

This was the original ask in `apple/container#1476`. Hosting it compose-side
keeps the scope narrower (project-scoped instead of host-wide) and avoids the
upstream concerns that closed the FR.

### Foundation: XPC sessions

[`apple/container#1524`](https://github.com/apple/container/pull/1524) (open)
adds XPC session handlers with disconnect callbacks. This plumbing — though
landed for unrelated reasons — is exactly the kind of foundation a
side-channel HTTP surface needs to subscribe to container lifecycle events
without modifying core. Track this PR; it may unblock the API-surface portion
of the initiative without further upstream coordination.

### Future direction: pivot to apple/container plugin

[`apple/container#1410`](https://github.com/apple/container/discussions/1410)
("Expanding Support for Plugins", open Ideas discussion) traces the history
of compose's relationship with apple/container:

- `#239` (compose support inside apple/container) did not merge — the
  request was to ship compose as a **plugin** rather than built-in.
- `#603` / `#635` exposed command-line tools as a programmatic interface
  that plugins can import instead of reconstructing commands.
- Open problem (per the discussion): passing `OptionGroups` / common flags
  down to plugins.

**Strategic implication for compose-ingress:** once apple/container's plugin
architecture matures enough to host a routing/HTTP-surface plugin cleanly,
**compose-ingress should pivot to live as an apple/container plugin** (not
just inside container-compose). Until then, build compose-side using the
sidecar pattern — but **design with eventual plugin migration in mind**:

- Keep the routing core decoupled from compose-specific orchestration
  (so it can be re-hosted as a plugin without rewriting).
- Prefer compose-spec-native input shapes (services / networks / labels)
  that map cleanly onto whatever the plugin API ends up looking like.
- Track `#1410` and the related plugin PRs (`#603`, `#635`, `#717`,
  `#1524`) for the inflection point where the pivot becomes feasible.

## Phasing (proposed)

1. **Phase A — Routing core.** Embedded sidecar + label grammar + HTTP
   reverse-proxy (likely Caddy/Traefik/nginx as the in-sidecar engine).
2. **Phase B — TLS termination.** ACME/local CA integration; per-router TLS
   options.
3. **Phase C — Docker Engine API surface.** Read-only project-scoped
   `/containers/json`, `/networks`, `/events`. Subscribers: external Traefik,
   OTel, Alloy.
4. **Phase D — TCP / non-HTTP routes.** Optional; demand-driven.

## Reference shape: well-scoped upstream-staged PRs

For the trust-building track that runs in parallel, two recent examples show
the cadence:

- [`full-chaos/container#19`](https://github.com/full-chaos/container/pull/19)
  — DNS fix (CHAOS-1478), default-config peer-name DNS resolves.
- [`full-chaos/container#15`](https://github.com/full-chaos/container/pull/15)
  — richer IPAM at network creation time (CHAOS-1334).

Both are small, scoped, and shaped to land upstream. The same discipline
applies to URL→FilePath migration PRs (CHAOS-1448 epic). `compose-ingress`
itself is **not** an upstream ask — it stays compose-side per the rationale
above — but the trust-building track adjacent to it is what eventually
unblocks larger upstream-bound work.

## Open questions

- Routing engine: embed Traefik / Caddy / nginx, or hand-roll a minimal
  HTTP router? (Traefik is the closest match to the rejected upstream FR's
  framing.)
- Label grammar: Traefik-compatible verbatim, or compose-native `compose.ingress.*`?
- API-surface auth model: project-scoped, host-bound only, or
  authenticated for cross-project tooling?
- Relationship to existing CHAOS-1349 / -1356 (auth model) and CHAOS-1359
  (TCP transport opt-in) work that already landed in compose's API path —
  reuse vs net-new?

## References

- apple/container#1410 (open Ideas discussion — plugin architecture future): <https://github.com/apple/container/discussions/1410>
- apple/container#1476 (closed — original Engine API FR): <https://github.com/apple/container/issues/1476>
- apple/container#1524 (open — XPC sessions, foundation for side-channel API): <https://github.com/apple/container/pull/1524>
- apple/container#239 (compose support FR that didn't merge — referenced from #1410): <https://github.com/apple/container/pull/239>
- full-chaos/container#19 (DNS fix example): <https://github.com/full-chaos/container/pull/19>
- full-chaos/container#15 (IPAM example): <https://github.com/full-chaos/container/pull/15>
- `docs/upstream-fork-status.md` — strategic stance on fork freeze + upstream relationship.
- `Sources/Container-Compose/Runtime/EmbeddedDNSSidecar.swift` — sidecar architectural template.
