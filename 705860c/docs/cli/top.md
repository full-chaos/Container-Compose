---
title: container-compose top
description: Display running processes in project containers.
---

# container-compose top

Display running processes in project containers.

## Synopsis

```bash filename="terminal"
container-compose top [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Services to show processes for (shows all if omitted) |

## Examples

### Show processes for all services

List all processes running inside every active container in the project.

```bash filename="terminal"
container-compose top
```

### Show processes for a specific service

Only list processes for the `db` service.

```bash filename="terminal"
container-compose top db
```

## See also

- [`ps`](./ps.md)
- [`logs`](./logs.md)
