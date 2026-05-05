# Migration from Docker Compose

> **Audience:** Users familiar with `docker compose` who want to run their
> stacks with Container-Compose on macOS.
>
> **Platform note:** Container-Compose targets macOS with `apple/container` as
> its runtime. Linux containers are run in lightweight VMs per container.
> Some Docker Compose features depend on Linux kernel primitives (cgroups,
> namespaces, block I/O controllers) that do not have a direct equivalent in
> this model.

---

## Quick start

If your stack uses only the common Compose primitives, it may work with no
changes:

```sh
# Replace this:
docker compose up

# With this:
container-compose up
```

The compose file name (`compose.yml`, `compose.yaml`, `docker-compose.yml`,
`docker-compose.yaml`) and the `--file / -f` flag work the same way.
`COMPOSE_PROJECT_NAME` and `COMPOSE_FILE` environment variables are respected.

What is unchanged:
- `image:`, `build:`, `ports:`, `volumes:` (bind mounts and named), `environment:`
- `depends_on:` (including `condition: service_healthy` and
  `condition: service_completed_successfully`)
- `networks:` (with `bridge` driver; driver is mapped to `container-network-vmnet`)
- `configs:` and `secrets:` with `file:` sources
- Multi-file `include:` support

---

## Supported features

The full field-by-field coverage matrix lives in
[`docs/feature-parity.md`](../feature-parity.md). The summary by tier:

| Tier | What it means | User impact |
| :--- | :--- | :--- |
| **Supported** | Field is decoded and passed to the runtime | Works as expected |
| **Tier 1 — Wireable** | Runtime support exists, field is parsed but not fully applied | Limited functionality; see workarounds below |
| **Tier 3 — Upstream FR** | Feature requires `apple/container` changes | Not available; field is warn-skipped |
| **Tier 4 — Won't do** | Linux/Windows-specific or Swarm-only | Not applicable on macOS; field is silently skipped |

Key supported highlights:
- Port publishing (`-p` / `ports:`)
- Named volumes (local driver) and bind mounts
- Build contexts including `dockerfile_inline:` and `target:`
- Multi-service dependency ordering with `depends_on`
- Environment variable substitution and `.env` files
- Configs and secrets (file-sourced; bind-mounted into containers)
- DNS configuration (`dns:`, `dns_search:`, `dns_opt:`)
- Capabilities (`cap_add:`, `cap_drop:`)
- CPU and memory limits (`deploy.resources.limits.cpus/memory`,
  `mem_limit:`, `cpus:`)

---

## Workarounds for partial features

### Networks: driver options, IPAM, IPv6, aliases

**What does not work:** `networks.<n>.driver_opts`, `networks.<n>.ipam.*`,
`networks.<n>.enable_ipv6`, and network-level `aliases:` are all warn-skipped
(CHAOS-1334 — blocked on `apple/container` upstream).

**Workaround:** For service discovery, containers on the same bridge network
can reach each other by container name. The `--alias` flag is not supported, so
cross-service references must use the compose service name, which Container-Compose
maps directly to the container id (`<project>-<service>`).

```yaml
# This works for basic inter-service communication:
services:
  app:
    image: myapp:latest
    networks:
      - backend
  db:
    image: postgres:16
    networks:
      - backend

networks:
  backend:
    driver: bridge   # mapped to container-network-vmnet automatically
```

Static IP assignment (`networks.<n>.ipv4_address`,
`networks.<n>.ipv6_address`) produces runtime errors — the `--ip` and `--ip6`
flags are not accepted by `apple/container`. Remove these fields or replace
them with service-name-based discovery.

### Secrets and configs: runtime APIs vs. file-sourced

**What works today:** `secrets:` and `configs:` with `file:` sources are
fully supported — the file contents are bind-mounted into the container at the
specified target path.

```yaml
secrets:
  db_password:
    file: ./secrets/db_password.txt

services:
  app:
    secrets:
      - db_password
    # /run/secrets/db_password is available inside the container
```

