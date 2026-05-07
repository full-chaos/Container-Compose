---
title: container-compose stop
description: Stop running containers without removing them.
---

# container-compose stop

Stop running containers without removing them.

## Synopsis

```bash filename="terminal"
container-compose stop [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Specify the services to stop |

## Examples

### Stop all services

Stop all running containers for the project.

```bash filename="terminal"
container-compose stop
```

### Stop a specific service

Only stop the `web` service.

```bash filename="terminal"
container-compose stop web
```

## See also

- [`start`](./start.md)
- [`down`](./down.md)
