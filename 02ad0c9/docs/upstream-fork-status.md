# Upstream / Fork Status

> **See also:** [`docs/feature-parity.md`](./feature-parity.md) — the
> canonical cross-cutting view of compose-spec gaps, Tier 0-5 classification,
> ticket map, and verified `apple/container` CLI surface.

This document records the current dependency reality for container-compose:

- **`apple/container` is the only canonical remote.**
- **`full-chaos/container` is frozen.** No new patches will be added.
- **`Package.swift` stays pinned to the fork for transitional compatibility only.**

Going forward, if container-compose hits a runtime gap, the work item belongs in
the upstream `apple/container` queue (or the corresponding internal blocker
ticket that tracks upstream advocacy). Do **not** open or plan new fork-patch
work.

---

## 1. Current reality

container-compose still builds against `full-chaos/container`, but that pin is
now a compatibility bridge, not an active development target. The fork remains
in the dependency graph because it still carries runtime surface container-compose
uses today, plus macro compatibility the project has not yet unwound.

That means two truths coexist:

1. **Users on today's fork-pinned dependency keep the behavior below right now.**
2. **From planning / ticketing / roadmap perspective, every one of these gaps is blocked on upstream `apple/container`.**

---

## 2. Fork-only features still present today

The fork still carries the six compose-relevant additions that container-compose
uses today. These remain available to current users, but none count as
canonical, done upstream work anymore.

| Feature still present via fork | Container-compose consumer | Linear status |
| --- | --- | --- |
| `ContainerSnapshot.health` / `HealthStatus` | `Compose+Wait.swift` (`depends_on.condition: service_healthy`) | CHAOS-1319 — fork-only today; blocked on upstream |
| `ContainerSnapshot.lastExitCode` | `Compose+Wait.swift` (`service_completed_successfully`) | CHAOS-1320 — fork-only today; blocked on upstream |
| `--restart` on `container run` | `Compose+ArgsLifecycle.swift` (`service.restart`) | CHAOS-1321 — fork-only today; blocked on upstream |
| `ContainerLogOptions.since` / `.timestamps` | `ComposeLogs.swift` | CHAOS-1322 — fork-only today; blocked on upstream |
| `ContainerEvent` streaming API | `ComposeEvents.swift` | CHAOS-1323 — fork-only today; blocked on upstream |
| `Flags.ProcessBase` support used by compose `run` / `exec` | `ComposeRun.swift`, `ComposeExec.swift` | CHAOS-1324 — fork-only today; blocked on upstream |

**Policy:** keep these working for the current pin, but treat the associated
issues as reopened / blocked-on-upstream until `apple/container` exposes
equivalent support.

---

## 3. What this means for new work

### 3.1 Former “Tier 2” items

The old “fork-patch path” bucket is deprecated. Historical fork-oriented tickets
now translate to one of two states:

- **Wireable in container-compose today** if upstream already has the needed
  surface (example: parts of the named-volume work need verification, not a fork).
- **Blocked on upstream `apple/container`** if the runtime / CLI surface is still
  missing (example: network IPAM expansion, restart policy parity, health / event
  APIs, extra container flags).

### 3.2 Ticketing rule

When you find a gap, file or update the relevant upstream-tracking issue in the
CHAOS backlog (for example the CHAOS-1378 family). Do **not** create new
“patch the fork” implementation tickets.

---

## 4. Transitional compatibility items that still exist

These are not invitations for new fork work; they are reasons the dependency pin
cannot be removed yet.

| Item | File | Why it still matters |
| --- | --- | --- |
| `@OptionGroupPassthrough` macro shim for `Flags.Logging` | `Sources/Container-Compose/Commands/Compose+FlagsLoggingPassthrough.swift` | Keeps container-compose compiling against today's dependency surface |
| `Flags.ProcessBase` passthrough shim | `Sources/Container-Compose/Commands/Compose+FlagsProcessBasePassthrough.swift` | Bridges fork-only process flag surface still consumed by compose `run` / `exec` |

These are compatibility shims, not active fork feature work.

---

## 5. Recommended direction

1. **Keep `Package.swift` pinned as-is for now.**
2. **Route all new runtime gap work to `apple/container` upstream.**
3. **Use Linear comments/states to mark fork-only behavior as non-canonical.**
4. **Replan old fork-path tickets as upstream blockers or container-compose-only
   wireups, depending on what the verified upstream CLI already supports.**

---

## 6. References

- Canonical parity inventory: [`docs/feature-parity.md`](./feature-parity.md)
- Agent orientation / dependency note: [`AGENTS.md`](../AGENTS.md)
- Canonical upstream: <https://github.com/apple/container>
- Frozen fork (compatibility pin only): <https://github.com/full-chaos/container>
