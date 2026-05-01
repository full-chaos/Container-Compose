# Upstream / Fork Status

This document catalogs **what container-compose depends on from the
`full-chaos/container` fork** and **what's still blocked by gaps in
`apple/container` upstream**.

It is the canonical source for:

1. Pull requests we should file against `apple/container` to eliminate
   fork dependencies.
2. Feature requests we should file (or track internally) for runtime
   capabilities that `apple/container` does not yet expose.
3. Compose-spec features intentionally deferred or out of scope.

The fork (`origin = full-chaos/container`, `upstream = apple/container`)
currently carries **4 commits** ahead of `apple/container`:

| Commit | PR | Summary |
| ------ | -- | ------- |
| `c910d3d` | #9 | Fix make after Swift toolchain update |
| `c63ed9a` | #6 | feat(api): Add streaming features and support commands |
| `630b8c8` | #7 | feat(api): Surface `lastExitCode` on `ContainerSnapshot` |
| `6d1b9d1` | #8 | fix(commands): Fix indefinite hang on `container --help` |

Together these introduce **6 API additions and 1 bug fix** that
container-compose directly depends on. Without them, container-compose
loses core Compose-spec functionality.

---

## 1. Fork Patches Already Shipped — Need PRs to `apple/container`

These features **work today** via the fork. Each needs a PR to
`apple/container` to eliminate the fork dependency.

| # | Feature | Fork Commit | CHAOS Issue | Container-Compose Consumer | Compose-Spec Feature |
|---|---------|-------------|-------------|---------------------------|---------------------|
| 1 | **`lastExitCode` on `ContainerSnapshot`** | `630b8c8` | CHAOS-1320 | `Compose+Wait.swift` — verifies exit code for `service_completed_successfully` | `depends_on.condition: service_completed_successfully` |
| 2 | **`HealthStatus` enum + `health` on `ContainerSnapshot`** | `c63ed9a` | CHAOS-1319 | `Compose+Wait.swift` — gates on `.healthy` for `service_healthy` | `depends_on.condition: service_healthy` |
| 3 | **`RestartPolicy` type + `--restart` flag on `container run`** | `c63ed9a` | CHAOS-1321 | `Compose+ArgsLifecycle.swift` — emits `--restart` per service | `service.restart` |
| 4 | **`ContainerLogOptions` (`since`, `timestamps`)** | `c63ed9a` | CHAOS-1322 | `ComposeLogs.swift` — `--since` / `--timestamps` flags | `compose logs --since/--timestamps` |
| 5 | **`ContainerEvent` type + `events()` streaming API** | `c63ed9a` | CHAOS-1323 | `ComposeEvents.swift` — native lifecycle event stream | `compose events` |
| 6 | **`Flags.ProcessBase` (`-e`/`-u`/`-w`/`-d` short flags)** | `c63ed9a` | CHAOS-1324 | `ComposeRun.swift` / `ComposeExec.swift` — standard process flags | `compose run/exec -e/-u/-w` |
| 7 | **XPC timeout fix (help freeze)** | `6d1b9d1` | — | Not a direct compose dependency, but critical CLI UX | `container --help` hangs when daemon is unresponsive |

### PR strategy for `apple/container`

- PRs **1–2** (exit code + health) have the broadest utility — any
  container orchestrator needs them.
- PR **3** (restart policy) is essential for any Compose-like workflow.
- PR **7** (XPC fix) is a pure bug fix with 6 unit tests already
  written — lowest friction to upstream.
- PRs **4–6** are compose-oriented enrichments; may be harder to
  motivate upstream and might be candidates for fork-only retention.

---

## 2. Features With No Upstream Equivalent — Need FRs

These are compose-spec features that container-compose **decodes and
warns about** because `apple/container` has no runtime support. Each
needs a Feature Request — either against `apple/container` upstream or
tracked internally for fork-level implementation in
`full-chaos/container`.

### A. Networking (FR against `apple/container`)

| Feature | Current Behavior | What's Needed |
|---------|-----------------|---------------|
| `networks.<name>.aliases` | Parsed, silently ignored | `container network connect --alias` support |
| `extra_hosts` | Parsed, silently ignored | `--add-host` flag on `container run` |
| Network `driver_opts` | Warned, skipped | `container network create --opt` flag |
| Network `attachable` | Warned, skipped | `--attachable` flag |
| `enable_ipv6` (bare flag) | Only works via explicit `--subnet-v6` | Bare `--ipv6` flag on `container network create` |
| IPAM `ip_range` / `gateway` / `aux_addresses` | Warned, skipped | Extended IPAM flags on `container network create` |
| IPAM `driver` / `options` | Warned, skipped | `--ipam-driver` / `--ipam-opt` flags |

