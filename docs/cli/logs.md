---
title: container-compose logs
description: View output from containers.
---

# container-compose logs

View output from containers.

## Synopsis

```bash title="terminal"
container-compose logs [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--follow` | `-f` | flag | | Follow log output |
| `--tail` | | string | | Number of lines to show from the end of the logs (e.g. '100' or 'all') |
| `--since` | | string | | Show logs since timestamp or relative duration (e.g. '2025-01-01T00:00:00Z' or '10m') |
| `--timestamps` | | flag | | Show timestamps in log output |
| `--no-color` | | flag | | Disable colour prefixes in log output |
| `--file` | | path | | The path to your Docker Compose file |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Services to show logs for (shows all if omitted) |

## Examples

### Follow logs for all services

Stream logs from all containers in the project.

```bash title="terminal"
container-compose logs -f
```

### Show logs for a specific service

Only show logs for the `web` service.

```bash title="terminal"
container-compose logs web
```

### Show recent logs with timestamps

Show the last 50 lines of logs and include timestamps.

```bash title="terminal"
container-compose logs --tail 50 --timestamps
```

### Show logs since a specific time

Show logs from the last 5 minutes.

```bash title="terminal"
container-compose logs --since 5m
```

## See also

- [`up`](./up.md)
- [`events`](./events.md)
