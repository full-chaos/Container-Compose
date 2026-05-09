---
title: container-compose start
description: Start existing stopped containers.
---

# container-compose start

Start existing stopped containers (without re-creating them).

## Synopsis

```bash title="terminal"
container-compose start [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Specify the services to start |

## Examples

### Start all stopped services

Start all containers that are currently stopped.

```bash title="terminal"
container-compose start
```

### Start a specific service

Only start the `db` service.

```bash title="terminal"
container-compose start db
```

## See also

- [`stop`](./stop.md)
- [`up`](./up.md)
