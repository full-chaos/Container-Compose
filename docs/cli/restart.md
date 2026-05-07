---
title: container-compose restart
description: Restart running containers.
---

# container-compose restart

Restart running containers without re-creating them.

## Synopsis

```bash title="terminal"
container-compose restart [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Specify the services to restart |

## Examples

### Restart all services

Restart all containers for the project.

```bash title="terminal"
container-compose restart
```

### Restart a specific service

Only restart the `web` service.

```bash title="terminal"
container-compose restart web
```

## See also

- [`stop`](./stop.md)
- [`start`](./start.md)
