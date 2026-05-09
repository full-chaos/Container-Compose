---
title: Limitations and Gotchas
description: Practical guide to compose-spec features that do not work in Container-Compose today, organized by user pain.
---

# Limitations and Gotchas

Container-Compose is a translator from compose-spec to `apple/container`. Where Apple's runtime has no equivalent, fields are decoded and warned. Below is the practical impact, organized by feature.

This page is symptom-first. For the full tier-by-tier gap inventory, see [Feature Parity](../feature-parity.md). For a workflow-oriented migration walkthrough, see [Migration from Docker Compose](./migration-from-docker-compose.md).

---

## Docker socket mounts (Traefik, Watchtower, Portainer, cAdvisor)

**The pattern that breaks:**

```yaml
services:
  traefik:
    image: traefik:v3.0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
```

**Why it fails:** There is no Docker daemon on the host. `apple/container` runs containers in lightweight per-container VMs managed by its own runtime. Nothing serves the Docker Engine API at `/var/run/docker.sock`. Mounting that path into a container gives the container a socket that does not exist.

**Container-Compose's own daemon socket is not a substitute.** The optional HTTP daemon at `~/.container-compose/api.sock` speaks the Container REST API, not the Docker Engine API. Mounting it as `/var/run/docker.sock` will not satisfy Docker-API clients.

**Concrete example:** A Traefik service configured with the `docker` provider will start, but Traefik's docker provider will fail to connect and list zero containers. Labels like `traefik.http.routers.myapp.rule=Host(...)` will be silently ignored.

**Workaround today:** Configure Traefik with the [file provider](https://doc.traefik.io/traefik/providers/file/) (static config) instead of the docker provider. Define routes in a mounted config file rather than container labels. For other tools, run reverse-proxy or monitoring logic outside the container stack, or use host-level agents.

**Future direction:** Docker Engine API compatibility is tracked as Linear `CHAOS-1340` (epic) via the [Socktainer](https://github.com/socktainer/socktainer) community project. Apple's `container` maintainer redirected Docker-API requests there when closing the upstream FR. Container-Compose has not yet integrated Socktainer. See [`docs/plans/socktainer-pivot-summary.md`](../plans/socktainer-pivot-summary.md) for the current status.

**Affected ecosystem tools:** Traefik (docker provider), Watchtower, Portainer, cAdvisor, autoheal, dockerproxy, docker-gen, ouroboros, diun.

---

## Network features

The following network fields are warn-skipped (CHAOS-1334, blocked on `apple/container` upstream):

- **Network-level `aliases:`** — cross-service references must use the container name `<project>-<service>` directly.
- **Static IP assignment** (`networks.<n>.ipv4_address` / `ipv6_address`) — the `--ip` and `--ip6` flags are not accepted by `apple/container`. Remove these fields or switch to service-name-based discovery.
- **`networks.<n>.driver_opts`** — parsed but not passed to the runtime.
- **`networks.<n>.ipam.*`** — subnet, gateway, and IP range configuration are not wired.
- **`networks.<n>.enable_ipv6`** — parsed and ignored.
- **`service.network_mode: host`** — containers run in lightweight VMs, so "host" networking is not the macOS host network in the Docker sense.

---

## Resource limits

Only `cpus` and `memory` (and their `deploy.resources.limits` equivalents) take effect. Everything else is warn-skipped: the container starts without the constraint applied, and a warning prints to stdout.

Warn-skipped resource fields:

- `shm_size`
- `pids_limit` / `deploy.resources.limits.pids`
- `mem_swappiness`
- `memswap_limit`
- `mem_reservation` / `deploy.resources.reservations.memory`
- `cpu_shares`
- `cpuset`
- `cpu_period`, `cpu_quota`
- `cpu_rt_period`, `cpu_rt_runtime`
- `oom_kill_disable`, `oom_score_adj`
- `blkio_config.*`

Tracking: CHAOS-1375.

---

## Linux/Windows-specific fields

These fields are decoded and classified as not applicable on macOS (Tier 4 in [Feature Parity](../feature-parity.md)):

- `cgroup`, `cgroup_parent`
- `device_cgroup_rules`
- `storage_opt`
- `isolation`
- `credential_spec`
- `label_file`

Remove them from your compose file to silence warnings. Behavior is otherwise unchanged.

---

## Security and isolation

The following fields are warn-skipped because `apple/container` has no equivalent flags:

- `--ipc`, `--pid`, `--uts` (namespace modes)
- `--security-opt`
- `userns_mode` (`--userns`)
- `cap_add` / `cap_drop` (partial — parsed but not fully applied)
- `devices` (`--device` host passthrough)
- `sysctls`
- `mac_address`
- `gpus`

Note that container isolation in `apple/container` already comes from per-container VMs, so the security model differs from Docker's shared-kernel namespace approach. Many of these fields address Linux namespace concerns that do not map to the VM model.

---

## Swarm orchestration

The following `deploy` fields are decoded but ignored — they belong to a different orchestrator class:

- `deploy.mode`
- `deploy.replicas`
- `deploy.placement`
- `deploy.update_config`
- `deploy.rollback_config`
- `deploy.endpoint_mode`

For replica-style fan-out, use the top-level `scale:` field on a service instead:

```yaml
services:
  worker:
    image: myworker:latest
    scale: 3
```

---

## Deprecated compose-spec fields

`links`, `external_links`, and `volumes_from` are not implemented. Use `depends_on` and named volumes or bind mounts instead.

---

## Secrets and configs

**File-sourced (`file:`) works.** The file contents are bind-mounted into the container at the specified target path.

**Runtime-managed and external do not work:**

- `POST /secrets` (runtime-managed secrets without a file source) is not implemented.
- `external: true` on secrets or configs is not supported.

**Workaround:** Read from your secrets manager in an entrypoint script and write to the expected path at container start. Or use environment variables:

```yaml
services:
  app:
    environment:
      DB_PASSWORD: "${DB_PASSWORD}"
```

---

## Logging drivers

Only the default logging driver works. Specifying a non-default `logging.driver` is parsed and warned. See [`docs/tutorials/logging-driver.md`](../tutorials/logging-driver.md).

---

## Volume drivers

Only the `local` driver works. `driver_opts:` is parsed but not wired (CHAOS-1335). Workaround: bind-mount NFS shares directly from the macOS host instead of using a volume driver.

---

## macOS 15 (Sequoia) DNS

Service-name resolution requires manual DNS configuration on macOS 15. macOS 26 (Tahoe) handles this natively. Upgrade to Tahoe for the best experience.

---

## How warnings appear

When you `up` a stack with unsupported fields, you'll see lines like:

```
'service.shm_size' is parsed but not supported by Apple container; ignored.
```

The container still starts. To see all warn sites in the source, search for `Detected, But Not Supported` and `is parsed but not supported` in `Sources/Container-Compose/Commands/`.

---

## See also

- [Feature Parity Inventory](../feature-parity.md) — full tier-by-tier gap breakdown
- [Upstream / Fork Status](../upstream-fork-status.md) — what is blocked on `apple/container`
- [Migration from Docker Compose](./migration-from-docker-compose.md) — workflow-oriented migration guide
- [Troubleshooting](./troubleshooting.md) — symptom-to-fix reference
- [Socktainer Pivot Summary](../plans/socktainer-pivot-summary.md) — Docker API compatibility roadmap
