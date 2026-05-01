---
title: Build with target with Container-Compose
description: Learn how to use multi-stage builds and inline Dockerfiles with Container-Compose.
---

# Build with target

Container-Compose supports advanced build features from the Compose specification. This tutorial demonstrates how to target specific build stages and define Dockerfiles directly within your YAML configuration.

## What you'll build

- A multi-stage build targeting a production environment.
- An inline Dockerfile for a lightweight utility service.
- Custom build arguments and labels.
- Resource limits and network configurations for the build process.

## Prerequisites

- Container-Compose installed ([Quickstart](../quickstart.md))
- Apple Container running (`container system start`)
- Familiarity with Docker Compose YAML

## The compose file

The complete example lives at [`Sample Compose Files/Build with target/docker-compose.yml`](../../Sample%20Compose%20Files/Build%20with%20target/docker-compose.yml). Here's what it does:

```yaml filename="docker-compose.yml"
# Demonstrates the full build sub-feature surface (Phase 2F).
#  - target: pick a stage out of a multi-stage Dockerfile
#  - dockerfile_inline: write the Dockerfile contents in compose itself
#  - cache_from / cache_to: BuildKit-style cache references
#  - labels, network, secrets, ssh, platforms, shm_size

services:
  api:
    build:
      context: .
      dockerfile: Dockerfile
      target: production
      args:
        APP_VERSION: "1.0.0"
      cache_from:
        - type=registry,ref=ghcr.io/myorg/api:cache
      cache_to:
        - type=registry,ref=ghcr.io/myorg/api:cache,mode=max
      labels:
        org.opencontainers.image.title: api
        org.opencontainers.image.source: https://example.com
      network: host
      secrets:
        - id=npmrc,src=/run/secrets/npmrc
      ssh:
        - default
      platforms:
        - linux/arm64
      shm_size: 64m
    image: api:1.0.0

  builder-only:
    build:
      context: .
      dockerfile_inline: |
        FROM alpine:latest
        RUN apk add --no-cache curl
        CMD ["curl", "--version"]
    image: builder-only:latest
```

## Step 1: Building the services

To build the images defined in your compose file without starting the containers, use the `build` subcommand. This is useful for verifying your Dockerfile logic and build arguments before deployment.

```bash filename="terminal"
container-compose build
```

Container-Compose will parse the build instructions and invoke the underlying `container build` commands.

## Step 2: Using inline Dockerfiles

The `builder-only` service uses the `dockerfile_inline` property. This allows you to define small, specialized images without creating a separate file on disk. It is ideal for utility containers or quick experiments.

When you run the build command, Container-Compose creates a temporary Dockerfile with the provided content and passes it to the build engine.

## Step 3: Targeting specific stages

The `api` service specifies `target: production`. This assumes your `Dockerfile` has multiple stages, such as `development`, `test`, and `production`. Container-Compose ensures that only the layers up to the specified stage are built and included in the final image.

## Verifying

After the build completes, you can verify that the images were created by listing them with the Apple Container CLI.

```bash filename="terminal"
container images
```

You should see `api:1.0.0` and `builder-only:latest` in the output.

## What's happening under the hood

Container-Compose translates the `build` section of your service into a set of arguments for the `container build` command. For example, the `target: production` field is converted into the `--target production` flag.

The tool also handles complex features like `cache_from` and `cache_to` by mapping them to the appropriate BuildKit-compatible flags in the Apple Container runtime.

## Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| `image not found` | Apple Container can't pull short-form refs by default | Use a fully-qualified ref like `docker.io/library/redis:7` |
| `daemon not running` | `container system start` not run | `container system start` then retry |
| `Dockerfile not found` | The `api` service expects a file named `Dockerfile` in the current directory | Create a multi-stage `Dockerfile` or use `dockerfile_inline` |

## Cleanup

To remove the images created during this tutorial, use the `container image rm` command.

```bash filename="terminal"
container image rm api:1.0.0 builder-only:latest
```

## See also

- [Resource limits](./resource-limits.md)
- [CLI: `build`](../cli/build.md)
