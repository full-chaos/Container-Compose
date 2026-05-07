---
title: Logging driver with Container-Compose
description: Learn about logging configuration and current support status in Container-Compose.
---

# Logging driver

Configuring how your containers handle logs is an important part of production readiness. This tutorial explores the `logging` section of the Compose specification and explains how Container-Compose handles these settings on macOS.

## What you'll build

- A service with specific log rotation settings.
- A service configured to send logs to a remote syslog server.
- Understanding of which logging features are currently supported.

## Prerequisites

- Container-Compose installed ([Quickstart](../quickstart.md))
- Apple Container running (`container system start`)
- Familiarity with Docker Compose YAML

## The compose file

The complete example lives at [`Sample Compose Files/Logging driver/docker-compose.yml`](../../Sample%20Compose%20Files/Logging%20driver/docker-compose.yml). Here's what it does:

```yaml filename="docker-compose.yml"
# Demonstrates service.logging driver/options pass-through (Phase 3C).
# Apple `container` runtime may not support all log drivers; flags are
# forwarded and the runtime decides.

services:
  app:
    image: nginx:alpine
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
        labels: production_status,geo
    labels:
      production_status: "stable"
      geo: us-west-2

  syslog-app:
    image: alpine:latest
    command: ["sh", "-c", "echo to syslog && sleep 5"]
    logging:
      driver: syslog
      options:
        syslog-address: tcp://logs.example.com:514
        tag: my-app
```

## Step 1: Starting the services

Launch the project using the `up` command.

```bash title="terminal"
container-compose up
```

## Step 2: Observing the output

When you run the command, you will notice warning messages in the terminal output. These warnings indicate that while Container-Compose recognizes the `logging` configuration, it is currently skipping these fields during the translation to the Apple Container runtime.

## Current support status

It is important to note that `logging.driver` and `logging.options` are currently **warn-skipped** in Container-Compose (see CHAOS-1329). This means that the tool parses the YAML correctly but does not yet wire these specific flags to the underlying `container run` command.

The rest of the compose file, including images, commands, and labels, will function as expected. Your containers will start and run, but they will use the default logging behavior of the Apple Container runtime regardless of the settings in the `logging` block.

For more details on the implementation roadmap and current gaps, refer to the [Upstream/Fork Status](../upstream-fork-status.md#2c-logging-drivers) documentation.

## Verifying logs

Even though custom drivers are not yet applied, you can still view the logs of your services using the standard `logs` command.

```bash title="terminal"
container-compose logs app
```

This will stream the standard output and error from the container using the default runtime logger.

## What's happening under the hood

Container-Compose uses a per-concern argument builder architecture. The logging configuration is parsed into a `Logging` struct, but the corresponding builder in `Compose+ArgsLifecycle.swift` currently emits a warning instead of appending flags to the command line. This design allows the tool to remain compatible with valid Compose files while clearly communicating feature gaps to the user.

## Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| `Logging driver X not supported` | The specified driver is not implemented in the runtime | Use the default driver for now |
| `max-size` not respected | Logging options are currently warn-skipped | Monitor log sizes manually or via external tools |
| `daemon not running` | `container system start` not run | `container system start` then retry |

## Cleanup

```bash title="terminal"
container-compose down
```

## See also

- [Multi-network with aliases](./multi-network-with-aliases.md)
- [CLI: `logs`](../cli/logs.md)