**What does not work:** The `POST /secrets` REST API (runtime-managed secrets
without a file source) is not implemented in either production backend — see
`RuntimeError.notSupported` under
[`docs/guides/error-codes.md`](./error-codes.md#notsupportedoperation-string-conformer-string).
External secret backends (`secrets.<n>.external: true`) are not supported.

**Workaround:** For external secrets, read the secret from your secrets
manager in an entrypoint script and write it to the expected path at container
start. Or use environment variables (less secure but simpler):

```yaml
services:
  app:
    environment:
      DB_PASSWORD: "${DB_PASSWORD}"
```

### Named volumes: non-local drivers

**What works:** Named volumes with the `local` driver (the default) are
fully supported via `container volume create`:

```yaml
volumes:
  dbdata:          # driver: local (default)
  cache:
    driver: local
```

**What does not work:** Non-`local` volume drivers (`nfs`, `tmpfs`, plugin
drivers) fall back to a local directory. The `driver_opts:` field is parsed
but not wired to `container volume create --opt` yet (CHAOS-1335 open).

**Workaround:** For NFS-backed data, bind-mount the NFS share directly from
the macOS host rather than using a volume driver:

```yaml
services:
  app:
    volumes:
      - /mnt/nfs-share:/data
```

For `tmpfs` mounts, use the `tmpfs:` field directly (supported):

```yaml
services:
  app:
    tmpfs:
      - /tmp
```

### Volume modes: read-only and selinux labels

The compose `:ro` volume modifier is parsed and passed to the runtime.
Docker-specific selinux labels (`:z`, `:Z`) are not supported by
`apple/container` and should be removed from your compose file.

```yaml
# Before:
volumes:
  - ./config:/etc/app/config:ro,z

# After:
volumes:
  - ./config:/etc/app/config:ro
```

### Resource limits: unsupported fields

`deploy.resources.limits.cpus` and `deploy.resources.limits.memory` (and their
top-level equivalents `cpus:`, `mem_limit:`) are supported.

Many granular resource flags accepted by Docker are not supported by
`apple/container` and are warn-skipped by Container-Compose. Setting them in
your compose file produces a console warning but does not cause failure:

- `shm_size:`, `pids_limit:`, `mem_swappiness:`, `memswap_limit:`
- `cpu_shares:`, `cpuset:`, `cpu_period:`, `cpu_quota:`
- `oom_kill_disable:`, `oom_score_adj:`
- `blkio_config:`, `device_read_bps:`, `device_write_bps:`

These are all Tier 0 or Tier 3 items in
[`docs/feature-parity.md`](../feature-parity.md). The fields are decoded and
a warning is printed; the container starts without the constraint.

**Action:** Remove these fields from your compose file to suppress the warnings.
The container will start but without the resource constraint applied.

### Healthcheck: declaration vs. enforcement

`healthcheck:` is fully decoded and the `depends_on: condition: service_healthy`
flow reads health status via the fork's `ContainerSnapshot.health` extension
(CHAOS-1319). However, `container run` has no `--health-cmd` equivalent in
upstream `apple/container`, so the healthcheck subprocess loop is not executed
by the runtime itself.

**Practical impact:** If your depends_on chain relies on health checks passing,
you may see the dependent service start before the upstream service is truly
ready if the upstream service's health check implementation is not done in the
entrypoint.

**Workaround:** Use `condition: service_started` (default) or
`condition: service_completed_successfully` for init containers instead of
relying on `service_healthy` for readiness gating.

### Restart policies

`restart: always`, `restart: on-failure`, `restart: unless-stopped`, and
`restart: no` are decoded and emitted as `--restart` to `container run`. This
flag exists only in the Container-Compose-pinned fork of `apple/container`
(`full-chaos/container` branch `tier2-fork-patches`) and is not in upstream
`apple/container`. It will be warn-skipped once the fork is retired.

### Logging: `logging:` block

`logging.driver` and `logging.options` are warn-skipped. `apple/container`
uses a fixed log layout and does not support external log drivers. Container
logs remain available via `compose logs`.

---

## Real-world examples

### Postgres + Redis (stateful services)

A standard Postgres + Redis stack translates directly:

```yaml
# docker-compose.yml (Docker version)
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: myapp
    volumes:
      - pgdata:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  cache:
    image: redis:7-alpine
    volumes:
      - redisdata:/data
    ports:
      - "6379:6379"
    healthcheck:
      test: "redis-cli ping"
      interval: 5s
      retries: 20

volumes:
  pgdata:
  redisdata:
```

This compose file works with Container-Compose without any changes.
The named volumes `pgdata` and `redisdata` are created as local volumes
via `container volume create`. The `healthcheck:` block is decoded but not
executed by the runtime — Redis will report ready immediately after start.

Run it:

```sh
container-compose up -d
container-compose logs -f cache
```

### WordPress + MySQL

WordPress and MySQL compose files frequently use `restart: always` and
depend on MySQL being ready before WordPress starts.

```yaml
# docker-compose.yml (original)
services:
  db:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: rootsecret
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wpuser
      MYSQL_PASSWORD: wpsecret
    volumes:
      - dbdata:/var/lib/mysql
    restart: always

  wordpress:
    image: wordpress:latest
    ports:
      - "8080:80"
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: wpuser
      WORDPRESS_DB_PASSWORD: wpsecret
      WORDPRESS_DB_NAME: wordpress
    depends_on:
      - db
    restart: always

volumes:
  dbdata:
```

**What to adjust:**

1. `restart: always` — currently works via the fork's `--restart` flag but
   will become a warning when the fork is retired. Acceptable for now.

2. `depends_on: db` uses `condition: service_started` (the default). MySQL
   takes a few seconds to initialize; WordPress may connect before MySQL is
   ready. Add a retry loop in your WordPress entrypoint or use a wait script:

   ```yaml
   depends_on:
     db:
       condition: service_started
   ```

   Then in your WordPress startup, implement retry logic for the database
   connection (e.g., using `wait-for-it.sh` or the built-in WordPress connection
   retry).

3. Service discovery: `WORDPRESS_DB_HOST: db` — this relies on the service
   name `db` resolving to the MySQL container. Container-Compose names
   containers `<project>-<service>` (e.g. `myproject-db`). Check whether
   your network configuration routes the short name `db` or the full container
   name. If short-name resolution does not work, override with the full
   container id or use the IP address discovered at runtime.

### Simple web app with build + Postgres

```yaml
# Original docker-compose.yml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "3000:3000"
    environment:
      DATABASE_URL: "postgres://appuser:apppass@db:5432/appdb"
    depends_on:
      db:
        condition: service_started

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: appuser
      POSTGRES_PASSWORD: apppass
      POSTGRES_DB: appdb
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

This works as-is. The `build:` block uses the standard Dockerfile in the
current directory. Note:

- If your Dockerfile uses `RUN --mount=type=cache` BuildKit cache directives,
  these work because `container build` supports BuildKit.
- `build.cache_from` and `build.cache_to` are warn-skipped (CHAOS-1377 /
  CHAOS-1397). Remove these from the `build:` block to suppress warnings.
- `build.ssh` is warn-skipped. Use multi-stage builds with baked-in SSH keys
  or pass credentials via `--secret` instead.

Build the images first, then start:

```sh
container-compose build
container-compose up -d
```

---

## Troubleshooting

### "unknown option --\<flag\>" at runtime

This means Container-Compose is passing a flag to `container run` that
`apple/container` does not accept. This is a Tier 0 issue documented in
[`docs/feature-parity.md`](../feature-parity.md#3-tier-0--silent-failure-high-priority).

Common culprits and fixes:

| Compose field | Symptom | Fix |
| :--- | :--- | :--- |
| `security_opt:` | `unknown option --security-opt` | Remove field (CHAOS-1371) |
| `userns_mode:` | `unknown option --userns` | Remove field |
| `ipc:` | `unknown option --ipc` | Remove field (CHAOS-1372) |
| `pid:` | `unknown option --pid` | Remove field |
| `uts:` | `unknown option --uts` | Remove field |
| `devices:` | `unknown option --device` | Remove field (CHAOS-1373) |
| `sysctls:` | `unknown option --sysctl` | Remove field |
| `mac_address:` | `unknown option --mac-address` | Remove field (CHAOS-1374) |
| `networks.<n>.ipv4_address:` | `unknown option --ip` | Remove field |
| `networks.<n>.ipv6_address:` | `unknown option --ip6` | Remove field |

For a complete list see [`docs/feature-parity.md` §3](../feature-parity.md#3-tier-0--silent-failure-high-priority).

### `Service <name> must define either 'image' or 'build'`

This is `ComposeError.imageNotFound`. See
[error-codes.md](./error-codes.md#imagenotfoundstring).

### `External volume '<name>' was not found`

This is `ComposeError.externalVolumeNotFound`. Create the volume before
running compose:

```sh
container volume create <name>
container-compose up
```

See [error-codes.md](./error-codes.md#externalvolumenotfoundstring).

### Container exits immediately on `compose up`

1. Check logs: `container-compose logs <service>`
2. Run the container directly to see its output:
   `container-compose run --no-deps <service>`
3. Verify the entrypoint/command: common issue is a Docker-specific entrypoint
   that references `/docker-entrypoint.sh` paths not present in the image
   variant.

### `compose up` fails with "No such container"

A dependency service was removed or never started. Run:

```sh
container-compose down
container-compose up
```

If the error persists, check for container id conflicts with `container ps -a`.

### Named volume data is missing after `compose down`

`compose down` does not remove named volumes by default (same behavior as
Docker Compose). Pass `--volumes` to also remove volumes:

```sh
container-compose down --volumes
```

To inspect or back up volume data before removal, the volume's data is stored
in the `apple/container` volume registry. Use `container volume inspect <name>`
to find the host path.

### `Timed out after <N>s waiting for container '<name>'`

This is `ComposeWaitError.timeout`. See
[error-codes.md](./error-codes.md#timeoutcontainername-string-condition-dependsoncondition-seconds-timeinterval).

A service is not starting in time. Check:
1. Is the upstream service actually starting? `compose logs <upstream>`
2. Is the condition reachable? `service_healthy` requires a healthcheck;
   `service_completed_successfully` requires a zero exit code.

### REST API returns 501 for create/network/secret operations

If you are calling the Container REST API directly (not the compose CLI), you
may hit `.notSupported` errors for operations the Bridge backend cannot handle.
See the [Runtime Protocol Contract](./runtime-protocol.md#notsupportedoperation-string-conformer-string)
for which operations are affected and why. Use the CLI compose commands for
these workflows instead.

---

## Feature support summary

The following table summarizes the most common Docker Compose fields and their
status in Container-Compose. For the full matrix, see
[`docs/feature-parity.md`](../feature-parity.md).

| Field | Status | Notes |
| :--- | :--- | :--- |
| `image:` | Supported | Auto-qualifies short names to `docker.io/library/<name>` |
| `build:` | Supported | `cache_from`, `cache_to`, `ssh`, `network` are warn-skipped |
| `ports:` | Supported | |
| `environment:`, `env_file:` | Supported | |
| `volumes:` bind mounts | Supported | File-level bind mounts not supported (directory only) |
| `volumes:` named volumes | Supported | `local` driver only; `driver_opts` not wired |
| `depends_on:` | Supported | `service_healthy`, `service_completed_successfully` supported |
| `networks:` | Supported | `driver: bridge` → `container-network-vmnet`; `driver_opts`, IPAM blocked |
| `configs:`, `secrets:` (file) | Supported | `external: true` not supported |
| `healthcheck:` | Partial | Decoded; not executed by runtime; `depends_on` reads health status |
| `restart:` | Partial | Fork-only; will become warn-skip when fork is retired |
| `logging:` | Warn-skipped | External log drivers not supported |
| `security_opt:`, `userns_mode:` | Warn-skipped | `apple/container` has no equivalent |
| `devices:`, `sysctls:` | Warn-skipped | Kernel-level features |
| `ipc:`, `pid:`, `uts:` | Warn-skipped | Linux namespace modes |
| `shm_size:`, `pids_limit:` | Warn-skipped | cgroup features not exposed |
| `cpu_shares:`, `cpuset:`, etc. | Warn-skipped | Fine-grained CPU controls not exposed |
| `blkio_config:` | Warn-skipped | Block I/O cgroup controls |
| `deploy.replicas`, `deploy.placement` | Skipped | Swarm-only fields |
| `service.links`, `volumes_from:` | Skipped | Deprecated by compose-spec |

---

## See also

- [Error Codes Reference](./error-codes.md) — meaning and resolution for every error
- [Runtime Protocol Contract](./runtime-protocol.md) — how the runtime layer works and its gaps
- [Feature Parity Inventory](../feature-parity.md) — the canonical field-by-field coverage matrix
- [Reviews](../reviews/) — code review notes and context
