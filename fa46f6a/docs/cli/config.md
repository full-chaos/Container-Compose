---
title: container-compose config
description: Parse, resolve and render the compose file.
---

# container-compose config

Parse, resolve and render the compose file.

## Synopsis

```bash filename="terminal"
container-compose config [global-options] [options]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | | The path to your Docker Compose file |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |
| `--services` | | flag | | Print service names, one per line |
| `--volumes` | | flag | | Print volume names, one per line |
| `--profiles` | | flag | | Print the union of all service profiles, one per line |
| `--no-interpolate` | | flag | | Skip environment-variable substitution |

## Examples

### Validate and view resolved config

Print the fully resolved and merged compose file.

```bash filename="terminal"
container-compose config
```

### List all services

Print only the names of the services defined in the compose file.

```bash filename="terminal"
container-compose config --services
```

### List all volumes

Print only the names of the volumes defined in the compose file.

```bash filename="terminal"
container-compose config --volumes
```

## See also

- [`up`](./up.md)
