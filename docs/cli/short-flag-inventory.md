# Short-flag inventory (CHAOS-1444)

## Convention

- We follow docker-compose's short-flag mapping where one is well-established.
- Short-flag conflicts within a subcommand resolve in favor of the most-frequently-typed flag (e.g. `logs -f` → `--follow`, leaving `--file` long-only).
- Existing shorts are NEVER removed; this change is purely additive.
- Conservative bias: when convention is unclear, do nothing rather than guess.
- Shared `@OptionGroup`s (`Flags.Process`, `Flags.Logging`, `ProjectFlags`) are out of scope.
  Their flags come from upstream / shared definitions; CHAOS-1444 only touches
  flags declared directly on the per-command structs.

## Summary

Total compose subcommands audited: **20** (plus `system` which is a parent
group with no per-command flags relevant to this audit).

Total `@Flag` / `@Option` declarations on the audited commands (excluding
`@OptionGroup` reuse): see per-command tables below.

Total shorts added: **4**

| Cmd      | Added short(s)        |
| -------- | --------------------- |
| `ps`     | `-a`/`--all`          |
| `run`    | `-d`/`--detach`       |
| `events` | `-j`/`--json`         |
| `logs`   | `-t`/`--timestamps`   |

Conflicts documented (no short added, see per-command tables for rationale):

- `logs --file` cannot take `-f` (taken by `--follow`); already long-only.
- `rm --file` cannot take `-f` (taken by `--force`); already long-only.
- `logs --no-color` has no docker-compose short; left alone.
- `logs --tail`, `--since` have no widely-recognised docker-compose shorts; left alone.

Coordination notes:

- `port` will be touched by Team A under CHAOS-1440 to add `-a/--all` for the
  new listing mode. CHAOS-1444 does NOT edit `ComposePort.swift`.

## Per-command tables

### up
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --detach          | `-d`          | `-d`           | keep   |
| --file            | `-f`          | (global `-f`)  | keep   |
| --build           | `-b`          | (none in DC)   | keep   |
| --no-cache        | (none)        | (none)         | none   |
| --profile         | (none)        | (none)         | none   |

### down
| Long              | Current short | docker-compose       | Action |
| ----------------- | ------------- | -------------------- | ------ |
| --volumes         | `-v`          | `-v`                 | keep   |
| --profile         | (none)        | (none)               | none   |
| --cwd             | (none)        | (project-specific)   | none   |
| --file            | `-f`          | (global)             | keep   |

### ps
| Long              | Current short | docker-compose | Action          |
| ----------------- | ------------- | -------------- | --------------- |
| --file            | `-f`          | (global)       | keep            |
| --quiet           | `-q`          | `-q`           | keep            |
| **--all**         | **(none)**    | **`-a`**       | **ADD `-a`**    |
| --profile         | (none)        | (none)         | none            |

### build
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --file            | `-f`          | (global)       | keep   |
| --no-cache        | (none)        | (none)         | none   |
| --verbose         | (none)        | (none in DC)   | none   |
| --profile         | (none)        | (none)         | none   |

### config
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --file            | `-f`          | (global)       | keep   |
| --profile         | (none)        | (none)         | none   |
| --services        | (none)        | (none)         | none   |
| --volumes         | (none)        | (none)         | none   |
| --profiles        | (none)        | (none)         | none   |
| --no-interpolate  | (none)        | (none)         | none   |

### create
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --file            | `-f`          | (global)       | keep   |
| --profile         | (none)        | (none)         | none   |
| --build           | `-b`          | (none in DC)   | keep   |
| --no-cache        | (none)        | (none)         | none   |
| --pull            | (none)        | (none)         | none   |

### events
| Long              | Current short | docker-compose | Action          |
| ----------------- | ------------- | -------------- | --------------- |
| **--json**        | **(none)**    | **(long-only)** | **ADD `-j`** (project ergonomic; ticket spec) |
| --file            | `-f`          | (global)       | keep            |

