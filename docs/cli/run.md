---
title: container-compose run
description: Run a one-off command on a service.
---

# container-compose run

Run a one-off command on a service.

## Synopsis

```bash title="terminal"
container-compose run [global-options] [options] service [command] [args...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--detach` | | flag | | Run container in the background |
| `--rm` | | flag | | Remove container after exit |
| `--service-ports` | | flag | | Publish the service's ports to the host |
| `--environment` | `-e` | string | | Set an environment variable KEY=VALUE (can be repeated) |
| `--volume` | `-v` | string | | Bind-mount a volume (can be repeated) |
| `--user` | `-u` | string | | Run as specified username or uid |
| `--name` | | string | | Override the container name |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |

## Arguments

| Argument | Description |
| :--- | :--- |
| `service` | The service to run a command on |
| `command` | Command to run (overrides service command) |

## Examples

### Run a shell in a service

Start a one-off container for the `web` service and run `sh`.

```bash title="terminal"
container-compose run --rm web sh
```

### Run a command with environment variables

Run a test command with a specific environment variable.

```bash title="terminal"
container-compose run -e DEBUG=1 web npm test
```

### Run in the background

Start a one-off container in the background.

```bash title="terminal"
container-compose run -d worker python process.py
```

## See also

- [`exec`](./exec.md)
- [`up`](./up.md)
