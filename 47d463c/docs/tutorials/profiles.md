---
title: Profiles with Container-Compose
description: Learn how to use service profiles to manage different deployment environments.
---

# Profiles

Service profiles allow you to define multiple environments (such as development, production, or monitoring) within a single compose file. This tutorial demonstrates how to selectively start services using the `--profile` flag and environment variables.

## What you'll build

- A core `web` service that always starts.
- A `debugger` service restricted to the `dev` profile.
- A `monitoring` service available in `prod` and `monitoring` profiles.
- An `ops-shell` service shared across `dev` and `prod`.

## Prerequisites

- Container-Compose installed ([Quickstart](../quickstart.md))
- Apple Container running (`container system start`)
- Familiarity with Docker Compose YAML

## The compose file

The complete example lives at [`Sample Compose Files/Profiles/docker-compose.yml`](../../Sample%20Compose%20Files/Profiles/docker-compose.yml). Here's what it does:

```yaml filename="docker-compose.yml"
# Demonstrates service profiles (Phase 3A).
# Run `compose up` with no profile flag → only services without profiles start (web).
# Run `compose up --profile dev` → web + debugger.
# Run `compose up --profile prod` → web + monitoring.

services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"

  debugger:
    image: debian:bookworm-slim
    profiles: [dev]
    command: ["sleep", "infinity"]

  monitoring:
    image: prom/prometheus:latest
    profiles: [prod, monitoring]
    ports:
      - "9090:9090"

  ops-shell:
    image: alpine:latest
    profiles: [dev, prod]
    command: ["sh", "-c", "echo ops shell active && sleep infinity"]
```

## Step 1: Running the default profile

By default, Container-Compose only starts services that do not have a `profiles` field defined.

```bash title="terminal"
container-compose up -d
```

In this example, only the `web` service will start. You can verify this with `ps`.

```bash title="terminal"
container-compose ps
```

## Step 2: Enabling a specific profile

To enable services associated with a profile, use the `--profile` flag.

```bash title="terminal"
container-compose --profile dev up -d
```

This command starts the `web` service (the default) plus the `debugger` and `ops-shell` services, which are both part of the `dev` profile.

## Step 3: Using environment variables

You can also enable profiles using the `COMPOSE_PROFILES` environment variable. This is useful for CI/CD pipelines or persistent local configurations.

```bash title="terminal"
export COMPOSE_PROFILES=prod
container-compose up -d
```

This will start the `web`, `monitoring`, and `ops-shell` services.

## Verifying

You can list all active services and see which profiles are currently running.

```bash title="terminal"
container-compose ps
```

If you want to see which services *would* start for a given profile without actually launching them, use the `config` command.

```bash title="terminal"
container-compose --profile dev config
```

## What's happening under the hood

Container-Compose implements profile filtering during the YAML resolution phase. When the `up` command is invoked, the tool collects all active profiles from the `--profile` flags and the `COMPOSE_PROFILES` environment variable.

It then iterates through the services in the compose file. A service is included in the deployment if:
1. It has no `profiles` defined.
2. At least one of its defined `profiles` matches an active profile.

Services that do not meet these criteria are excluded from the dependency graph and the subsequent container creation tasks.

## Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| Service not starting | The profile is not enabled | Check the `--profile` flag or `COMPOSE_PROFILES` variable |
| Multiple profiles needed | Only one profile was specified | Use the flag multiple times: `--profile dev --profile tools` |
| `daemon not running` | `container system start` not run | `container system start` then retry |

## Cleanup

```bash title="terminal"
container-compose down
```

## See also

- [Resource limits](./resource-limits.md)
- [CLI: `config`](../cli/config.md)
