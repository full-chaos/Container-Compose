---
title: Resource limits with Container-Compose
description: Learn how to constrain CPU, memory, and other resources for your services.
---

# Resource limits

Managing resource consumption is essential for maintaining host stability and ensuring that services do not interfere with each other. This tutorial demonstrates how to apply CPU, memory, and process limits to your containers using Container-Compose.

## What you'll build

- A CPU-bound service with specific core allocations.
- Memory limits and swap constraints.
- Process ID (PID) limits and shared memory configuration.
- Custom ulimits for file descriptors and processes.

## Prerequisites

- Container-Compose installed ([Quickstart](../quickstart.md))
- Apple Container running (`container system start`)
- Familiarity with Docker Compose YAML

## The compose file

The complete example lives at [`Sample Compose Files/Resource limits/docker-compose.yml`](../../Sample%20Compose%20Files/Resource%20limits/docker-compose.yml). Here's what it does:

```yaml filename="docker-compose.yml"
# Demonstrates resource limits via top-level Service properties (Phase 2B).
# These are the new top-level fields from Phase 1.2 (parsed) wired through
# ResourceArgs in Phase 2B. They override deploy.resources.limits when present.

services:
  trainer:
    image: alpine:latest
    command: ["sh", "-c", "yes > /dev/null"]   # CPU-bound dummy workload
    cpus: 1.5
    cpu_shares: 1024
    cpuset: "0-3"
    mem_limit: 512m
    mem_reservation: 256m
    memswap_limit: 1g
    pids_limit: 200
    shm_size: 64m
    oom_kill_disable: false
    oom_score_adj: -500
    ulimits:
      nofile: 65536            # scalar form: soft == hard
      nproc:                   # object form
        soft: 1024
        hard: 2048

  gpu-worker:
    image: alpine:latest
    command: ["sh", "-c", "echo gpu worker && sleep infinity"]
    gpus: all                  # shorthand
    blkio_config:
      weight: 300
      weight_device:
        - path: /dev/sda
          weight: 400
```

## Step 1: Applying CPU constraints

The `trainer` service uses several CPU-related fields:
- `cpus: 1.5`: Limits the service to use at most 1.5 CPU cores.
- `cpu_shares: 1024`: Sets the relative weight of CPU cycles compared to other services.
- `cpuset: "0-3"`: Restricts the service to run only on CPU cores 0, 1, 2, and 3.

These settings ensure that a runaway process in the container cannot starve the host or other services of CPU resources.

## Step 2: Managing memory

Memory limits prevent a container from consuming all available RAM on your Mac:
- `mem_limit: 512m`: The maximum amount of physical memory the container can use.
- `memswap_limit: 1g`: The total amount of memory plus swap space.

Note that while `mem_reservation` is parsed by Container-Compose, it is not yet applied by the underlying runtime. For a full list of supported resource fields, see the [Feature Parity](../feature-parity.md) documentation.

## Step 3: Configuring ulimits

The `ulimits` section allows you to tune system-level constraints for the containerized process. In this example, we increase the maximum number of open files (`nofile`) and the maximum number of processes (`nproc`). This is often required for high-performance databases or web servers.

## Verifying

Start the services and then inspect the running container to verify that the limits are active.

```bash title="terminal"
container-compose up -d
container inspect <container_id>
```

The `HostConfig` section of the inspection output will contain the `CpuQuota`, `Memory`, and `Ulimits` values translated from your compose file.

## What's happening under the hood

Container-Compose parses both the top-level resource fields (like `cpus` and `mem_limit`) and the nested `deploy.resources.limits` block. If both are present, the top-level fields take precedence.

These values are passed to the `ResourceArgs.build` function, which generates the corresponding flags for the `container run` command, such as `--cpus`, `--memory`, and `--ulimit`. The Apple Container runtime then uses macOS-native resource controls (such as `sandbox` and `posix_spawn` attributes) to enforce these limits at the kernel level.

## Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| Container killed by OOM | The `mem_limit` is too low for the workload | Increase `mem_limit` in the compose file |
| `cpuset` error | The specified CPU IDs do not exist on the host | Verify your Mac's core count and adjust `cpuset` |
| `daemon not running` | `container system start` not run | `container system start` then retry |

## Cleanup

```bash title="terminal"
container-compose down
```

## See also

- [Build with target](./build-with-target.md)
- [CLI: `up`](../cli/up.md)
