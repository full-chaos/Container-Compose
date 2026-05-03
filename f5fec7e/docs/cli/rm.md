---
title: container-compose rm
description: Remove stopped project containers.
---

# container-compose rm

Remove stopped project containers.

## Synopsis

```bash filename="terminal"
container-compose rm [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--force` | `-f` | flag | | Remove containers even if they are running |
| `--stop` | `-s` | flag | | Stop the containers before removing them |
| `--volumes` | `-v` | flag | | Remove anonymous volumes associated with the containers |
| `--file` | | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Specify the services whose containers should be removed |

## Examples

### Remove all stopped containers

Delete all containers for the project that are not currently running.

```bash filename="terminal"
container-compose rm
```

### Force remove running containers

Stop and remove all containers, even if they are active.

```bash filename="terminal"
container-compose rm -f -s
```

### Remove specific service containers

Only remove containers for the `web` service.

```bash filename="terminal"
container-compose rm web
```

## See also

- [`down`](./down.md)
- [`create`](./create.md)
