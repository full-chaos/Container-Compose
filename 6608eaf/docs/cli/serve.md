---
title: container-compose serve
description: Start the container-compose HTTP API daemon.
---

# container-compose serve

Start the container-compose HTTP API daemon over a Unix domain socket.

## Synopsis

```bash filename="terminal"
container-compose serve [options]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--socket` | | path | `~/.container-compose/api.sock` | [Deprecated] Path to the Unix domain socket. Use --listen unix:///path instead. |
| `--listen` | | url | | Listen address. Schemes: unix:///path (default), tcp://host:port, tls://host:port |
| `--cert` | | path | | Path to TLS certificate PEM file (required for tls:// unless auto-detected from ~/.container-compose/cert.pem) |
| `--key` | | path | | Path to TLS private key PEM file (required for tls:// unless auto-detected from ~/.container-compose/key.pem) |
| `--client-ca` | | path | | Path to PEM-encoded CA bundle. When provided, the daemon requires every TLS client to present a certificate signed by this CA. |
| `--insecure` | | flag | | Allow plain TCP on non-localhost addresses (warning: unencrypted) |
| `--auth-required` | | flag | | Require Bearer-token auth on Unix socket listeners (always required on TCP/TLS). |
| `--launchd` | | flag | | Run in launchd-managed mode: emit timestamped, structured log lines. |

## Examples

### Start the daemon with default settings

Bind to the default Unix domain socket.

```bash filename="terminal"
container-compose serve
```

### Bind to a custom socket path

Specify a different location for the socket.

```bash filename="terminal"
container-compose serve --listen unix:///tmp/cc.sock
```

### Start with TLS

Enable encrypted transport on a TCP port.

```bash filename="terminal"
container-compose serve --listen tls://0.0.0.0:8443 --cert cert.pem --key key.pem
```

## See also

- [`system`](./system.md)