### B. Storage (FR against `apple/container`)

| Feature | Current Behavior | What's Needed |
|---------|-----------------|---------------|
| File-level bind mounts | Skipped with warning | `container run -v` support for individual files (not just directories) |
| Named volume references | Workaround via hardlink directories | Native `container volume create` + `container run -v name:/path` |
| Non-local volume drivers | Falls back to hardlink dir | Volume driver plugin system |
| Anonymous volume removal | Skipped with note | `ContainerClient` API for volume lifecycle |
| `volumes_from` | Warned, skipped | `--volumes-from` flag |
| `storage_opt` | Warned, skipped | `--storage-opt` flag |

### C. Container Runtime (FR against `apple/container`)

| Feature | Current Behavior | What's Needed |
|---------|-----------------|---------------|
| `logging.driver` / `logging.options` | Parsed, ignored | `--log-driver` / `--log-opt` flags |
| `build.entitlements` | Warned, ignored | Entitlements support in `container build` |
| `template_driver` (configs/secrets) | Warned, mounted as raw file | Template processing engine |
| `--gpus` | Forwarded, may not work | GPU passthrough support |
| `blkio_config` | Forwarded, may not work | Block I/O control flags |
| `container create` (without start) | Probes for support, warns if absent | `container create` subcommand |
| `device_cgroup_rules` | Warned, skipped | cgroup device rules |
| Lifecycle hooks (`post_start` / `pre_stop`) | Decoded only (CHAOS-1303) | Container lifecycle hook API |

### D. Frontier Compose-Spec Features — Track, Don't File Yet

| Feature | Status | Notes |
|---------|--------|-------|
| `top.models` / `service.models` / `service.provider` | "Detected, But Not Supported" | AI/LLM provider plumbing — spec still evolving |
| Swarm-only deploy fields (`replicas`, `update_config`, `rollback_config`, `placement`, `endpoint_mode`, `mode`) | Decoded as stubs | Intentionally deferred — belong to a different orchestrator class |
| `cgroup_parent`, `credential_spec`, `isolation` | Decoded only (CHAOS-1303) | Linux/Windows-specific; likely never relevant on macOS |
| `annotations`, `attach`, `cgroup`, `label_file` | Decoded only (CHAOS-1303) | Low priority; no user demand observed |
| Deprecated: `links`, `external_links` | Intentionally skipped | Deprecated by compose-spec |

### E. Docker API Compatibility (FR against `apple/container` — fork-tracked)

Ecosystem tools (Traefik, OpenTelemetry collector, Grafana Alloy, …) drive
service discovery, metrics, and log shipping through Docker's REST API over
`/var/run/docker.sock`. Apple `container` has no daemon and no socket; tools
fail at startup with `Cannot connect to the Docker daemon`. Closing this gap
is a runtime concern (cross-VM transport + daemon lifecycle), not a compose
concern.

**Linear is canonical for this work** — track scope, AC, and progress in:

