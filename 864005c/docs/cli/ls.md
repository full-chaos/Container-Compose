---
title: container-compose ls
description: List Compose projects on the host.
---

# container-compose ls

List Compose projects on the host.

## Synopsis

```bash filename="terminal"
container-compose ls [global-options] [options]
```

## Options

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--all` | `-a` | flag | | Include stopped projects |
| `--quiet` | `-q` | flag | | Only display project names |

## Examples

### List active projects

Show all projects that have at least one running container.

```bash filename="terminal"
container-compose ls
```

### List all projects

Show all projects, including those with only stopped containers.

```bash filename="terminal"
container-compose ls -a
```

### Get project names only

Useful for scripting.

```bash filename="terminal"
container-compose ls -q
```

## See also

- [`ps`](./ps.md)
