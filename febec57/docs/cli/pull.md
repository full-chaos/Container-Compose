---
title: container-compose pull
description: Pull service images.
---

# container-compose pull

Pull service images.

## Synopsis

```bash filename="terminal"
container-compose pull [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |
| `--include-deps` | | flag | | Also pull images for dependency services |
| `--ignore-pull-failures` | | flag | | Do not fail if a pull cannot be done |
| `--policy` | | string | | Override pull policy: always \| missing \| never |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Services to pull (pulls all image-based services if omitted) |

## Examples

### Pull all images

Pull all images defined in the compose file.

```bash filename="terminal"
container-compose pull
```

### Pull a specific service

Only pull the image for the `web` service.

```bash filename="terminal"
container-compose pull web
```

### Pull with dependencies

Pull the `web` service and all services it depends on.

```bash filename="terminal"
container-compose pull --include-deps web
```

## See also

- [`build`](./build.md)
- [`push`](./push.md)
