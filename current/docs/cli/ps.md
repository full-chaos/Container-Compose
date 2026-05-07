---
title: container-compose ps
description: List containers for this Compose project.
---

# container-compose ps

List containers for this Compose project.

## Synopsis

```bash title="terminal"
container-compose ps [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--quiet` | `-q` | flag | | Only display container IDs |
| `--all` | | flag | | Include stopped containers |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Filter output to specific services |

## Examples

### List running containers

Show all running containers for the current project.

```bash title="terminal"
container-compose ps
```

### List all containers

Show both running and stopped containers.

```bash title="terminal"
container-compose ps --all
```

### Get container IDs only

Useful for scripting.

```bash title="terminal"
container-compose ps -q
```

## See also

- [`ls`](./ls.md)
- [`top`](./top.md)
