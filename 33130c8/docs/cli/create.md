---
title: container-compose create
description: Create containers without starting them.
---

# container-compose create

Create containers without starting them.

## Synopsis

```bash filename="terminal"
container-compose create [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |
| `--build` | `-b` | flag | | Build images before creating containers |
| `--no-cache` | | flag | | Do not use cache when building |
| `--pull` | | flag | | Always pull the image before creating the container |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Specify the services to create |

## Examples

### Create all containers

Provision all containers defined in the compose file without starting them.

```bash filename="terminal"
container-compose create
```

### Create specific service

Only create the `db` container.

```bash filename="terminal"
container-compose create db
```

## See also

- [`up`](./up.md)
- [`rm`](./rm.md)
