---
title: Healthchecked Web with Container-Compose
description: Learn how to orchestrate service startup based on health dependencies.
---

# Healthchecked Web

In complex applications, services often depend on each other. For example, a web application should only start after its database is ready to accept connections. This tutorial demonstrates how to use health-based dependencies to orchestrate a multi-service stack.

## What you'll build

- A three-tier stack consisting of a database (Postgres), a cache (Redis), and a web server (Nginx).
- Healthchecks for the database and cache services.
- Dependency rules that gate the web server startup on the health of its dependencies.
- Handling of optional vs. required dependencies.

## Prerequisites

- Container-Compose installed ([Quickstart](../quickstart.md))
- Apple Container running (`container system start`)
- Familiarity with Docker Compose YAML

## The compose file

The complete example lives at [`Sample Compose Files/Healthchecked Web/docker-compose.yml`](../../Sample%20Compose%20Files/Healthchecked%20Web/docker-compose.yml). Here's what it does:

```yaml title="docker-compose.yml"
# Demonstrates the depends_on object form (compose-spec L277-L310).
# `app` only starts after `db` is healthy, with restart-on-failure semantics.

services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: example
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s

  cache:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 3s
      retries: 3

  app:
    image: nginx:alpine
    depends_on:
      db:
        condition: service_healthy
        required: true
        restart: true
      cache:
        condition: service_healthy
        required: false   # app starts even if cache is degraded
    ports:
      - "8080:80"
```

## Step 1: Starting the stack

Launch the entire stack using the `up` command.

```bash title="terminal"
container-compose up
```

Observe the logs. You will see that the `db` and `cache` containers are created and started first. The `app` container will wait until the healthchecks for its dependencies pass.

## Step 2: Understanding dependency conditions

The `app` service uses the `depends_on` object form to specify fine-grained conditions:
- `condition: service_healthy`: This tells Container-Compose to wait until the dependency's healthcheck returns a healthy status.
- `required: true`: If the `db` fails to become healthy, the `app` service will not start, and the deployment will fail.
- `required: false`: The `app` service will wait for the `cache` to become healthy, but if it fails (e.g., times out), the `app` will proceed to start anyway. This is useful for non-critical dependencies.

## Step 3: Automatic restarts

The `db` dependency also specifies `restart: true`. This means that if the `db` container crashes or becomes unhealthy after the stack is running, Container-Compose will attempt to restart the `app` container to re-establish the connection once the database is healthy again.

## Verifying

Check the status of all services to see them transition from `starting` to `healthy`.

```bash title="terminal"
container-compose ps
```

Once the `db` and `cache` are healthy, the `app` service should show as `running`.

## What's happening under the hood

Container-Compose implements the `depends_on` logic by polling the health status of dependencies before initiating the startup of the dependent service. 

Following the implementation of CHAOS-1319 and CHAOS-1320, Container-Compose reads the `ContainerSnapshot.health` and `lastExitCode` from the Apple Container runtime. For `service_healthy` conditions, it blocks the `app` service's startup task until the runtime reports the dependency as healthy. If `required: true` is set and the dependency fails, an error is propagated, stopping the deployment.

## Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| `app` never starts | The `db` healthcheck is failing | Check `db` logs with `container-compose logs db` |
| `image not found` | Apple Container can't pull short-form refs by default | Use fully-qualified refs like `docker.io/library/postgres:16-alpine` |
| `non-zero exit code` | A dependency failed to start correctly | Verify environment variables like `POSTGRES_PASSWORD` are set |

## Cleanup

```bash title="terminal"
container-compose down
```

## See also

- [Healthchecked Redis](./healthchecked-redis.md)
- [CLI: `logs`](../cli/logs.md)