| Linear | Role | Scope |
|--------|------|-------|
| **[CHAOS-1340](https://linear.app/fullchaos/issue/CHAOS-1340)** | Epic | Parent issue tracking the full Docker-API-compatibility surface |
| [CHAOS-1341](https://linear.app/fullchaos/issue/CHAOS-1341) | MVP — read-only HTTP bridge | events/list/inspect/networks; unblocks Traefik (`dev-health`, `script-manifest`) |
| [CHAOS-1342](https://linear.app/fullchaos/issue/CHAOS-1342) | Streaming reads — stats + logs | unblocks SigNoz `otel-collector` + Grafana Alloy `loki.source.docker` |

Implementation lives in `full-chaos/container` as a `container system api`
subcommand (HTTP server, TCP-bound on host). Compose-side consumer is
`Sources/Container-Compose/Commands/ComposeUp.swift:505-506` (currently no-op
on `use_api_socket: true`).

**Explicitly out of scope** (no current consumer pressure observed): write
operations on containers, exec endpoints, `/images/*`, vsock-forwarded
`/var/run/docker.sock` inside containers. File a new sibling sub-issue under
CHAOS-1340 if/when a consumer appears.

### F. Container Log File Layout (tracking gap — no ticket filed yet)

Two consumer stacks reviewed during §2.E planning have a parallel gap that
the API bridge does **not** solve: they read host filesystem paths directly,
not the API. Apple `container` has no equivalent path layout.

| Stack | Mount | Tool | Use |
|-------|-------|------|-----|
| `signoz` (`/Users/chris/projects/full-chaos/signoz/deploy/docker/docker-compose.yaml`) | `/var/lib/docker/containers:ro` | OTel `filelog` receiver | tails `*-json.log` files |
| `alloy` (`/Users/chris/projects/alloy/compose/grafana-dc-alloy.yml`) | `/var/log:ro` | Grafana Alloy `loki.source.file` | host syslog tailing |

**Status:** No Linear ticket filed yet — file when a stack actually blocks
on this rather than as a pre-emptive FR. Candidate resolutions:

1. Surface per-container log-file paths via `ContainerSnapshot` and a stable
   layout under `~/.containers/Logs/<id>/...` so receivers can be re-pointed.
2. Pivot affected receivers to consume §2.E's `/containers/{id}/logs?follow=true`
   instead — covers most use cases without filesystem-mount semantics.
3. For host syslog (`alloy /var/log`): non-goal on macOS; document and
   recommend a Linux-side collector or alternate source.

---

## 3. Fork Maintenance Items

| Item | File | Notes |
|------|------|-------|
| `@OptionGroupPassthrough` macro shim for `Flags.Logging` | `Sources/Container-Compose/Commands/Compose+FlagsLoggingPassthrough.swift` | Manual re-implementation of a macro that was in the `mcrich23/container` fork. Must stay in lockstep with upstream `Flags.Logging` definition. If apple/container adds the macro, this file can be deleted. |
| `Flags.ProcessBase` passthrough shim | `Sources/Container-Compose/Commands/Compose+FlagsProcessBasePassthrough.swift` | Same pattern — manual shim for fork-added `Flags.ProcessBase` type. |

---

## 4. Recommended Action Plan

### Immediate (PR to `apple/container`)

1. **XPC timeout fix** — Pure bug fix, 6 unit tests included, easiest to upstream.
2. **`lastExitCode` on `ContainerSnapshot`** — One optional field + one assignment; forward-compatible wire format.
3. **`HealthStatus` on `ContainerSnapshot`** — Small API surface, high utility for any orchestrator.

### Short-term (PR to `apple/container`)

4. **`RestartPolicy` + `--restart` flag** — Standard container primitive; expected by every container UI.
5. **`ContainerLogOptions` extensions** — `--since` / `--timestamps` are table-stakes for log tooling.

### Medium-term (FR against `apple/container`)

6. **Network aliases / `extra_hosts` / IPAM extensions** — Compose-critical networking gaps.
7. **File-level bind mounts** — Major real-world Compose-file blocker.
8. **`container create` subcommand** — Needed for `compose create`.
9. **Logging driver support** — Essential for production use.
10. **Docker API HTTP bridge — MVP** ([CHAOS-1341](https://linear.app/fullchaos/issue/CHAOS-1341)) — Highest ecosystem-compat leverage in this doc; one fork-side daemon unblocks Traefik / OpenTelemetry / log shippers / container UIs in a single batch. See §2.E. Streaming-reads follow-up: [CHAOS-1342](https://linear.app/fullchaos/issue/CHAOS-1342).

### Long-term / Track Only

11. GPU passthrough, lifecycle hooks, AI/LLM provider features —
    monitor compose-spec evolution and apple/container roadmap before
    committing fork engineering effort.
12. **Container log file layout** (§2.F) — file a Linear ticket only when a
    consumer stack hard-blocks on it; for now §2.E's `/containers/{id}/logs`
    covers the most common cases.

---

## 5. References

- Fork repository: <https://github.com/full-chaos/container>
- Apple upstream: <https://github.com/apple/container>
- Container-compose coverage matrix: [`coverage.html`](../coverage.html)
- AGENTS.md "Tier 2" / "Tier 3" classification:
  [`AGENTS.md`](../AGENTS.md#high-leverage-open-work)
- Linear project: **CHAOS** team (issues `CHAOS-1319` … `CHAOS-1338`)

