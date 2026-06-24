---
title: CLI Reference
description: Complete reference for the container-compose CLI.
---

# CLI Reference

This reference covers all subcommands and options available in the `container-compose` CLI. `container-compose` is a tool to use and manage Docker Compose files with Apple Container.

## Global Flags

These flags are shared by all subcommands. Recognized global flags placed before the subcommand are automatically promoted to after the subcommand for compatibility with Docker Compose UX.

| Flag | Shorthand | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `--file` | `-f` | path | `compose.yaml` | Path to compose file. |
| `--project-name` | `-p` | string | | Project name override (defaults to compose 'name:' field, then cwd basename). |
| `--project-directory` | | path | | Project root directory for resolving relative paths (defaults to the compose file's directory). |
| `--profile` | | string | | Specify a profile to enable. Can be specified multiple times. |
| `--env-file` | | path | `.env` | Path to environment file. |

## Lifecycle Commands

Commands for managing the lifecycle of your containers.

| Command | Description | Detailed Reference |
| :--- | :--- | :--- |
| `up` | Start containers with compose | [Reference](./cli/up.md) |
| `down` | Stop containers with compose | [Reference](./cli/down.md) |
| `start` | Start existing stopped containers | [Reference](./cli/start.md) |
| `stop` | Stop running containers without removing them | [Reference](./cli/stop.md) |
| `restart` | Restart running containers | [Reference](./cli/restart.md) |
| `create` | Create containers without starting them | [Reference](./cli/create.md) |
| `kill` | Force-stop project containers | [Reference](./cli/kill.md) |
| `rm` | Remove stopped project containers | [Reference](./cli/rm.md) |

## Inspection Commands

Commands for inspecting the state of your project.

| Command | Description | Detailed Reference |
| :--- | :--- | :--- |
| `ps` | List containers for this Compose project | [Reference](./cli/ps.md) |
| `ls` | List Compose projects on the host | [Reference](./cli/ls.md) |
| `logs` | View output from containers | [Reference](./cli/logs.md) |
| `top` | Display running processes in project containers | [Reference](./cli/top.md) |
| `port` | Print the public port for a service's private port | [Reference](./cli/port.md) |
| `events` | Stream container lifecycle events | [Reference](./cli/events.md) |
| `config` | Parse, resolve and render the compose file | [Reference](./cli/config.md) |

## Build & Run Commands

Commands for building images and running one-off commands.

| Command | Description | Detailed Reference |
| :--- | :--- | :--- |
| `build` | Build images from a compose file | [Reference](./cli/build.md) |
| `pull` | Pull service images | [Reference](./cli/pull.md) |
| `push` | Push service images | [Reference](./cli/push.md) |
| `run` | Run a one-off command on a service | [Reference](./cli/run.md) |
| `exec` | Execute a command in a running service container | [Reference](./cli/exec.md) |
| `watch` | Monitor file changes and update services | [Reference](./cli/watch.md) |

## System & API Commands

Commands for managing the daemon and system state.

| Command | Description | Detailed Reference |
| :--- | :--- | :--- |
| `serve` | Start the HTTP API daemon | [Reference](./cli/serve.md) |
| `system` | Manage the daemon and runtime state | [Reference](./cli/system.md) |
| `version` | Display the version information | [Reference](./cli/version.md) |

## API Clients

Generated SDK publication channels for the daemon's OpenAPI surface.

| Topic | Description | Detailed Reference |
| :--- | :--- | :--- |
| `api-clients` | SDK package names, install commands, and snapshot/release channels | [Reference](./cli/api-clients.md) |

## Exit Codes

- `0`: Success
- `1`: General error
