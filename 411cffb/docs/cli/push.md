---
title: container-compose push
description: Push service images.
---

# container-compose push

Push service images.

## Synopsis

```bash title="terminal"
container-compose push [global-options] [options] [services...]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |
| `--include-deps` | | flag | | Also push images for dependency services |
| `--ignore-push-failures` | | flag | | Do not fail if an image push cannot be done |
| `--quiet` | `-q` | flag | | Suppress progress output |

## Arguments

| Argument | Description |
| :--- | :--- |
| `services` | Services to push (pushes all image-based services if omitted) |

## Examples

### Push all images

Push all images defined in the compose file to their respective registries.

```bash title="terminal"
container-compose push
```

### Push a specific service

Only push the image for the `api` service.

```bash title="terminal"
container-compose push api
```

## See also

- [`build`](./build.md)
- [`pull`](./pull.md)
