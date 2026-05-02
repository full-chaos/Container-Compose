# Apple/container upstream staging — handoff

> **Status:** active — six tier2-fork-patches features now have dedicated branches; CHAOS-1334 + CHAOS-1381 remain.
> **Author:** Sisyphus (session handoff to next agent)
> **Date:** 2026-05-02
> **Audience:** the next agent picking up CHAOS-1334 + CHAOS-1381 work
> **Companion docs:** [`feature-parity.md`](../feature-parity.md) (canonical inventory), [`upstream-fork-status.md`](../upstream-fork-status.md), [`AGENTS.md`](../../AGENTS.md) §6

---

## TL;DR

Six features in [tier2-fork-patches commit `602efdc`](https://github.com/full-chaos/container/commit/602efdc) — the bundled fork-only patches container-compose was pinning — have been **un-bundled into dedicated branches** and pushed as drafts. Two upstream-shaped (apple/container) drafts are also live (CHAOS-1319, CHAOS-1320). One ticket (CHAOS-1335) was audited and confirmed already-shipped on `main` under CHAOS-1368.

Two substantial pieces remain, each requiring a dedicated session:
- **CHAOS-1334** — Network IPAM extensions, full plugin-honoring impl
- **CHAOS-1381** — Healthcheck observer, full implementation

Both involve `apple/container` daemon-side runtime changes (network plugin protocol; sandbox-side exec + observer state machine) that are too big to land alongside other work.

---

## Standing inventory

### Has dedicated PR / shipped

| Ticket | Where | Pattern |
| :--- | :--- | :--- |
| CHAOS-1319 | [apple/container#1504](https://github.com/apple/container/pull/1504) | Upstream draft, data-shape only |
| CHAOS-1320 | [apple/container#1503](https://github.com/apple/container/pull/1503) | Upstream draft, full impl |
| CHAOS-1321 | [full-chaos#13](https://github.com/full-chaos/container/pull/13) | Fork-main draft, data-shape + CLI |
| CHAOS-1322 | [full-chaos#11](https://github.com/full-chaos/container/pull/11) | Fork-main draft, full impl |
| CHAOS-1323 | [full-chaos#14](https://github.com/full-chaos/container/pull/14) | Fork-main draft, full impl |
| CHAOS-1324 | [full-chaos#12](https://github.com/full-chaos/container/pull/12) | Fork-main draft, additive only |
| CHAOS-1335 | already on `main` (PR [#85](https://github.com/full-chaos/container-compose/pull/85) / commit `145fac8`) | Done — Linear flipped |

### Net-new work, no impl yet

| Ticket | Title | Effort |
| :--- | :--- | :--- |
| **CHAOS-1334** | Network IPAM extensions (full plugin-honoring) | medium-large |
| **CHAOS-1381** | Healthcheck observer (full impl) | large; pairs with already-staged CHAOS-1319 |
| CHAOS-1336 | `deploy.resources.reservations` runtime | hybrid (compose + upstream) |
| CHAOS-1337 | `container build --allow` (entitlements) | medium-large, BuildKit-equivalent |
| CHAOS-1379 | `--gpus` GPU passthrough | large, specialized (Hypervisor.framework) |
| CHAOS-1380 | `--blkio-*` / cgroup BFQ tuning | medium, specialized |
| CHAOS-1382 | File-level bind mounts on `container run -v` | large, virt-stack work |
| CHAOS-1383 | Lifecycle hooks (`post_start` / `pre_stop`) | medium-large |
| CHAOS-1384 | Template-driver engine for configs/secrets | medium, niche |

---

## Next steps in priority order

### Step 1 — Set up your context (~5 min)

1. `cd /Users/chris/projects/full-chaos/container/container-compose`
2. Read [`docs/feature-parity.md`](../feature-parity.md) (canonical inventory) + [`AGENTS.md`](../../AGENTS.md) §6 + [`docs/upstream-fork-status.md`](../upstream-fork-status.md)
3. **Load the `linear` skill BEFORE any Linear command** (`--state`, not `--status`)
4. Skim the most recent fork-main draft PRs as templates: [#11](https://github.com/full-chaos/container/pull/11), [#12](https://github.com/full-chaos/container/pull/12), [#13](https://github.com/full-chaos/container/pull/13), [#14](https://github.com/full-chaos/container/pull/14)

### Step 2 — CHAOS-1334 (full plugin-honoring Network IPAM)

**Investigate before implementing:**

- Read `container-network-vmnet` plugin protocol surface (see `Sources/ContainerNetworkVMNet/` and `Sources/ContainerNetworkPluginAPI/`)
- Determine which IPAM fields the plugin can actually honor today vs. needs new wiring:
  - `gateway`
  - `ipRange`
  - `auxAddresses`
  - `driverOpts`
  - `attachable`
  - `enableIPv6`
- Existing surface: `Sources/ContainerResource/Network/NetworkConfiguration.swift` (6 current fields), `Sources/ContainerCommands/Network/NetworkCreate.swift` (6 current flags: `--label`, `--internal`, `--subnet`, `--subnet-v6`, `--plugin`, `--plugin-variant`)

**Implementation pattern:**

- New worktree: `/Users/chris/projects/full-chaos/container/container/.worktress/chaos-1334-network-ipam` from `main`
- Branch: `feat/chaos-1334-network-ipam`
- Draft PR to `full-chaos:main` (NOT `apple/container:main`)

**Likely file surface:**

- `Sources/ContainerResource/Network/NetworkConfiguration.swift` — add new fields (data shape)
- `Sources/ContainerCommands/Network/NetworkCreate.swift` — add CLI flags
- `Sources/ContainerNetworkPluginAPI/...` — protocol additions if plugin needs to receive new opts
- `Sources/ContainerNetworkVMNet/...` — plugin impl honoring new opts (where vmnet supports them)

### Step 3 — CHAOS-1381 (full healthcheck observer)

**Consult Oracle FIRST** (~30-min pass) on observer design tradeoffs before writing code:

- Where does the observer task live? Per-container actor, global pool, or sandbox-side?
- Probe execution: via `SandboxClient.exec`, new `ExecProbe` type, or runtime VM-side?
- State machine: `starting` → `running` → `healthy` / `unhealthy`, with `start_period` grace window + retry counting against the configured `retries` threshold
- Integration points: hook into create lifecycle (start observer when container reaches `.running`), shut down on stop/destroy
- How does `ContainerSnapshot.health` get updated atomically from the observer back to the snapshot? `ContainersService` actor mutation, or a separate `HealthObserver` actor that messages back?

**Pairs with already-staged CHAOS-1319** ([apple/container#1504](https://github.com/apple/container/pull/1504)) — together they close the loop for compose `depends_on.condition: service_healthy`.

**Implementation surface (after Oracle consult):**

- New `Healthcheck` struct in `Sources/ContainerResource/Container/`
  - Fields: `test: [String]`, `interval: TimeInterval`, `timeout: TimeInterval`, `retries: Int`, `startPeriod: TimeInterval?`, `startInterval: TimeInterval?`, `disable: Bool?`
  - Compose-spec mapping reference: container-compose's [`Healthcheck.swift`](../../Sources/Container-Compose/Codable%20Structs/Healthcheck.swift)
- New `healthcheck: Healthcheck?` field on `Sources/ContainerResource/Container/ContainerCreateOptions.swift`
- New CLI flags on `Flags.Management`:
  - `--health-cmd`
  - `--health-interval`
  - `--health-timeout`
  - `--health-retries`
  - `--health-start-period`
  - `--health-start-interval`
  - `--no-healthcheck` (disable)
- Observer task wired into `ContainersService` lifecycle methods
  - Start observer in `handleStart` when container reaches `.running` AND has a healthcheck spec
  - Tear down in `handleStop` / `handleDelete`
- Snapshot update path — the observer needs a way to atomically update `state.snapshot.health` (which CHAOS-1319 just reserved)

**Worktree:** `.worktress/chaos-1381-healthcheck-observer`, branch `feat/chaos-1381-healthcheck-observer`, draft PR to `full-chaos:main`.

---

## Conventions (non-negotiable)

| Convention | Detail |
| :--- | :--- |
| **Workflow** | Stage in `full-chaos/container:main` FIRST. NEVER open at `apple/container` until user reviews the fork-main staging PR. |
| **Worktrees** | `.worktress/<chaos-NNNN-slug>` (typo intentional, matches existing pattern) |
| **Branch names** | `feat/chaos-NNNN-slug` |
| **PR base** | `full-chaos:main` for new work; `apple/container:main` only after user reviews + approves the upstream mirror |
| **PR state** | Always `--draft` for staging |
| **Authoring** | Fresh implementation against `main`, NOT cherry-pick from `tier2-fork-patches` commit `602efdc` |
| **Comment hook** | Pre-justify license headers (repo convention) and public-API docstrings (necessary for non-obvious semantics) — the hook fires on every doc/comment edit. Apple's source convention: every file gets the `//===---===//` Apache 2.0 banner; every public type/method/case gets a `///` docstring documenting non-obvious semantics. |
| **Git env** | Always set `GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat` to avoid hangs in non-TTY shells |
| **Linear** | `--state` flag (not `--status`); load `linear` skill before commands. Common pattern: `linear i update CHAOS-NNNN --state Done` |
| **Verification** | Full `swift build` clean (release config, all targets) before push; document known limitations in PR body |
| **File links** | Use `[text](file:///abs/path)` format when referencing files in agent output — never raw paths in prose |

---

## Things explicitly NOT to do

- **Do not** add to or modify `tier2-fork-patches` branch (frozen — no new patches)
- **Do not** open PRs at `apple/container` without user review of the fork-main staging PR first
- **Do not** cherry-pick from commit `602efdc` — implement fresh against `main`. The fork's commit is reference-only
- **Do not** use `background_cancel(all=true)` — cancel individual task IDs only
- **Do not** delete failing tests, suppress types (`as any`, `@ts-ignore`, `@unchecked`), or add no-op error handlers
- **Do not** commit changes unless explicitly asked

---

## Reference: pattern from completed work

For each of the six completed branches (CHAOS-1319 through CHAOS-1324), the pattern was:

1. Create dedicated worktree from `main`
2. Implement minimal data-shape (or scoped functional) surface
3. Build clean (`swift build`)
4. Commit with detailed body documenting motivation, scope, wire compatibility, known limitations
5. Push to `origin` (= `full-chaos/container`)
6. Open draft PR via `gh pr create --repo full-chaos/container --base main --head feat/chaos-NNNN-... --draft`
7. (Optionally) Mirror to `apple/container` upstream as companion-issue + draft-PR pair (only done for CHAOS-1319 / CHAOS-1320 in this session)
8. Linear comment via `linear i comment CHAOS-NNNN --body "..."` documenting the PR + scope decision

The commit message bodies on these PRs are templates — reference them when authoring CHAOS-1334 / CHAOS-1381 commits.

---

## Open the new session with

> "Continue from `docs/plans/apple-container-upstream-handoff.md`. Start with CHAOS-1334 — investigate `container-network-vmnet` plugin protocol before writing code. After CHAOS-1334 is staged, move to CHAOS-1381 with an Oracle consult on observer design first."

---

## Why this handoff exists

The previous session (2026-05-02) burned through context budget tackling the six tier2-fork-patches features end-to-end, then ran into the much-larger CHAOS-1334 / CHAOS-1381 surface area. Rather than rush either of those, we deferred them with this handoff so the next agent gets a fresh budget per ticket and can do the runtime/plugin/observer design work properly.

The user's explicit guidance for the deferred tickets:
- **CHAOS-1334**: Full plugin-honoring impl (NOT data-shape only). Plugin must actually honor the new options at network creation.
- **CHAOS-1381**: Full observer wiring (NOT data-shape only). Spec + flags + observer task that execs probes and updates `ContainerSnapshot.health`.

Both are deliberately big asks — taking shortcuts here would just produce another round of "data-shape only" PRs that don't actually move the user-visible behavior. Spend the budget; do them right.
