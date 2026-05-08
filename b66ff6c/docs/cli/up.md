---
title: container-compose up
description: Start containers with compose.
---

# container-compose up

Start containers with compose.

## Synopsis

```bash title="terminal"
container-compose up [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--detach` | `-d` | flag | | Detaches from container logs. Note: If you do NOT detach, killing this process will NOT kill the container. To kill the container, run container-compose down |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--build` | `-b` | flag | | Rebuild images before starting containers |
| `--no-cache` | | flag | | Do not use cache |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Specify the services to start |

## Examples

### Start all services in the background

Run all services defined in the compose file and detach from logs.

```bash title="terminal"
container-compose up -d
```

### Start specific services

Only start the `web` and `db` services.

```bash title="terminal"
container-compose up web db
```

### Use a custom compose file

Specify a different compose file to use.

```bash title="terminal"
container-compose -f stack.yaml up
```

### Filter by profile

Only start services that belong to the `dev` profile.

```bash title="terminal"
container-compose up --profile dev
```

## Notes / Anti-Patterns

- Killing the foreground process does NOT stop containers; use `down` to stop and remove them.

## See also

- [`down`](./down.md)
- [`stop`](./stop.md)
- [`start`](./start.md)
