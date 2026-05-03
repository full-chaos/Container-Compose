# Feature Parity Inventory — Container-Compose ↔ apple/container

> **Audit date:** 2026-05-01
> **Author:** Sisyphus (audit + synthesis)
> **Scope:** Compose-spec coverage in Container-Compose vs. CLI / runtime surface of `apple/container`
> **Method:** Six parallel scouts across `coverage.html`, source-code gap markers, argv emission, doc inventory, apple/container source, and CLI doc standards
> **Status:** Canonical companion to [`coverage.html`](../coverage.html) (data) and [`upstream-fork-status.md`](./upstream-fork-status.md) (fork dependencies)

---

## 1. TL;DR

| Tier | Count | Description | Action |
| :--- | :---: | :--- | :--- |
| **Tier 0 — Silent failure** | **~22 flags** | Container-Compose unconditionally emits flags `apple/container` does NOT accept. Setting these compose fields produces `unknown option` runtime errors. | **Fix in Container-Compose** (Tier 0 cleanup, file new tickets) |
| **Tier 1 — Wireable now** | 6 fields | Runtime support exists; we just haven't wired or enforced. | **Fix in Container-Compose** (existing or new tickets) |
| **Tier 2 — Fork-patch path (deprecated)** | 0 active / 7 historical | Historical bucket only. The fork is frozen, so no new work should target it. | **Do not patch the fork** |
| **Tier 3 — Upstream PR / FR** | 19 features | Need apple/container engineering, including the items previously parked in Tier 2. | **File FR upstream** |
| **Tier 4 — Won't do** | 21 fields | Deprecated, Swarm-only, or platform-specific (Windows/Linux cgroups). | Decoded → warn-skipped → `coverage.html` `miss` |
| **Tier 5 — Frontier** | 3 fields | AI/LLM provisioning — spec still evolving. | Track only |

**Critical finding:** Tier 0 is the biggest discovery of this audit. `--ipc`, `--pid`, `--uts`, `--device`, `--userns`, `--security-opt`, all `--blkio-*`, `--shm-size`, `--pids-limit`, `--memory-reservation`, `--memory-swap`, `--memory-swappiness`, `--cpu-shares`, `--cpuset-cpus`, `--cpu-period`, `--cpu-quota`, `--cpu-rt-period`, `--cpu-rt-runtime`, `--cpu-count`, `--cpu-percent`, `--oom-kill-disable`, `--oom-score-adj`, `--sysctl`, `--ip`, `--ip6`, `--gpus`, `--mac-address` are all emitted by Container-Compose but have **no entry** in upstream `apple/container`'s `Flags.Management` / `Flags.Resource` (verified by cloning `apple/container@main` 2026-05-01 and grepping). The runtime will reject these flags. CHAOS-1329 (logging), CHAOS-1330 (extra_hosts), CHAOS-1331 (aliases) already followed this remediation pattern; the same remediation is needed for the 22 flags above.

