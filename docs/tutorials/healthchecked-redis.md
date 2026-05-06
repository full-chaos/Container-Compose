---
title: Healthchecked Redis with Container-Compose
description: Learn how to define and monitor service health for a Redis instance.
---

# Healthchecked Redis

Ensuring that a service is not just running but actually ready to handle traffic is critical for reliable deployments. This tutorial demonstrates how to configure a healthcheck for a Redis service using Container-Compose.

## What you'll build

- A Redis service with persistent volume storage.
- A custom healthcheck using the `redis-cli ping` command.
- Configurable healthcheck intervals and retry logic.
- Verification of health status via the CLI.

## Prerequisites

- Container-Compose installed ([Quickstart](../quickstart.md))
- Apple Container running (`container system start`)
- Familiarity with Docker Compose YAML

## The compose file

The complete example lives at [`Sample Compose Files/Healthchecked Redis/docker-compose.yaml`](../../Sample%20Compose%20Files/Healthchecked%20Redis/docker-compose.yaml). Here's what it does:

```yaml filename="docker-compose.yaml"
services:
  redis:
    restart: always
    image: redis:7-alpine
    volumes:
      - redis-data:/data
    healthcheck:
      test: "redis-cli ping"
      interval: 5s
      retries: 20
    ports:
      - "6379:6379"
```

## Step 1: Starting the service

Launch the Redis service using the `up` command.

```bash filename="terminal"
container-compose up -d
```

The `-d` flag runs the service in detached mode, allowing you to continue using your terminal.

## Step 2: Monitoring health status

Once the service is started, Container-Compose begins executing the healthcheck command inside the container every 5 seconds. You can check the current status of the service using the `ps` command.

```bash filename="terminal"
container-compose ps
```

The output will show the status of the container, including whether it is `starting`, `healthy`, or `unhealthy`.

## Step 3: Understanding the healthcheck logic

The `healthcheck` section defines how the runtime determines if the container is working correctly:
- `test`: The command to run inside the container. A return code of 0 indicates health.
- `interval`: How often to run the check (5 seconds in this example).
- `retries`: How many consecutive failures are allowed before marking the container as `unhealthy`.

## Verifying

You can also use the underlying Apple Container CLI to see the raw health data.

```bash filename="terminal"
container inspect <container_id>
```

Look for the `Health` section in the JSON output to see the log of recent checks and the current state.

## What's happening under the hood

Container-Compose decodes the `healthcheck` block from your compose file. Per [CHAOS-1319](https://linear.app/fullchaos/issue/CHAOS-1319), Container-Compose reads `ContainerSnapshot.health` from the `full-chaos/container` fork to enforce `depends_on: { redis: { condition: service_healthy } }` — meaning a *dependent* service can be made to wait until Redis reports `.healthy` before starting.

> **Runtime requirement:** Container-Compose emits `--health-cmd` / `--health-*` only when the installed `full-chaos/container` fork advertises those flags. Older runtimes are warn-skipped, so the healthcheck block is decoded but the probe command itself is not executed; in that case `depends_on: condition: service_healthy` can only observe health reported by the image/runtime. Until CHAOS-1381 is in your installed fork, prefer images that bake their own `HEALTHCHECK` instruction (the official `redis:7-alpine` does NOT).

## Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| `image not found` | Apple Container can't pull short-form refs by default | Use a fully-qualified ref like `docker.io/library/redis:7-alpine` |
| `unhealthy` status | The `redis-cli` command is failing | Check container logs with `container-compose logs redis` |
| `daemon not running` | `container system start` not run | `container system start` then retry |

## Cleanup

```bash filename="terminal"
container-compose down
```

## See also

- [Healthchecked Web](./healthchecked-web.md)
- [CLI: `ps`](../cli/ps.md)
