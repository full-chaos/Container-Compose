---
title: container-compose events
description: Stream container lifecycle events.
---

# container-compose events

Stream container lifecycle events for this Compose project.

## Synopsis

```bash filename="terminal"
container-compose events [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--json` | | flag | | Emit events as newline-delimited JSON |
| `--file` | `-f` | path | | The path to your Docker Compose file |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Filter events to specific services |

## Examples

### Stream all events

Watch all container lifecycle events (create, start, stop, etc.) for the project.

```bash filename="terminal"
container-compose events
```

### Stream events as JSON

Useful for piping into other tools like `jq`.

```bash filename="terminal"
container-compose events --json
```

### Filter events by service

Only watch events for the `web` service.

```bash filename="terminal"
container-compose events web
```

## See also

- [`logs`](./logs.md)
- [`ps`](./ps.md)
