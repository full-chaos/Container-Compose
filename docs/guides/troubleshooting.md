---
title: Troubleshooting
description: Symptom-to-fix reference for common Container-Compose problems.
---

# Troubleshooting

Each entry below follows the pattern: **Symptom → Cause → Fix**. Start with the symptom that matches what you're seeing.

---

## "Container runtime not available" / `container` not found

**Symptom:** `container-compose up` fails immediately with a message about the runtime not being available, or `container: command not found`.

**Cause:** Apple Container is not installed, or the system daemon has not been started.

**Fix:**

1. Install Apple Container from [github.com/apple/container/releases](https://github.com/apple/container/releases).
2. Start the system daemon:
   ```bash title="terminal"
   container system start
   ```
3. Verify it is running:
   ```bash title="terminal"
   container ls
   ```

---

## Service hostnames don't resolve from inside containers (macOS 15)

**Symptom:** Containers can't reach each other by service name. DNS lookups for `<service>` or `<project>-<service>` fail inside containers.

**Cause:** macOS 15 (Sequoia) does not auto-configure DNS for the container subnet.

**Fix options:**

- Upgrade to macOS 26 (Tahoe), which handles container DNS natively.
- Follow Apple Container's manual DNS setup instructions for macOS 15.

See also: [Limitations and Gotchas — macOS 15 DNS](./limitations-and-gotchas.md#macos-15-sequoia-dns).

---

## "unknown option" runtime errors when running `up`

**Symptom:** `container-compose up` starts containers but prints errors like `Error: unknown option --shm-size` or similar.

**Cause:** An older Container-Compose build that emits flags `apple/container` does not accept. These are Tier 0 silent-failure bugs.

**Fix:** Upgrade to the latest release:

```bash title="terminal"
brew upgrade container-compose
```

Or rebuild from source:

```bash title="terminal"
make build && make install
```

For the full list of affected flags, see [Feature Parity — Tier 0](../feature-parity.md#3-tier-0--silent-failure-high-priority).

---

## Service stuck in "starting" — never becomes healthy

**Symptom:** `container-compose ps` shows a service in a starting or unhealthy state indefinitely. `up` blocks waiting for a dependency.

**Cause:** The healthcheck is failing inside the container.

**Fix:**

1. Check the service logs:
   ```bash title="terminal"
   container-compose logs <service>
   ```
2. Run the healthcheck command manually inside the container:
   ```bash title="terminal"
   container exec <project>-<service> sh -c '<your healthcheck command>'
   ```
3. Verify the command exits 0 inside the container, not just on the host. Path differences, missing binaries, and network timing are common culprits.

---

## "Port already in use" on `up`

**Symptom:** `container-compose up` fails with a port binding error.

**Cause:** Another process is bound to the port, or a previous run did not tear down cleanly.

**Fix:**

1. Tear down any existing stack:
   ```bash title="terminal"
   container-compose down
   ```
2. Find what is holding the port:
   ```bash title="terminal"
   lsof -iTCP:<port> -sTCP:LISTEN
   ```
3. Check for stale containers:
   ```bash title="terminal"
   container ls -a
   ```

---

## Build context not found / "no such file"

**Symptom:** `container-compose build` or `up` fails with a "no such file or directory" error referencing the build context.

**Cause:** The relative path in `build.context` is resolved against the wrong directory.

**Fix:** Run from the compose file's directory, or pass `--project-directory` explicitly:

```bash title="terminal"
container-compose --project-directory /path/to/project up
```

The project directory defaults to the compose file's parent. Use `container-compose config` to see how paths are resolved after substitution.

---

## `.env` values not interpolating

**Symptom:** Variables like `${IMAGE_TAG}` appear literally in `container-compose config` output, or services start with the wrong image.

**Cause:** The env file is not in the expected location. Precedence is: `--env-file` flag > `process.envFile` in compose YAML > `./.env` (relative to the project directory).

**Fix:** Pass the env file explicitly:

```bash title="terminal"
container-compose --env-file ./path/to/.env up
```

Verify the resolved YAML before starting:

```bash title="terminal"
container-compose config
```

---

## `depends_on` with `condition: service_healthy` doesn't wait

**Symptom:** A service starts before its dependency is healthy, even though `condition: service_healthy` is set.

**Cause:** The dependency service has no `healthcheck` block defined. Container-Compose falls back to `service_started` (running state) when no healthcheck is configured.

**Fix:** Add a `healthcheck` block to the dependency service:

```yaml
services:
  db:
    image: postgres:16
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
```

---

## `depends_on` with `service_completed_successfully` fails on non-zero exit

**Symptom:** `container-compose up` throws an error about a non-zero exit code from a dependency.

**Cause:** This is correct behavior. `condition: service_completed_successfully` requires the dependency to exit 0. Container-Compose throws `ComposeWaitError.nonZeroExitCode` on any other exit code.

**Fix:** Fix the upstream service so it exits 0 on success. If the failure is acceptable (e.g., a migration that may already be applied), use `required: false`:

```yaml
services:
  app:
    depends_on:
      migrate:
        condition: service_completed_successfully
        required: false
```

---

## Traefik / reverse-proxy says no containers found

**Symptom:** Traefik starts but reports zero backends. Container labels are ignored. Other Docker-API clients (Portainer, Watchtower) fail to connect.

**Cause:** Docker socket mounts are not supported. There is no Docker daemon on the host.

**Fix:** See [Limitations and Gotchas — Docker socket mounts](./limitations-and-gotchas.md#docker-socket-mounts-traefik-watchtower-portainer-cadvisor) for the full explanation and workarounds.

---

## Daemon (`serve`) socket connection refused

**Symptom:** API clients or `container-compose system status` report connection refused on `~/.container-compose/api.sock`.

**Cause:** The daemon is not running, or the socket path does not match.

**Fix:**

1. Check daemon status:
   ```bash title="terminal"
   container-compose system status
   ```
2. Start the daemon:
   ```bash title="terminal"
   container-compose serve
   ```
   Or, for Homebrew installs:
   ```bash title="terminal"
   brew services start container-compose
   ```
3. The default socket is `~/.container-compose/api.sock`. If you started with a custom `--socket` path, pass the same path to clients.

---

## "container has no entrypoint or command"

**Symptom:** A container exits immediately with an error about a missing entrypoint or command.

**Cause:** The image declares neither `ENTRYPOINT` nor `CMD`, and the compose service does not provide `command:` or `entrypoint:`.

**Fix:** Add `command:` or `entrypoint:` to the service definition:

```yaml
services:
  worker:
    image: mybase:latest
    command: ["python", "worker.py"]
```

---

## How to file a bug

Open an issue at [github.com/full-chaos/container-compose/issues](https://github.com/full-chaos/container-compose/issues). Include:

- `container-compose --version`
- `container --version`
- macOS version (`sw_vers`)
- `container-compose config` output (redact secrets)
- The full `container-compose up` log

---

## See also

- [Limitations and Gotchas](./limitations-and-gotchas.md) — what does not work and why
- [Error Codes Reference](./error-codes.md) — typed error catalog
- [Feature Parity Inventory](../feature-parity.md) — full gap breakdown by tier
