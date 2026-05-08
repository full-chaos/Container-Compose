---
title: Multi-network with aliases with Container-Compose
description: Learn how to isolate services using multiple networks and understand the status of network aliases.
---

# Multi-network with aliases

Network isolation is a core feature of container orchestration. It allows you to separate public-facing services from internal databases and workers. This tutorial demonstrates how to define multiple networks and connect services to them.

## What you'll build

- A public `frontend` network for a proxy service.
- A private `backend` network for internal API and worker services.
- Services connected to multiple networks simultaneously.
- Understanding of network alias support in Container-Compose.

## Prerequisites

- Container-Compose installed ([Quickstart](../quickstart.md))
- Apple Container running (`container system start`)
- Familiarity with Docker Compose YAML

## The compose file

The complete example lives at [`Sample Compose Files/Multi-network with aliases/docker-compose.yml`](../../Sample%20Compose%20Files/Multi-network%20with%20aliases/docker-compose.yml). Here's what it does:

```yaml title="docker-compose.yml"
# Demonstrates service-level networks in object form with aliases (Phase 3B).
# Both list and map forms are accepted; this file uses the map form.

networks:
  frontend:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.20.0.0/24
  backend:
    driver: bridge
    internal: true

services:
  proxy:
    image: nginx:alpine
    networks:
      frontend:
        aliases: [proxy, edge]
        priority: 100
    ports:
      - "8080:80"

  api:
    image: alpine:latest
    command: ["sh", "-c", "echo api && sleep infinity"]
    networks:
      frontend:
        aliases: [api, api-v1]
      backend:
        aliases: [api]

  worker:
    image: alpine:latest
    command: ["sh", "-c", "echo worker && sleep infinity"]
    networks:
      backend: {}   # connect with no aliases (empty config)
```

## Step 1: Creating the networks

When you run the project, Container-Compose first creates the top-level networks defined in the `networks` section.

```bash title="terminal"
container-compose up -d
```

The `frontend` network is created with a specific subnet, while the `backend` network is marked as `internal`, meaning it has no default gateway to the outside world.

## Step 2: Connecting services

The `api` service is connected to both the `frontend` and `backend` networks. This allows it to receive traffic from the `proxy` (on the frontend) and communicate with the `worker` (on the backend).

## Current status of network aliases

While the multi-network connectivity works as expected, it is important to note that service-level `aliases` are currently **warn-skipped** (see CHAOS-1331). 

In standard Docker Compose, aliases allow services to reach each other using custom DNS names. In the current version of Container-Compose, services can still reach each other using their service names (e.g., `api` or `worker`), but the additional names specified in the `aliases` list will not be resolvable.

For more information on network feature parity, see the [Upstream/Fork Status](../upstream-fork-status.md#2a-network-aliases) documentation.

## Verifying connectivity

You can verify that the networks were created and the containers are attached by using the Apple Container CLI.

```bash title="terminal"
container network ls
container network inspect frontend
```

The inspection output will list the containers currently attached to the network.

## What's happening under the hood

Container-Compose translates the top-level `networks` section into `container network create` commands. It honors driver settings and IPAM configurations where supported by the Apple Container runtime.

For service connections, it uses the `--network` flag during `container run`. The `priority` field is used to determine the order of network attachment, which can affect default routing inside the container. However, the `aliases` field is parsed but not yet passed to the runtime, as the underlying Apple Container API for network aliases is still in development.

## Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| `network not found` | The network failed to create | Check for subnet conflicts with existing host networks |
| `alias not resolving` | Network aliases are currently warn-skipped | Use the service name for inter-service communication |
| `daemon not running` | `container system start` not run | `container system start` then retry |

## Cleanup

```bash title="terminal"
container-compose down
```

## See also

- [Logging driver](./logging-driver.md)
- [CLI: `up`](../cli/up.md)
