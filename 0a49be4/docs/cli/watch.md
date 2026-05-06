---
title: container-compose watch
description: Monitor file changes and update services.
---

# container-compose watch

Monitor file changes and update services.

## Synopsis

```bash filename="terminal"
container-compose watch [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |
| `--dry-run` | | flag | | Print actions that would be taken without executing them |
| `--polling` | | flag | | Use legacy polling instead of the default FSEvents watcher |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Specify the services to watch (default: all services with develop.watch) |

## Examples

### Start watching for changes

Monitor all services that have `develop.watch` rules defined.

```bash filename="terminal"
container-compose watch
```

### Watch specific services

Only monitor changes for the `web` service.

```bash filename="terminal"
container-compose watch web
```

### Dry run

See what actions would be taken when files change without actually executing them.

```bash filename="terminal"
container-compose watch --dry-run
```

## See also

- [`up`](./up.md)
- [`build`](./build.md)
