# CHAOS-1440 — `port` runtime listing + `ProjectListing` extraction

**Status:** approved (Section 1) — sections 2-5 finalized inline by the author after user said "spin up the teams". Open for review at any time.
**Date:** 2026-05-07
**Linear:** CHAOS-1440
**Sibling ticket (out of scope here):** flag-shortcut inventory across all subcommands — filed as a separate CHAOS-* issue.

---

## 1. Goal

Make `container-compose port` show **published ports for the running containers of this project**, deliberately diverging from `docker compose port`'s "two-arg or bust" behavior. The two-arg form (`port <service> <private-port>`) keeps working unchanged for backward compatibility with existing scripts.

Modes:

| Invocation                              | Behavior                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `port`                                  | Implicit `--all`. Print `NAME / PORTS` table for every running container in this project.        |
| `port -a` / `port --all`                | Same as above (explicit).                                                                         |
| `port <service>`                        | Print `NAME / PORTS` table filtered to one service. Error if that service has no running container. |
| `port <service> <private-port>`         | **Unchanged.** YAML lookup of `service.ports`, prints raw `host:port`. Backward-compat path.      |
| `port <service> <private-port> --protocol udp` | **Unchanged.** Same as today.                                                                    |

Source of truth for the new modes: **runtime** (`RuntimeEnvironment.current.list(filters:)`). Source of truth for the legacy two-arg mode: **YAML** (unchanged).

## 2. Architecture & touch list

### New file

**`Sources/Container-Compose/Runtime/ProjectListing.swift`** (~80 LOC)

