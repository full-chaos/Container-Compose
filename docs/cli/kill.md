---
title: container-compose kill
description: Force-stop project containers.
---

# container-compose kill

Force-stop project containers.

## Synopsis

```bash title="terminal"
container-compose kill [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--signal` | `-s` | string | `SIGKILL` | Signal to send to the container |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Specify the services to kill |

## Examples

### Kill all containers

Send `SIGKILL` to all running containers in the project.

```bash title="terminal"
container-compose kill
```

### Send a specific signal

Send `SIGTERM` instead of the default `SIGKILL`.

```bash title="terminal"
container-compose kill -s SIGTERM
```

### Kill a specific service

Only kill the `worker` service.

```bash title="terminal"
container-compose kill worker
```

## See also

- [`stop`](./stop.md)
- [`down`](./down.md)