Note: docker-compose `events --json` is long-only upstream. CHAOS-1444 adds
`-j` as a project ergonomic alias (per the ticket's example commit message).
Documented here so future audits don't flag the divergence.

### exec
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --detach          | `-d`          | `-d`           | keep   |
| --no-interactive  | (none)        | (none)         | none   |
| --no-tty          | (none)        | `-T`           | none — `-T` not in scope; we model the negation, not the original `-i`/`-t` |
| --env             | `-e`          | `-e`           | keep   |
| --user            | `-u`          | (none in DC)   | keep   |
| --workdir         | `-w`          | `-w`           | keep   |
| --file            | `-f`          | (global)       | keep   |

### kill
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --signal          | `-s`          | `-s`           | keep   |
| --file            | `-f`          | (global)       | keep   |
| --profile         | (none)        | (none)         | none   |

### logs
| Long              | Current short | docker-compose       | Action            |
| ----------------- | ------------- | -------------------- | ----------------- |
| --follow          | `-f`          | `-f`                 | keep              |
| --tail            | (none)        | `-n` (sometimes)     | none — `-n` is not consistently part of `docker compose logs`; conservative skip |
| --since           | (none)        | (none in DC)         | none              |
| **--timestamps**  | **(none)**    | **`-t`**             | **ADD `-t`**      |
| --no-color        | (none)        | (none)               | none              |
| --file            | (none)        | (global)             | none — `-f` is taken by `--follow`; keep long-only |

### ls
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --all             | `-a`          | `-a`           | keep   |
| --quiet           | `-q`          | `-q`           | keep   |

### port
| Long              | Current short | docker-compose | Action                                |
| ----------------- | ------------- | -------------- | ------------------------------------- |
| --protocol        | (none)        | (none)         | none                                  |
| --file            | `-f`          | (global)       | keep                                  |
| (planned `--all`) | n/a           | `-a`           | **NOT IN SCOPE** — Team A / CHAOS-1440 |

### pull
| Long                   | Current short | docker-compose | Action |
| ---------------------- | ------------- | -------------- | ------ |
| --file                 | `-f`          | (global)       | keep   |
| --profile              | (none)        | (none)         | none   |
| --include-deps         | (none)        | (none)         | none   |
| --ignore-pull-failures | (none)        | (none)         | none   |
| --policy               | (none)        | (none)         | none   |

### push
| Long                   | Current short | docker-compose | Action |
| ---------------------- | ------------- | -------------- | ------ |
| --file                 | `-f`          | (global)       | keep   |
| --profile              | (none)        | (none)         | none   |
| --include-deps         | (none)        | (none)         | none   |
| --ignore-push-failures | (none)        | (none)         | none   |
| --quiet                | `-q`          | `-q`           | keep   |

### restart
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --file            | `-f`          | (global)       | keep   |
| --profile         | (none)        | (none)         | none   |

### rm
| Long              | Current short | docker-compose | Action                  |
| ----------------- | ------------- | -------------- | ----------------------- |
| --force           | `-f`          | `-f`           | keep                    |
| --stop            | `-s`          | `-s`           | keep                    |
| --volumes         | `-v`          | `-v`           | keep                    |
| --file            | (none)        | (global)       | none — `-f` taken by `--force`; long-only by design |
| --profile         | (none)        | (none)         | none                    |

### run
| Long              | Current short | docker-compose | Action          |
| ----------------- | ------------- | -------------- | --------------- |
| **--detach**      | **(none)**    | **`-d`**       | **ADD `-d`**    |
| --rm              | (none)        | (none)         | none            |
| --service-ports   | (none)        | (none)         | none            |
| --env             | `-e`          | `-e`           | keep            |
| --volume          | `-v`          | `-v`           | keep            |
| --user            | `-u`          | `-u`           | keep            |
| --name            | (none)        | (none)         | none            |
| --file            | `-f`          | (global)       | keep            |
| --profile         | (none)        | (none)         | none            |

### start
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --file            | `-f`          | (global)       | keep   |
| --profile         | (none)        | (none)         | none   |

### stop
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --file            | `-f`          | (global)       | keep   |
| --profile         | (none)        | (none)         | none   |

### top
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --file            | `-f`          | (global)       | keep   |
| --profile         | (none)        | (none)         | none   |

### watch
| Long              | Current short | docker-compose | Action |
| ----------------- | ------------- | -------------- | ------ |
| --file            | `-f`          | (global)       | keep   |
| --profile         | (none)        | (none)         | none   |
| --dry-run         | (none)        | (none)         | none   |
| --polling         | (none)        | (none)         | none   |

### serve, system (system status), system generate-cert/key, etc.

These are container-compose-specific surfaces (not docker-compose subcommands)
and don't have docker-compose conventions to follow. Out of scope for CHAOS-1444.
