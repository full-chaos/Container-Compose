---
title: Configs and Secrets with Container-Compose
description: Learn how to manage application configuration and sensitive data using configs and secrets.
---

# Configs and Secrets

Container-Compose allows you to inject configuration files and sensitive data into your containers without baking them into the image. This tutorial covers using inline content and environment variables as sources for configs and secrets.

## What you'll build

- A service that consumes configuration from inline YAML content.
- A service that retrieves configuration from host environment variables.
- A secure secret injected into the container at runtime.
- Verification of file placement and content within the container.

## Prerequisites

- Container-Compose installed ([Quickstart](../quickstart.md))
- Apple Container running (`container system start`)
- Familiarity with Docker Compose YAML

## The compose file

The complete example lives at [`Sample Compose Files/Configs and Secrets/docker-compose.yaml`](../../Sample%20Compose%20Files/Configs%20and%20Secrets/docker-compose.yaml). Here's what it does:

```yaml title="docker-compose.yaml"
services:
  smoke:
    image: docker.io/library/alpine:3
    command: ["sh", "-c", "cat /run/secrets/env_secret; cat /etc/inline_cfg; cat /etc/env_cfg; sleep 2"]
    configs:
      - source: inline_cfg
        target: /etc/inline_cfg
      - source: env_cfg
        target: /etc/env_cfg
    secrets:
      - source: env_secret
configs:
  inline_cfg:
    content: "hello-from-content"
  env_cfg:
    environment: SMOKE_CFG_VAR
secrets:
  env_secret:
    environment: SMOKE_SECRET_VAR
```

## Step 1: Setting environment variables

The compose file uses environment variables as sources for one config and one secret. Before running the project, you must set these variables on your host machine.

```bash title="terminal"
export SMOKE_CFG_VAR="config-from-env"
export SMOKE_SECRET_VAR="secret-from-env"
```

## Step 2: Starting the service

Launch the project using the `up` command. Container-Compose will process the configs and secrets, creating temporary files on the host to facilitate the bind-mounts.

```bash title="terminal"
container-compose up
```

## Step 3: Verifying the injection

The `smoke` service is configured to print the contents of the injected files to the console. You should see the following output in your terminal:

```text
secret-from-env
hello-from-content
config-from-env
```

This confirms that:
1. The secret was correctly sourced from `SMOKE_SECRET_VAR`.
2. The inline config was sourced from the `content` field.
3. The environment config was sourced from `SMOKE_CFG_VAR`.

## What's happening under the hood

Container-Compose implements configs and secrets by creating temporary files in a managed directory (typically under `~/.container-compose/`). 

For `content` sources, the text is written directly to a file. For `environment` sources, the value of the specified host variable is written to the file. These files are then bind-mounted into the container at the specified `target` path (or the default `/run/secrets/` for secrets) using the `container run -v` flag. This approach ensures compatibility with the Apple Container runtime while maintaining the expected Compose semantics.

## Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| `image not found` | Apple Container can't pull short-form refs by default | Use a fully-qualified ref like `docker.io/library/alpine:3` |
| `cat: /etc/env_cfg: No such file` | The environment variable was not set on the host | Run `export SMOKE_CFG_VAR=...` before `up` |
| `permission denied` | The container user lacks read access to the mount point | Ensure the `target` path is in a writable or accessible directory |

## Cleanup

```bash title="terminal"
container-compose down
```

## See also

- [Profiles](./profiles.md)
- [CLI: `up`](../cli/up.md)
