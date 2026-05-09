---
title: container-compose port
description: Print the public port for a service's private port.
---

# container-compose port

Print the public port for a service's private port.

## Synopsis

```bash title="terminal"
container-compose port [global-options] [options] service privatePort
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--protocol` | | string | `tcp` | Port protocol (tcp or udp) |
| `--file` | `-f` | path | | The path to your Docker Compose file |

## Arguments

| Argument | Description |
| :--- | :--- |
| `service` | Service name |
| `privatePort` | Private container port |

## Examples

### Resolve a public port

Find out which host port is mapped to the `web` service's port `80`.

```bash title="terminal"
container-compose port web 80
```

### Resolve a UDP port

Find the host mapping for a UDP port.

```bash title="terminal"
container-compose port dns 53 --protocol udp
```

## See also

- [`ps`](./ps.md)
