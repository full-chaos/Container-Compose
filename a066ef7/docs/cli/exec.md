---
title: container-compose exec
description: Execute a command in a running service container.
---

# container-compose exec

Execute a command in a running service container.

## Synopsis

```bash filename="terminal"
container-compose exec [global-options] [options] service command [args...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--detach` | `-d` | flag | | Run command in the background |
| `--no-interactive` | | flag | | Disable STDIN passthrough (default: interactive is on) |
| `--no-tty` | | flag | | Disable TTY allocation (default: tty is on) |
| `--environment` | `-e` | string | | Set an environment variable KEY=VALUE (can be repeated) |
| `--user` | `-u` | string | | Run as specified username or uid |
| `--workdir` | `-w` | string | | Working directory inside the container |
| `--file` | `-f` | path | | The path to your Docker Compose file |

## Arguments

| Argument | Description |
| :--- | :--- |
| `service` | The service to execute a command in |
| `command` | Command to execute |

## Examples

### Open a shell in a running container

Execute `sh` in the already running `web` container.

```bash filename="terminal"
container-compose exec web sh
```

### Run a command as a different user

Run a database command as the `root` user.

```bash filename="terminal"
container-compose exec -u root db psql
```

### Run a command in a specific directory

Execute a command in the `/app/src` directory.

```bash filename="terminal"
container-compose exec -w /app/src web ls -l
```

## See also

- [`run`](./run.md)
- [`ps`](./ps.md)
