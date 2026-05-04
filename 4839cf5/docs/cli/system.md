---
title: container-compose system
description: Manage the daemon and runtime state.
---

# container-compose system

Manage the container-compose daemon and runtime state.

## container-compose system status

Report container-compose daemon liveness and runtime-state summary.

### Synopsis

```bash filename="terminal"
container-compose system status [options]
```

### Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--socket` | | path | `~/.container-compose/api.sock` | Path to the Unix domain socket. |
| `--address` | | url | | Listen address to probe. Schemes: unix:///path, tcp://host:port, tls://host:port |
| `--cacert` | | path | | CA certificate PEM file for TLS trust verification (used with tls:// addresses) |

### Examples

#### Check daemon status

Verify if the daemon is running on the default socket.

```bash filename="terminal"
container-compose system status
```

---

## container-compose system generate-key

Generate a new API key for daemon Bearer-token auth.

### Synopsis

```bash filename="terminal"
container-compose system generate-key [options]
```

### Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--name` | | string | | Unique label for the key (used by revoke-key/list-keys). |
| `--auth-file` | | path | `~/.container-compose/auth.json` | Path to auth keys file. |

### Examples

#### Generate a new key

Create a key named `my-app`.

```bash filename="terminal"
container-compose system generate-key --name my-app
```

---

## container-compose system generate-cert

Generate a self-signed TLS certificate and private key.

### Synopsis

```bash filename="terminal"
container-compose system generate-cert [options]
```

### Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--out-dir` | | path | `~/.container-compose` | Directory to write cert.pem and key.pem. |
| `--cn` | | string | `container-compose` | Certificate common name. |
| `--days` | | int | `365` | Certificate validity in days. |
| `--san-dns` | | string | `localhost` | DNS SAN entry (repeatable). |
| `--san-ip` | | string | `127.0.0.1, ::1` | IP SAN entry (repeatable). |
| `--force` | | flag | | Overwrite existing cert.pem and key.pem |

### Examples

#### Generate default certificates

Create `cert.pem` and `key.pem` in the default directory.

```bash filename="terminal"
container-compose system generate-cert
```

---

## container-compose system list-keys

List API keys (NAME, HASH-PREFIX, CREATED).

### Synopsis

```bash filename="terminal"
container-compose system list-keys [options]
```

### Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--auth-file` | | path | `~/.container-compose/auth.json` | Path to auth keys file. |

---

## container-compose system revoke-key

Revoke an API key by name.

### Synopsis

```bash filename="terminal"
container-compose system revoke-key [options] <name>
```

### Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--auth-file` | | path | `~/.container-compose/auth.json` | Path to auth keys file. |

### Arguments

| Argument | Description |
| :--- | :--- |
| `name` | The key name to revoke |

## See also

- [`serve`](./serve.md)
