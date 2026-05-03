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

> **Current limitation:** apple/container's `container run` does not yet expose `--health-cmd` / `--health-interval` / `--health-retries` CLI flags, so the test command itself is not executed by the runtime today. The healthcheck block is decoded and surfaced via `ContainerSnapshot.health` only when the runtime is otherwise able to determine health (e.g., via image-baked `HEALTHCHECK` directives). Wiring the explicit CLI form is tracked in [`docs/feature-parity.md`](../feature-parity.md) Tier 3. Until then, prefer images that bake their own `HEALTHCHECK` instruction (the official `redis:7-alpine` does NOT — file your own `Dockerfile FROM redis:7-alpine` if you need full enforcement today).

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
