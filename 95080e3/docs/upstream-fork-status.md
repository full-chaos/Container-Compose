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

## 5.1 Opt-in: `full-chaos/container#dev` for fork-forward features

While the canonical roadmap routes new runtime work to `apple/container`, the
`full-chaos/container` fork carries an active **`dev` branch** with additional
compose-relevant features that have not yet landed upstream. Source-build users
who want fork-forward functionality can swap the pin in `Package.swift`:

```swift
// Default (production-stable):
.package(url: "https://github.com/full-chaos/container", branch: "tier2-fork-patches"),

// Opt-in (fork-forward, requires source build):
.package(url: "https://github.com/full-chaos/container", branch: "dev"),
```

**What `dev` adds vs. `tier2-fork-patches`:**

- All features from §2 above (`ContainerSnapshot.health`, `lastExitCode`,
  `--restart`, `ContainerLogOptions.{since, timestamps}`, `ContainerEvent`
  streaming, `Flags.ProcessBase`).
- **CHAOS-1334 — richer IPAM at network creation time.** Lifts the
  network-level limitations called out in
  [Limitations and Gotchas → Network features](./guides/limitations-and-gotchas.md#network-features).
- Rebased onto newer `apple/containerization` (0.32.x line) plus mainline
  `apple/container` improvements (TOML configuration defaults, CI changes).

**Caveats:**

- **Source build only.** The Homebrew bottle ships against `tier2-fork-patches`.
  To use `dev`, clone the repo, edit `Package.swift`, and `make build && make install`.
- **Not a stability target.** `dev` is the active development branch; expect
  occasional churn. Pin to a specific commit if you need reproducibility.
- **Same end state as `apple/container` upstream.** Every feature on `dev` is
  also tracked as a CHAOS upstream-blocker ticket; using `dev` is a way to
  exercise these features today rather than wait for `apple/container` parity.

Branch reference: <https://github.com/full-chaos/container/tree/dev>

---

## 6. Upstream relationship strategy: small-PR trust-building cadence

The "route to upstream" stance in §3 and §5 is paired with an explicit
cadence discipline: **send small, well-scoped PRs to `apple/container` before
asking for larger features**.

### 6.1 Why small first

- **Don't overburden the maintainers.** Apple's review bandwidth is finite;
  large diffs slow review for everyone.
- **Build trust.** A track record of clean, narrow, easy-to-merge PRs earns
  credibility for landing the bigger asks tracked in §2 (health /
  `lastExitCode` / `--restart` / log filters / `ContainerEvent` streaming /
  `Flags.ProcessBase`) and the deeper requests like network-alias DNS,
  richer IPAM, or Engine-API plumbing.
- **Some refactors belong upstream regardless of trust.** The
  `URL → SystemPackage.FilePath` migration epic (CHAOS-1448 + ~15 sub-issues)
  is foundational filesystem-API hygiene that benefits every downstream of
  `apple/container` / `apple/containerization`, not just compose. Sending it
  upstream is right on its own merits; the trust-building dividend is a side
  benefit.

### 6.2 Pattern examples (good shape)

- [`full-chaos/container#15`](https://github.com/full-chaos/container/pull/15)
  — `feat(network): apply richer IPAM at network creation time` (CHAOS-1334
  staging PR). Tight scope: six previously-dropped network creation options
  on `container network create`.
- [`full-chaos/container#19`](https://github.com/full-chaos/container/pull/19)
  — `fix(network/dns): default-config peer-name DNS resolves` (CHAOS-1478).
  Single-bug fix with two cooperating layers and focused tests.
- The CHAOS-1448 FilePath epic — each sub-issue (CHAOS-1449–1468) is a
  single subsystem conversion (`PluginConfig`, `SnapshotStore`,
  `ContainerResource.Filesystem`, `DirectoryWatcher`, `PacketFilter`, etc.).
  The current "In Review" wave is the live cadence example; do **not** pile
  scope onto these PRs.
- [`docs/upstream-proposals/network-alias-dns.md`](./upstream-proposals/network-alias-dns.md)
  — example of the FR shape used when proposing additive surface changes
  (CHAOS-1476 / Phase 11.1).

### 6.3 What does *not* go upstream

Some work intentionally stays in container-compose because the upstream
conversation has resolved against hosting it:

- **`compose-ingress`** — Traefik-style routing + Docker Engine API surface
  for ecosystem tools. Tracked in
  [CHAOS-1500](https://linear.app/fullchaos/issue/CHAOS-1500); design doc at
  [`docs/initiatives/compose-ingress.md`](./initiatives/compose-ingress.md).
  Lives compose-side because
  [`apple/container#1476`](https://github.com/apple/container/issues/1476)
  was **closed** and
  [`apple/container#239`](https://github.com/apple/container/pull/239) did
  not merge. Long-term direction, per
  [`apple/container#1410`](https://github.com/apple/container/discussions/1410)
  ("Expanding Support for Plugins"): pivot to an `apple/container` plugin
  once plugin architecture matures.

### 6.4 Implication for planning

- The `fork-bound` items in §2 are not abstractly "blocked on upstream" —
  they are **specifically gated on the trust-building track maturing enough
  that bigger asks land cleanly**. Treat them as **strategically** blocked,
  not just technically blocked.
- Forward motion on compose itself uses the local-only backlog (workarounds,
  fixes, parallel build/pull, docker-socket watcher, parser follow-ups,
  embedded sidecars). These don't need any upstream cooperation and should
  ship on their own cadence.
- When triaging a new gap, ask first: _does this need `apple/container`?_
  If yes, is it a small-shape PR or a large-shape ask? Small ones can ship
  now via `full-chaos/container` staging; large ones queue behind the
  ongoing cadence.

---

## 7. References

- Canonical parity inventory: [`docs/feature-parity.md`](./feature-parity.md)
- Agent orientation / dependency note: [`AGENTS.md`](../AGENTS.md)
- Initiative docs: [`docs/initiatives/`](./initiatives/)
- Canonical upstream: <https://github.com/apple/container>
- Frozen fork (compatibility pin only): <https://github.com/full-chaos/container>
