---
title: container-compose down
description: Stop containers with compose.
---

# container-compose down

Stop containers with compose.

## Synopsis

```bash filename="terminal"
container-compose down [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |
| `--cwd` | | path | | Host working directory for locating the Compose file |
| `--file` | `-f` | path | | The path to your Docker Compose file |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Specify the services to stop |

## Examples

### Stop all services

Stop and remove all containers for the current project.

```bash filename="terminal"
container-compose down
```

### Stop specific services

Only stop the `web` service.

```bash filename="terminal"
container-compose down web
```

## See also

- [`up`](./up.md)
- [`stop`](./stop.md)
