---
title: container-compose build
description: Build images from a compose file.
---

# container-compose build

Build images from a compose file without starting containers.

## Synopsis

```bash title="terminal"
container-compose build [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--no-cache` | | flag | | Do not use cache when building |
| `--verbose` | | flag | | Show extra detail on the empty-output message when no services need building |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Services to build (builds all if omitted) |

## Examples

### Build all services

Build all images defined with a `build` section in the compose file.

```bash title="terminal"
container-compose build
```

### Build a specific service

Only build the `api` service.

```bash title="terminal"
container-compose build api
```

### Build without cache

Force a fresh build of all images.

```bash title="terminal"
container-compose build --no-cache
```

## See also

- [`up`](./up.md)
- [`pull`](./pull.md)
- [`push`](./push.md)