**Fork-dependency note:** container-compose currently builds against `full-chaos/container` (branch `tier2-fork-patches`), which still carries 6 compose-relevant patches not in upstream `apple/container`. Those features work today for fork-pinned users, but the fork is frozen and is no longer a valid implementation path for new work. From a planning perspective, those gaps are now blocked on upstream `apple/container`. Named volumes are a separate nuanced gap with their own dedicated section — see [Appendix B (§13)](#13-appendix-b--named-volumes-deep-dive).

---

## 2. Methodology

### 2.1 Sources cross-referenced

1. **[`coverage.html`](../coverage.html)** — canonical compose-spec coverage matrix (62 partials, 16 misses out of 197 fields after CHAOS-1384). Inline JSON `<script id="coverage-data">` block.
2. **In-code gap markers** — every `#warning(...)`, `print("Note: ... is not supported by Apple container; ignored.")`, `"Detected, But Not Supported"`, and `// Phase N TODO` in `Sources/Container-Compose/`.
3. **Argv emission** — every `args.append("--flag", ...)` in `Sources/Container-Compose/Commands/Compose+Args*.swift` and `Compose<Name>.swift`. Mapped to the apple/container subcommand (`run`, `build`, `network create`, `volume create`, `exec`, etc.) it targets.
4. **apple/container CLI surface** — read directly from `.build/checkouts/container/Sources/Services/ContainerAPIService/Client/Flags.swift` (canonical `Flags.Management`/`Flags.Process`/`Flags.Resource`/`Flags.DNS` definitions) and `.build/checkouts/container/Sources/ContainerCommands/Container/{ContainerRun,ContainerCreate,ContainerExec}.swift` and `.build/checkouts/container/Sources/ContainerCommands/Network/NetworkCreate.swift`.
5. **Linear** — existing CHAOS issues (Done + Backlog) so we don't duplicate.
6. **`upstream-fork-status.md`** — prior cataloguing of fork dependencies; reconciled into Tier 2 / Tier 3 below.

### 2.2 What "supported by apple/container" means

A flag is "supported" if it appears as an `@Option`/`@Flag` declaration in either:
- `Flags.Management`, `Flags.Process`, `Flags.Resource`, `Flags.DNS`, `Flags.ProcessBase`, `Flags.Logging`, `Flags.Registry`, `Flags.Progress`, `Flags.ImageFetch` (under `.build/checkouts/container/Sources/Services/ContainerAPIService/Client/Flags.swift`), OR
- A subcommand-local declaration in `.build/checkouts/container/Sources/ContainerCommands/...` (e.g., `NetworkCreate.swift` declares `--subnet`, `--internal`, `--plugin`).

Anything else passed to `container <subcommand>` will fail argument parsing with `Error: unknown option <flag>`.

---

## 3. Tier 0 — Silent Failure (HIGH PRIORITY)

These are flags Container-Compose **emits unconditionally** when the corresponding compose field is set, but `apple/container` rejects them. Each is a real bug — the user's `container-compose up` will fail at runtime with `Error: unknown option --<flag>`. Pattern matches the already-remediated CHAOS-1329 (`--log-driver`), CHAOS-1330 (`--add-host`), CHAOS-1331 (`--alias`).

**Remediation pattern:** stop emitting the flag; emit a `print("Note: '<field>' is parsed but not supported by Apple container; ignored.")` instead. Coverage row stays `partial` (decoded but not wired).

### 3.1 Container runtime flags (target: `container run` / `container create`)

| Compose field | Currently emitted as | apple/container support? | Container-Compose source | Linear |
| :--- | :--- | :--- | :--- | :--- |
| `service.security_opt` | `--security-opt` | ❌ no `Flags.Management.securityOpt` | `Compose+ArgsSecurity.swift:40-42` | CHAOS-1371 |
| `service.userns_mode` | `--userns` | ❌ | `Compose+ArgsSecurity.swift:43-45` | CHAOS-1371 |
| `service.ipc` | `--ipc` | ❌ | `Compose+ArgsNetworking.swift:134-137` | CHAOS-1372 |
| `service.pid` | `--pid` | ❌ | `Compose+ArgsNetworking.swift:140-143` | CHAOS-1372 |
| `service.uts` | `--uts` | ❌ | `Compose+ArgsNetworking.swift:146-149` | CHAOS-1372 |
| `service.devices` | `--device` (per device) | ❌ | `Compose+ArgsStorage.swift:52-56` | CHAOS-1373 |
| `service.sysctls` | `--sysctl KEY=VALUE` | ❌ | `Compose+ArgsStorage.swift:45-49` | CHAOS-1373 |
| `service.networks.<n>.ipv4_address` | `--ip` | ❌ (only via `--network <name>,mac=...,mtu=...`; no `--ip` standalone) | `Compose+ArgsNetworking.swift:54-56` | CHAOS-1374 |
| `service.networks.<n>.ipv6_address` | `--ip6` | ❌ | `Compose+ArgsNetworking.swift:60-62` | CHAOS-1374 |
| `service.mac_address` | `--mac-address` | ❌ standalone (only within `--network <name>,mac=...`) | `Compose+ArgsNetworking.swift:124` | CHAOS-1374 |
| `service.deploy.resources.limits.pids` / `service.pids_limit` | `--pids-limit` | ❌ | `Compose+ArgsResource.swift:60-63` | CHAOS-1375 |
| `service.shm_size` | `--shm-size` | ❌ | `Compose+ArgsResource.swift:66-68` | CHAOS-1375 |
| `service.mem_reservation` / `deploy.resources.reservations.memory` | `--memory-reservation` | ❌ | `Compose+ArgsResource.swift:46-48` | CHAOS-1375 |
| `service.mem_swappiness` | `--memory-swappiness` | ❌ | `Compose+ArgsResource.swift:51-53` | CHAOS-1375 |
| `service.memswap_limit` | `--memory-swap` | ❌ | `Compose+ArgsResource.swift:56-58` | CHAOS-1375 |
| `service.cpu_shares` | `--cpu-shares` | ❌ (only `--cpus` exists) | `Compose+ArgsResource.swift:81-83` | CHAOS-1375 |
| `service.cpuset` | `--cpuset-cpus` | ❌ | `Compose+ArgsResource.swift:86-88` | CHAOS-1375 |
| `service.cpu_period` | `--cpu-period` | ❌ | `Compose+ArgsResource.swift:91-93` | CHAOS-1375 |
| `service.cpu_quota` | `--cpu-quota` | ❌ | `Compose+ArgsResource.swift:96-98` | CHAOS-1375 |
| `service.cpu_rt_period` | `--cpu-rt-period` | ❌ | `Compose+ArgsResource.swift:101-103` | CHAOS-1375 |
| `service.cpu_rt_runtime` | `--cpu-rt-runtime` | ❌ | `Compose+ArgsResource.swift:106-108` | CHAOS-1375 |
| `service.cpu_count` | `--cpu-count` | ❌ | `Compose+ArgsResource.swift:111-113` | CHAOS-1375 |
| `service.cpu_percent` | `--cpu-percent` | ❌ | `Compose+ArgsResource.swift:116-118` | CHAOS-1375 |
| `service.oom_kill_disable` | `--oom-kill-disable` | ❌ | `Compose+ArgsResource.swift:71-73` | CHAOS-1375 |
| `service.oom_score_adj` | `--oom-score-adj` | ❌ | `Compose+ArgsResource.swift:76-78` | CHAOS-1375 |
| `service.gpus` | `--gpus all` / `--gpus count=N,...` | ❌ (code already prints `Note: ... may reject this flag.` — convert to skip-emit) | `Compose+ArgsResource.swift:131-150` | CHAOS-1376 |
| `service.blkio_config` | `--blkio-weight`, `--blkio-weight-device`, `--device-read-bps`, `--device-write-bps`, `--device-read-iops`, `--device-write-iops` | ❌ (code already warns; convert to skip-emit) | `Compose+ArgsResource.swift:152-173` | CHAOS-1376 |

**Remediation effort:** Same shape as CHAOS-1329/1330/1331 — wrap each emission in a guard, replace with a `print(...)` warning, update tests. Each field = small isolated PR. Estimated 4-8 hours total for all 22+ remediations if batched into one Tier-0 sweep.

### 3.2 Network create flags (target: `container network create`)

These are NOT directly emitted today — Container-Compose's `ComposeUp.swift` already warn-skips most of them — but some have ambiguous code paths worth a Tier-0 audit:

| Compose field | Status | Linear |
| :--- | :--- | :--- |
| `networks.<n>.driver_opts` | warn-skip ✅ | CHAOS-1334 (open) |
| `networks.<n>.attachable` | warn-skip ✅ | CHAOS-1334 (open) |
| `networks.<n>.enable_ipv6` (bare) | warn-skip ✅ | CHAOS-1334 (open) |
| `networks.<n>.internal` | emitted as `--internal` ✅ (supported by `NetworkCreate`) | — |
| `networks.<n>.ipam.config.ip_range` / `gateway` / `aux_addresses` | warn-skip ✅ | CHAOS-1334 (open) |

No Tier 0 work here — already correctly warn-skipped.

### 3.3 Build flags (target: `container build`)

Not yet audited line-by-line as part of this scout. The argv-builder scout extracted what we emit:
- `--build-arg`, `--file`, `--tag`, `--no-cache`, `--target`, `--cache-from`, `--cache-to`, `--label`, `--network`, `--secret`, `--ssh`, `--os`, `--arch`, `--shm-size`, `--cpus`, `--memory`

Cross-check against `.build/checkouts/container/Sources/ContainerCommands/BuildCommand.swift` is recommended as a follow-up before the Tier 0 sweep ships. **Filed as part of NEW Tier 0 ticket.**

---

## 4. Tier 1 — Wireable Now (we can do this)

Runtime support exists; we just need to wire it.

| # | Compose field | Coverage status | What's needed | Existing Linear |
| :-: | :--- | :--- | :--- | :--- |
| 1 | `service.healthcheck.*` enforcement (test/interval/timeout/retries/start_period/start_interval/disable) | partial (decoded only) | Wire `Compose+Wait.waitForCondition(.serviceHealthy)` to actually drive the runtime healthcheck. Healthchecks are currently never executed; only `depends_on.condition: service_healthy` reads `ContainerSnapshot.health` (already shipped via CHAOS-1319). The healthcheck **subprocess loop** must run. | Likely needs apple/container support too (no `--health-cmd` flag in upstream) — see Tier 2/3 |
| 2 | `service.deploy.resources.reservations.cpus` | partial (degraded mapping; CHAOS-1336) | **Shipped** as a degraded compose-side fallback in [`Compose+ArgsResource.swift`](../Sources/Container-Compose/Commands/Compose+ArgsResource.swift). Reservation maps onto `--cpus` as a fixed VM allocation when no limit is set; warns the user that Docker-style soft reservation semantics are not honored. Oracle determined upstream `--cpu-reservation` flags would be misleading in apple/container's VM-per-container model (no inter-container contention inside a dedicated VM). | CHAOS-1336 (resolved compose-side) |
| 3 | `service.deploy.resources.reservations.memory` | partial (degraded mapping; CHAOS-1336) | Same as #2 — reservation maps onto `--memory` as a fixed VM allocation when no `mem_limit` / `deploy.limits.memory` is set; warns about degraded semantics. Top-level `mem_reservation` follows the same fallback path. When both limit and reservation are present, the limit wins and an ignored-reservation warning fires. | CHAOS-1336 (resolved compose-side) |
| 4 | `top.volumes` named volume runtime CRUD (replace hardlink-dir fallback) | partial | Phase 0 source audit is GREEN: `container run -v <name>:<path>` is parsed as a named volume when `<name>` has no `/`, then resolved through `ClientVolume.create/inspect` before the container starts. Container-Compose can therefore create real local volumes and pass the volume name directly at runtime. Non-`local` drivers still fall back to the legacy hardlink path. See [Appendix B (§13)](#13-appendix-b--named-volumes-deep-dive). | CHAOS-1368 (open), CHAOS-1335 (open) |
| 5 | `service.provider` | partial (warn-skipped) | Provider lifecycle wiring is implementation, not runtime — could be done without apple/container changes if model-provisioning is intentionally Container-Compose-side. Frontier feature though — verify spec stability before commit. | CHAOS-1332 (open) |
| 6 | Build/Up `pullImage` consolidation | refactor | `ComposeRun.swift:352` has a private `pullImage` while `Compose+Pull.swift:19` has the shared helper. Already noted as R1 in `docs/plans/no-upstream-refactor-and-linear.md`. | tracked in plan, not Linear-ticketed |

**CHAOS-1384 update:** `configs.template_driver` and `secrets.template_driver` are now compose-side `partial`, not upstream-blocked: `template_driver: golang` is rendered host-side before the config/secret is materialized as a bind-mounted temp file; `template_driver: file` remains the raw/no-op default; unknown drivers warn once and fall back to raw content. Full Go `text/template` control flow/custom functions remain out of scope.

---

## 5. Tier 2 — Fork-patch path (deprecated)

### 5.1 Already shipped via fork (production today)
These features still work today only because container-compose remains pinned to the frozen fork. They are **not** valid new-work targets anymore; each is now effectively blocked on upstream `apple/container` landing equivalent support.

| Fork addition | Compose surface that depends on it | Linear |
| :--- | :--- | :--- |
| `--restart` flag on `container run` | `service.restart: always\|on-failure\|unless-stopped\|no` — emitted at `Compose+ArgsLifecycle.swift:64-66` | CHAOS-1321 (fork-only; blocked on upstream) |
| `ContainerSnapshot.health: HealthStatus?` | `depends_on.condition: service_healthy` blocking via `Compose+Wait.swift` | CHAOS-1319 (fork-only; blocked on upstream) |
| `ContainerSnapshot.lastExitCode: Int32?` | `depends_on.condition: service_completed_successfully` exit-code verification | CHAOS-1320 (fork-only; blocked on upstream) |
| `ContainerLogOptions.{since, timestamps}` | `compose logs --since` / `--timestamps` flags | CHAOS-1322 (fork-only; blocked on upstream) |
| `ContainerEvent` + `events()` streaming API | `compose events` native streaming | CHAOS-1323 (fork-only; blocked on upstream) |
| `Flags.ProcessBase` | `compose run/exec` standard `-e/-u/-w/-d` short flags | CHAOS-1324 (fork-only; blocked on upstream) |

**Current policy:** keep the fork pin for compatibility only; do not add to this list. Tracked at `docs/upstream-fork-status.md`.

### 5.2 Could-add-to-fork (not yet shipped)
This subsection is retained only as historical context. **Do not implement any of these in the fork.** Every item below now belongs to the upstream FR / advocacy queue.

| # | Feature | Why it is now upstream-blocked | Existing Linear |
| :-: | :--- | :--- | :--- |
| 1 | `--ipc / --pid / --uts` namespace mode flags | Needs canonical `apple/container` CLI/runtime surface | sub-issue of Tier 0 sweep (CHAOS-1372) |
| 2 | `--security-opt` | Needs canonical `apple/container` CLI/runtime surface | CHAOS-1371 |
| 3 | `--device` (file passthrough) | Needs canonical `apple/container` CLI/runtime surface | CHAOS-1373 |
| 4 | `--userns` | Needs canonical `apple/container` CLI/runtime surface | CHAOS-1371 |
| 5 | `--memory-reservation`, `--memory-swap`, `--memory-swappiness`, `--pids-limit`, `--shm-size`, `--cpu-shares`, `--cpuset-cpus`, `--cpu-period`/`-quota`/`-rt-*`/`-count`/`-percent`, `--oom-*` | Needs canonical `apple/container` CLI/runtime surface | CHAOS-1375 |
| 6 | Network IPAM extensions (`--driver-opts`, `--attachable`, `--ipv6` bare, `--ip-range`, `--gateway`, `--aux-addresses`, `--ipam-driver`/`--ipam-opt`) | Needs `apple/container network create` to grow equivalent options | CHAOS-1334 (open) |
| 7 | `--add-host`, `--alias`, `--log-driver`/`--log-opt` | Needs canonical `apple/container` CLI/runtime surface if reintroduced | tracked in upstream-fork-status.md |

**Replacement policy:** file or update upstream FRs against `apple/container`, then keep container-compose in warn-skip / blocked state until upstream lands.

---

## 6. Tier 3 — Upstream FR (file against `apple/container`)

These need real apple/container engineering and likely virtualization-stack changes. Tracked here for outside-in advocacy.

| # | Feature | Why upstream | Existing Linear |
| :-: | :--- | :--- | :--- |
| 1 | File-level bind mounts (single file, not just directory) | Apple `container -v` mounts directories only | upstream-fork-status.md §2.B |
| 2 | Volume driver plugin system | `container volume create --opt` exists but only `local`-style options | CHAOS-1335 (open) |
| 3 | Anonymous volume lifecycle API | `ContainerClient` lacks volume RM hooks | upstream-fork-status.md §2.B |
| 4 | `--gpus` (GPU passthrough) | Requires Hypervisor passthrough work | NEW (FR) |
| 5 | `--blkio-*` / cgroup BFQ tuning | Linux cgroup-v2 surface; not exposed | NEW (FR) |
| 6 | Lifecycle hooks (`post_start` / `pre_stop`) | Need `ContainerClient` lifecycle hook API | upstream-fork-status.md §2.C |
| 7 | `build.entitlements` / `--allow` | `container build` has no entitlement / `--allow` flag | CHAOS-1337 (open) |
| 8 | `--log-driver` / `--log-opt` | Apple container log layout is fixed | upstream-fork-status.md §2.C |
| 9 | `--health-cmd`, `--health-interval`, etc. (CLI form) | Currently health is read via `ContainerSnapshot.health` (CHAOS-1319) but `container run` has no health-cmd flag | NEW (FR) |
| 10 | Per-container log file layout (signoz / alloy compatibility) | `/var/lib/docker/containers/*-json.log` equivalent | upstream-fork-status.md §2.F (no ticket yet) |
| 11 | `container create` (true create-without-start) | Container-Compose probes for support; today shells out to `run --no-start`-equivalent | upstream-fork-status.md §2.C |

**Filing strategy:** one apple/container GitHub issue per feature (or batched logically). Reference compose-spec sections, cite Container-Compose source line where the gap manifests.

---

## 7. Tier 4 — Won't do (decoded → `coverage.html` `miss`)

Per CHAOS-1338 (Done) and the no-upstream-refactor plan, these are intentionally classified as `miss` rather than a backlog item.

### 7.1 Linux/Windows-specific (no Apple equivalent)
- `service.cgroup`, `service.cgroup_parent` — Linux cgroup surface
- `service.device_cgroup_rules` — Linux cgroup-v1
- `service.storage_opt` — Linux storage drivers
- `service.isolation`, `service.credential_spec` — Windows-only
- `service.label_file` — Linux label sourcing

### 7.2 Swarm-only orchestrator surface (different orchestrator class)
- `service.deploy.mode`, `service.deploy.replicas`, `service.deploy.placement`
- `service.deploy.update_config`, `service.deploy.rollback_config`
- `service.deploy.endpoint_mode`
- (Note: `coverage.html` keeps these as `partial` because they're decoded; they could be flipped to `miss` in a follow-up but that's an editorial choice, not a feature gap.)

### 7.3 Deprecated by compose-spec
- `service.links`, `service.external_links`, `service.volumes_from`

### 7.4 Decoded-only with no apple/container equivalent (CHAOS-1338 family)
- `service.annotations`, `service.attach`, `service.post_start`, `service.pre_stop`, `service.pull_refresh_after`, `service.use_api_socket`

---

## 8. Tier 5 — Frontier (track only)

Compose-spec features still evolving. Do not invest significant implementation work until the upstream/runtime direction stabilizes.

- `top.models` / `service.models` / `service.provider` — AI/LLM provider plumbing. Linear: CHAOS-1332.

---

## 9. Linear ticket map

### 9.1 Already Done (no action needed)

| Linear | Title | What it covers |
| :--- | :--- | :--- |
| CHAOS-1319 | Service-healthy enforcement via `ContainerSnapshot.health` | Fork-only today; blocked on upstream parity |
| CHAOS-1320 | Exit-code verification for `service_completed_successfully` | Fork-only today; blocked on upstream parity |
| CHAOS-1321 | `--restart` flag on `container run` | Fork-only today; blocked on upstream parity |
| CHAOS-1322 | `compose logs --since/--timestamps` | Fork-only today; blocked on upstream parity |
| CHAOS-1323 | Native `compose events` streaming | Fork-only today; blocked on upstream parity |
| CHAOS-1324 | Standard `-e/-u/-w/-d` flags on `compose run/exec` | Fork-only today; blocked on upstream parity |
| CHAOS-1327 | Map driver `bridge` → `container-network-vmnet` | Tier 0 → done |
| CHAOS-1328 | Auto-qualify short-form image refs | Tier 0 → done |
| CHAOS-1329 | Stop emitting `--log-driver` / `--log-opt` | Tier 0 → done |
| CHAOS-1330 | Stop emitting `--add-host` (extra_hosts) | Tier 0 → done |
| CHAOS-1331 | Stop emitting `--alias` (network aliases) | Tier 0 → done |
| CHAOS-1333 | Configs + secrets runtime bind-mount | Tier 1 → done |
| CHAOS-1338 | Decode-only "no equivalent" coverage flips | Tier 4 → done |
| CHAOS-1339 | Named-volume target truncation fix | Tier 1 → done |
| CHAOS-1384 | Host-side `template_driver: golang` rendering for configs / secrets | Reclassified from upstream FR → compose-side partial support |

### 9.2 Open backlog (already filed, valid)

| Linear | Title | Tier |
| :--- | :--- | :--- |
| CHAOS-1332 | Compose AI: wire `models` + `service.provider` runtime support | Tier 5 (frontier) |
| CHAOS-1334 | Network `driver_opts` / `attachable` / `enable_ipv6` / `internal` / `ipam` runtime | Blocked on apple/container upstream |
| CHAOS-1335 | Volume `driver_opts` runtime + improved named-volume handling | Partly wireable; otherwise blocked on apple/container upstream |
| CHAOS-1336 | `deploy.resources.reservations` runtime application | Tier 1 (wireable) but still constrained by upstream flag surface |
| CHAOS-1337 | `build.entitlements` → `--allow` equivalent | Tier 3 (upstream FR) |
| CHAOS-1366 | `RuntimeError.imageNotFound` mapping | unrelated infra |
| CHAOS-1368 | Replace volume path-fallback with runtime CRUD | Tier 1 (wireable) |
| CHAOS-1345 | PRD: Architecture and Docker API compatibility plan | umbrella |

### 9.3 New tickets filed (this audit, 2026-05-01)

Filed automatically as part of this audit. Two umbrellas, 13 sub-issues.

| Linear | Title | Tier |
| :--- | :--- | :--- |
| **[CHAOS-1370](https://linear.app/fullchaos/issue/CHAOS-1370)** | Tier 0: Stop emitting flags `apple/container` does not accept (sweep) — umbrella | Tier 0 |
| [CHAOS-1371](https://linear.app/fullchaos/issue/CHAOS-1371) | Tier 0: Stop emitting `--security-opt` / `--userns` | Tier 0 |
| [CHAOS-1372](https://linear.app/fullchaos/issue/CHAOS-1372) | Tier 0: Stop emitting `--ipc` / `--pid` / `--uts` | Tier 0 |
| [CHAOS-1373](https://linear.app/fullchaos/issue/CHAOS-1373) | Tier 0: Stop emitting `--device` / `--sysctl` | Tier 0 |
| [CHAOS-1374](https://linear.app/fullchaos/issue/CHAOS-1374) | Tier 0: Stop emitting `--ip` / `--ip6` / `--mac-address` | Tier 0 |
| [CHAOS-1375](https://linear.app/fullchaos/issue/CHAOS-1375) | Tier 0: Stop emitting advanced resource flags (`--memory-*`, `--pids-limit`, `--shm-size`, `--cpu-*`, `--oom-*`) | Tier 0 |
| [CHAOS-1376](https://linear.app/fullchaos/issue/CHAOS-1376) | Tier 0: Convert `--gpus` / `--blkio-*` from warn-emit to skip-emit | Tier 0 |
| [CHAOS-1377](https://linear.app/fullchaos/issue/CHAOS-1377) | Tier 0: Audit `container build` flag emissions vs upstream `BuildCommand` | Tier 0 |
| **[CHAOS-1378](https://linear.app/fullchaos/issue/CHAOS-1378)** | Tier 3: File apple/container FRs for missing runtime surface — umbrella | Tier 3 |
| [CHAOS-1379](https://linear.app/fullchaos/issue/CHAOS-1379) | FR upstream: `--gpus` GPU passthrough | Tier 3 |
| [CHAOS-1380](https://linear.app/fullchaos/issue/CHAOS-1380) | FR upstream: `--blkio-*` / cgroup BFQ tuning | Tier 3 |
| [CHAOS-1381](https://linear.app/fullchaos/issue/CHAOS-1381) | FR upstream: `--health-cmd` / `--health-*` CLI flags | Tier 3 |
| [CHAOS-1382](https://linear.app/fullchaos/issue/CHAOS-1382) | FR upstream: file-level bind mounts on `container run -v` | Tier 3 |
| [CHAOS-1383](https://linear.app/fullchaos/issue/CHAOS-1383) | FR upstream: lifecycle hooks API (`post_start` / `pre_stop`) | Tier 3 |

---

## 10. Recommended next steps

1. **File CHAOS-NEW-A umbrella + 7 sub-issues** (Tier 0 sweep). Effort estimate: 4-8 hours batched, vs. file-by-file 30-60 min each.
2. **File CHAOS-NEW-B umbrella + 6 sub-issues** (FR campaign). These get filed externally on `apple/container` GitHub once CHAOS-NEW-B exists internally.
3. **Tighten `coverage.html`** so every Tier 0 row is `partial` (decoded but not wired) rather than implicitly "ok". The current row notes are accurate but the wireup status is misleading.
4. **Cross-link from `coverage.html` rows to this doc** via section anchors — useful for the rendered https://full-chaos.github.io/container-compose/ page.
5. **Update `AGENTS.md` §6** to add a new `Tier 0` heading above Tier 1, summarizing this audit and pointing here. Tier 1 / Tier 2 / Tier 3 numbering shifts down (rename to Tier 1 / Tier 2 / Tier 3 / Tier 4 to match this doc's tiers).

---

## 11. References

- Coverage matrix data: [`coverage.html`](../coverage.html) (canonical), regenerable to `coverage.json` via `scripts/regen-coverage.sh`
- Fork dependencies: [`upstream-fork-status.md`](./upstream-fork-status.md)
- Plan that drained the prior no-upstream queue: [`docs/plans/no-upstream-refactor-and-linear.md`](./plans/no-upstream-refactor-and-linear.md)
- apple/container CLI flag definitions (verified at audit time): `.build/checkouts/container/Sources/Services/ContainerAPIService/Client/Flags.swift` lines 21-405
- apple/container subcommand-local flags: `.build/checkouts/container/Sources/ContainerCommands/Container/{ContainerRun,ContainerCreate,ContainerExec}.swift`, `Network/NetworkCreate.swift`
- Container-Compose argv emission: `Sources/Container-Compose/Commands/Compose+Args*.swift`
- Linear team: **CHAOS** (project: Container Compose)

---

## 12. Appendix A — Verified apple/container CLI surface

Captured 2026-05-01 from `.build/checkouts/container/Sources/Services/ContainerAPIService/Client/Flags.swift`. Use this as the single source of truth when deciding whether a flag is safe to emit.

### `Flags.Logging`
- `--debug` (env: `CONTAINER_DEBUG`)

### `Flags.ProcessBase`
- `--cwd <dir>`
- `--env-file <path>` (no short flag)

### `Flags.Process`
- `-e, --env KEY=VALUE`
- `--env-file <path>`
- `--gid <uint32>`
- `-i, --interactive`
- `-t, --tty`
- `-u, --user <name|uid[:gid]>`
- `--uid <uint32>`
- `-w, --workdir, --cwd <dir>`
- `--ulimit <type>=<soft>[:<hard>]`

### `Flags.Resource`
- `-c, --cpus <int64>`
- `-m, --memory <bytes>`

### `Flags.DNS`
- `--dns <ip>`
- `--dns-domain <domain>`
- `--dns-option <opt>`
- `--dns-search <domain>`

### `Flags.Management`
- `-a, --arch <arch>`
- `--cap-add <cap>`
- `--cap-drop <cap>`
- `--cidfile <path>`
- `-d, --detach`
- (group) `Flags.DNS`
- `--entrypoint <cmd>`
- `--init`
- `--init-image <image>`
- `-k, --kernel <path>`
- `-l, --label KEY=VALUE`
- `--mount type=...,source=...,target=...,readonly`
- `--name <id>`
- `--network <name>[,mac=...][,mtu=...]` (NB: `--ip`, `--alias`, `--add-host` are NOT here)
- `--no-dns`
- `--os <linux|...>`
- `-p, --publish [host-ip:]host-port:container-port[/protocol]`
- `--platform <plat>` (env: `CONTAINER_DEFAULT_PLATFORM`)
- `--publish-socket host_path:container_path`
- `--read-only`
- `--rm`
- `--rosetta`
- `--runtime <handler>`
- `--ssh`
- `--tmpfs <path>`
- `--virtualization`
- `-v, --volume <spec>` (host-path bind mounts; named-volume resolution behavior unverified — see §13)

### Fork-only additions in `full-chaos/container` (NOT in upstream apple/container)
Verified by cloning `github.com/apple/container@main` 2026-05-01 and grepping for these flags — zero matches. They live only in the frozen `tier2-fork-patches` branch we still pin for transitional compatibility.

- `--restart <no|always|on-failure[:N]|unless-stopped>` (CHAOS-1321 — added in fork commit `c63ed9a`). container-compose emits this from `service.restart` (NOT `service.deploy.restart_policy.condition`, which is Tier 4 won't-do per CHAOS-1338). Treat it as blocked on upstream `apple/container`; do not extend the fork further.
- `health: HealthStatus?` field on `ContainerSnapshot` (CHAOS-1319, fork commit `c63ed9a`) — read-only API the fork added. Upstream snapshot has no `health` field.
- `lastExitCode: Int32?` on `ContainerSnapshot` (CHAOS-1320, fork commit `630b8c8`).
- `ContainerLogOptions.{since, timestamps}` (CHAOS-1322).
- `ContainerEvent` + `events()` streaming API (CHAOS-1323).
- `Flags.ProcessBase` short-flag-free subset (CHAOS-1324).

### `container network create` (subcommand-local)
- `--label KEY=VALUE`
- `--internal` (host-only)
- `--subnet <CIDRv4>`
- `--subnet-v6 <CIDRv6>`
- `--plugin <name>` (default: `container-network-vmnet`)
- `--plugin-variant <name>`
- `<name>` (positional)

### `container build` (subcommand-local)
*Not exhaustively re-verified in this audit; see CHAOS-NEW-A.7.*

### What is NOT in upstream apple/container (Tier 0 + Tier 2/3 territory)
- `--ipc`, `--pid`, `--uts`
- `--device`
- `--userns`
- `--security-opt`
- `--add-host`
- `--alias` (network alias)
- `--gpus`
- `--blkio-weight`, `--blkio-weight-device`, `--device-read-bps`, `--device-write-bps`, `--device-read-iops`, `--device-write-iops`
- `--shm-size`
- `--pids-limit`
- `--memory-reservation`, `--memory-swap`, `--memory-swappiness`
- `--cpu-shares`, `--cpuset-cpus`, `--cpu-period`, `--cpu-quota`, `--cpu-rt-period`, `--cpu-rt-runtime`, `--cpu-count`, `--cpu-percent`
- `--oom-kill-disable`, `--oom-score-adj`
- `--sysctl`
- `--ip`, `--ip6` (standalone; `--network <name>,mac=...` only)
- `--mac-address` (standalone; `--network <name>,mac=...` only)
- `--log-driver`, `--log-opt`
- `--health-cmd`, `--health-interval`, `--health-retries`, `--health-timeout`, `--health-start-period`
- `--volumes-from`
- `--storage-opt`
- `--device-cgroup-rule`
- `--isolation`
- Network create: `--driver-opts`, `--attachable`, `--ipv6` (bare), `--ip-range`, `--gateway`, `--aux-address`, `--ipam-driver`, `--ipam-opt`
- `container build`: `--allow` (entitlements)

---

---

## 13. Appendix B — Named volumes (deep dive)

This is a particularly nuanced gap that doesn't fit cleanly into Tier 0/1/2/3. Calling it out separately because the symptoms are subtle.

### Current behavior

Compose YAML like:

```yaml
services:
  db:
    volumes:
      - dbdata:/var/lib/postgresql/data
volumes:
  dbdata:
```

is detected at `Sources/Container-Compose/Commands/ComposeUp.swift:837` via heuristic: source contains `/` or starts with `.` / `..` → bind mount; else → named volume reference.

For named-volume references, Container-Compose:
1. Resolves to host directory `~/.containers/Volumes/<project>/<name>/` (line 866-867)
2. Creates the directory if missing (line 872)
3. Emits `-v <hostPath>:<containerPath>` to `container run` (line 875-878)
4. Emits a warning at line 869-871 saying "The 'container' tool does not support named volume references in 'container run -v' command"

The warning's claim was outdated. apple/container ships `container volume create` (verified upstream — `.build/checkouts/container/Sources/ContainerCommands/Volume/VolumeCreate.swift:28-59`) with `--label`, `--opt`, and `--size`, and the runtime path for `container run -v` resolves bare names as named volumes rather than host paths.

### Phase 0 smoke-test result: GREEN

`container run -v <name>:<path>` **does resolve named volumes** when the source token has no `/` and is not `.` / `..`.

Evidence:

1. `ContainerRun.run()` does not parse `-v` itself; it delegates to `Utility.containerConfigFromFlags(...)` with `managementFlags` (`.build/checkouts/container/Sources/ContainerCommands/Container/ContainerRun.swift:92-103`). `ContainerCreate.run()` follows the same path (`.build/checkouts/container/Sources/ContainerCommands/Container/ContainerCreate.swift:72-87`).
2. `containerConfigFromFlags(...)` parses `management.volumes` via `Parser.volumes(...)`, then converts each `.volume` case into `Filesystem.volume(...)` after `getOrCreateVolume(...)` resolves it through the volume registry (`.build/checkouts/container/Sources/Services/ContainerAPIService/Client/Utility.swift:167-190`).
3. `Parser.volume(...)` explicitly classifies `src` values **without `/` and not equal to `.` / `..`** as named volumes, validates the volume name, and returns `.volume(ParsedVolume(name: src, ...))` instead of a filesystem bind mount (`.build/checkouts/container/Sources/Services/ContainerAPIService/Client/Parser.swift:518-533`).
4. `getOrCreateVolume(...)` creates or inspects the named volume through `ClientVolume.create(...)` / `ClientVolume.inspect(...)`, not through a host-path fallback (`.build/checkouts/container/Sources/Services/ContainerAPIService/Client/Utility.swift:359-392`).
5. `container volume create` / `list` are backed by the same registry API (`ClientVolume.create/list`) and persist real `Volume` records with `name`, `source`, `labels`, and `options` (`.build/checkouts/container/Sources/ContainerCommands/Volume/VolumeCreate.swift:45-60`, `.build/checkouts/container/Sources/ContainerCommands/Volume/VolumeList.swift:42-53`, `.build/checkouts/container/Sources/Services/ContainerAPIService/Client/ClientVolume.swift:25-68`, `.build/checkouts/container/Sources/ContainerResource/Volume/Volume.swift:19-38`).

Conclusion: the old `container-compose` warning was incorrect for local named volumes. The right fix is to create/inspect real volumes and pass the resolved volume **name** to `container run -v <name>:<path>`.

### What's broken / suboptimal

- **`top.volumes.<name>.driver_opts`** — parsed (CHAOS-1335 open) but ignored at runtime. apple/container's `volume create --opt KEY=VALUE` exists, so this is wireable.
- **`top.volumes.<name>.labels`** — parsed but not propagated. `volume create --label` exists.
- **`top.volumes.<name>.driver`** — only `local` is honored; non-local drivers fall back to hardlink (line 320-324). This is correct behavior per apple/container scope, but the warning could be more informative.
- **Cross-project volume sharing** — hardlink-dir scopes to `<project>/<name>`. Real `container volume create` would scope by name only, allowing two projects to share a named volume. This is a behavior divergence that may surprise migrating-from-Docker users.
- **Volume cleanup on `compose down`** — current code does not remove the hardlink dir on `down`. CHAOS-1339 (done) fixed truncation; CHAOS-1368 (open) tracks the broader rework.

### What needs to happen

| Step | Effort | Linear |
| :--- | :--- | :--- |
| 1. Verify whether `container run -v <name>:<path>` (source without `/`) resolves to a registered volume in current upstream | **Done — GREEN via source audit** | CHAOS-1368 |
| 2. Replace hardlink-dir fallback with `container volume create` + `container run -v <name>:<path>`. Wire `driver_opts` / `labels` through. | Implemented in CHAOS-1368 branch; `driver_opts` wiring also advances CHAOS-1335 | CHAOS-1368, CHAOS-1335 |
| 3. Preserve existing data by migrating legacy `~/.containers/Volumes/<project>/<name>/` contents into the runtime volume store on first use. | Implemented with one-time stderr notice and no destructive delete | CHAOS-1368 |
| 4. Keep non-`local` drivers on the legacy hardlink fallback with a clearer warning until apple/container grows broader driver support. | Follow-up / long tail | CHAOS-1335 |

### Bind-mount vs. named-volume disambiguation

The `/` heuristic (line 837) is fragile. A volume name that happens to contain `/` (e.g., a path-like name) would be misidentified as a bind mount. Compose-spec doesn't strictly forbid this — though it's unusual. Possible improvement (out of scope of this audit): consult `top.volumes.<name>` first, classify by declaration, fall back to heuristic only for undeclared sources.

---

*This document supersedes earlier scattered notes in AGENTS.md §6, upstream-fork-status.md §2, and `docs/plans/no-upstream-refactor-and-linear.md` §2 as the single canonical inventory. Those documents remain valid for their original purposes; this one is the cross-cutting view.*