Free functions in a `ProjectListing` enum (Swift's idiom for a namespace with no instances). Encapsulates "list this project's containers from runtime, optionally filtered to specific services, returning structured tuples in a stable order".

```swift
public enum ProjectListing {
    /// Returned tuple: serviceName (parsed from container id by stripping the
    /// "<project>-" prefix and the optional "-N" replica suffix), and the
    /// runtime container snapshot.
    public struct Entry: Sendable, Hashable {
        public let serviceName: String
        public let container: RuntimeContainer
    }

    /// List containers belonging to `projectName`, optionally filtering to a
    /// subset of services. Stable order: by serviceName ascending, then by
    /// container.id ascending (so scaled replicas group together deterministically).
    ///
    /// - Parameters:
    ///   - runtime:        the runtime to query
    ///   - projectName:    the resolved compose project name
    ///   - serviceFilter:  if non-nil and non-empty, keep only entries whose
    ///                     serviceName is in the set. Empty array == no filter.
    ///   - includeStopped: when false, drop entries whose status != .running
    public static func list(
        runtime: any Runtime,
        projectName: String,
        serviceFilter: [String]? = nil,
        includeStopped: Bool = false
    ) async throws -> [Entry]

    /// Parse a container id of the form "<project>-<service>" or
    /// "<project>-<service>-<N>" into its serviceName component. Returns nil
    /// if the id doesn't carry the project prefix.
    static func parseServiceName(containerId: String, projectName: String) -> String?
}
```

The implementation will:
1. Call `runtime.list(filters: RuntimeListFilters(namePrefix: "\(projectName)-"))` (lets the runtime do the prefix filter — see `RuntimeContainer.swift:114-136`).
2. For each container, call `parseServiceName(containerId:projectName:)`. Drop ids that don't match the prefix.
3. Drop `status != .running` unless `includeStopped`.
4. Apply `serviceFilter` if provided (case-sensitive exact match).
5. Sort by `(serviceName, container.id)`.

### Edited files

**`Sources/Container-Compose/Commands/ComposePort.swift`** (~+80 / -5)

- Make `privatePort: Int?` optional (was `Int`).
- Add `@Flag(name: [.customShort("a"), .customLong("all")]) var all: Bool = false`.
- Add explicit `@Argument` doc note that omitting `<private-port>` triggers the listing path.
- In `run()`:
  - **Listing path** (`privatePort == nil`): query via `ProjectListing.list(...)`, optionally filter to `[service]` if `service` is non-empty, print the `NAME / PORTS` table. If a `<service>` was passed and the result is empty → error `"<service> is not running"`. If no service was passed and the result is empty → error `"no containers running for project <projectName>"`.
  - **Resolver path** (`privatePort != nil`): existing path unchanged. `<service>` becomes required again in this branch.
- Drop the `protocol` filter from the listing path (it only applies to resolver mode). Listing prints all protocols.

**`Sources/Container-Compose/Commands/ComposePs.swift`** (~30 lines changed)

- Replace the inline filter+sort block at L84-L105 with `ProjectListing.list(runtime: runtime, projectName: projectName, serviceFilter: services.isEmpty ? nil : services, includeStopped: all)`.
- Keep the `targetNames` derivation only if it remains needed for explicit `container_name` overrides; otherwise delete (the prefix filter inside `ProjectListing` covers the common case).
- Output format unchanged (NAME / IMAGE / STATUS / PORTS).

**`Sources/Container-Compose/Helper Functions.swift`** (+~15)

- Add `func formatPublishedPorts(_ ports: [RuntimePublishedPort]) -> String` returning the `host:port->cport/proto, ...` joined string (matches the current inline formatting in `ComposePs.swift:131-133`).
- Both `ps` and `port` call it.

### Tests

**New: `Tests/Container-Compose-StaticTests/ProjectListingTests.swift`**

- `parseServiceName` happy paths: `"myproj-redis"` → `"redis"`; `"myproj-redis-2"` → `"redis"` (replica index stripped is left to caller; we keep the suffix in serviceName since compose treats `redis-2` as the replica id, not a different service — clarify in the spec: WE DROP the trailing `-N` numeric replica index. Test both cases.)
- `parseServiceName` rejection: `"otherproj-redis"` against project `"myproj"` returns `nil`.
- `list(...)` with `RecordingContainerClientProvider` fixture: 3 containers across 2 services + 1 from another project. Assert filter, ordering, includeStopped.

**New: `Tests/Container-Compose-StaticTests/RuntimeArgvTests/ComposePortRuntimeTests.swift`**

- Each test installs a recording runtime fixture and asserts stdout.
- Cases:
  - `port` (no args) prints all-services table.
  - `port -a` matches `port` no-args output.
  - `port <service>` filters to that service.
  - `port <service>` with no running container errors with the expected message.
  - `port <service> <private-port>` continues to print bare `host:port` (regression).
  - `port <service> <private-port> --protocol udp` regression.

**Extend: `Tests/Container-Compose-StaticTests/ComposeParsingTests/ComposePortParsingTests.swift`**

- Argument-parsing tests: `--all`, `-a`, missing `<private-port>`, both args, both args + `--protocol`.

**Extend: `Tests/Container-Compose-StaticTests/HelperFunctionsTests.swift`**

- `formatPublishedPorts` happy / empty / multi-port / mixed-proto.

**Touch: existing `ComposePsRuntimeArgvTests.swift` / `ComposePsParsingTests.swift`** — only if the refactor changes observable output (it should not). Run as regression.

## 3. Behavior matrix (precise)

| Invocation                       | Listing? | Resolver? | Output                                            | Exit |
| -------------------------------- | -------- | --------- | ------------------------------------------------- | ---- |
| `port`                           | yes      | no        | NAME/PORTS table, all running services           | 0    |
| `port -a`                        | yes      | no        | NAME/PORTS table, all running services           | 0    |
| `port redis`                     | yes      | no        | NAME/PORTS table, only redis row                 | 0    |
| `port redis` (not running)       | yes      | no        | `Error: redis is not running` to stderr          | 1    |
| `port` (project has no running)  | yes      | no        | `Error: no containers running for project <p>`   | 1    |
| `port redis 6379`                | no       | yes       | `0.0.0.0:16379` (existing behavior)              | 0    |
| `port redis 6379 --protocol udp` | no       | yes       | resolved UDP host:port (existing behavior)       | 0    |
| `port -a redis 6379`             | error    | error     | `--all and <private-port> are mutually exclusive`| 1    |

The last row is an explicit conflict: if `--all` is set AND `privatePort` is provided, fail with that diagnostic. Implemented as a guard at the top of `run()`.

## 4. Test plan

- All new and changed tests live under `Tests/Container-Compose-StaticTests/`. No dynamic tests added (this is a parsing/argv-shape change, not a runtime integration).
- Run with `make test-json` (per repo convention; **never** `--parallel`).
- New tests must pass; pre-existing `ComposePsRuntimeArgvTests` must remain green to prove the `ps` refactor is observably a no-op.

## 5. Out of scope for CHAOS-1440 (filed separately)

- Cross-command short-flag inventory + standardization (e.g., `ps --all` getting `-a`, `run --detach` getting `-d`, `events --json` getting `-j`). Filed as a sibling CHAOS-* ticket; tracked by Team B in parallel.
- Handling `RuntimePublishedPort.count` (port ranges) in the formatter. Existing `ps` doesn't, so `port` won't either; ticket follow-up if needed.
- JSON output mode (`--json`). Possible follow-up; today docker-compose `port` is plain-text only.

## 6. Implementation hand-off

Both Track A (CHAOS-1440) and Track B (sibling) operate in their own git worktrees. Each gets the matching design brief embedded directly in its agent prompt. This document is the user-facing record of intent.
