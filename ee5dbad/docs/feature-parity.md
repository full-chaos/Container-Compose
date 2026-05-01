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
| **Tier 2 — Fork-patch path** | 7 features | `apple/container` lacks the surface; `full-chaos/container` fork can add it (proven by CHAOS-1319-1324 pattern). | **PR to fork** (existing tickets) |
| **Tier 3 — Upstream PR / FR** | 12 features | Need apple/container engineering, not a fork patch. | **File FR upstream** (new) |
| **Tier 4 — Won't do** | 21 fields | Deprecated, Swarm-only, or platform-specific (Windows/Linux cgroups). | Decoded → warn-skipped → `coverage.html` `miss` |
| **Tier 5 — Frontier** | 3 fields | AI/LLM provisioning — spec still evolving. | Track only |

**Critical finding:** Tier 0 is the biggest discovery of this audit. `--ipc`, `--pid`, `--uts`, `--device`, `--userns`, `--security-opt`, all `--blkio-*`, `--shm-size`, `--pids-limit`, `--memory-reservation`, `--memory-swap`, `--memory-swappiness`, `--cpu-shares`, `--cpuset-cpus`, `--cpu-period`, `--cpu-quota`, `--cpu-rt-period`, `--cpu-rt-runtime`, `--cpu-count`, `--cpu-percent`, `--oom-kill-disable`, `--oom-score-adj`, `--sysctl`, `--ip`, `--ip6`, `--gpus`, `--mac-address` are all emitted by Container-Compose but have **no entry** in `apple/container`'s `Flags.Management` / `Flags.Resource` (verified at `.build/checkouts/container/Sources/Services/ContainerAPIService/Client/Flags.swift` lines 21-405). The runtime will reject these flags. CHAOS-1329 (logging), CHAOS-1330 (extra_hosts), CHAOS-1331 (aliases) already followed this remediation pattern; the same remediation is needed for the 22 flags above.

---

## 2. Methodology

### 2.1 Sources cross-referenced

1. **[`coverage.html`](../coverage.html)** — canonical compose-spec coverage matrix (33 partials, 18 misses out of 194 fields). Inline JSON `<script id="coverage-data">` block.
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
| 2 | `service.deploy.resources.reservations.cpus` | partial (parsed; not applied) | Already emit `--memory-reservation` for `service.mem_reservation`; do same for `deploy.resources.reservations.memory` and `cpus`. **CAVEAT**: this hits Tier 0 — `--memory-reservation` is itself unsupported by apple/container today. Block on Tier 0 cleanup OR fork patch. | CHAOS-1336 (open) |
| 3 | `service.deploy.resources.reservations.memory` | partial (parsed; not applied) | Same as #2 | CHAOS-1336 (open) |
| 4 | `top.volumes` named volume runtime CRUD (replace hardlink-dir fallback) | partial | Replace `~/.containers/Volumes/<project>/<name>/` hardlink-dir fallback with `container volume create` API + `container run -v <name>:/path`. Verified `container volume create --label`/`--opt`/`--size` exists. | CHAOS-1368 (open), CHAOS-1335 (open) |
| 5 | `service.provider` | partial (warn-skipped) | Provider lifecycle wiring is implementation, not runtime — could be done without apple/container changes if model-provisioning is intentionally Container-Compose-side. Frontier feature though — verify spec stability before commit. | CHAOS-1332 (open) |
| 6 | Build/Up `pullImage` consolidation | refactor | `ComposeRun.swift:352` has a private `pullImage` while `Compose+Pull.swift:19` has the shared helper. Already noted as R1 in `docs/plans/no-upstream-refactor-and-linear.md`. | tracked in plan, not Linear-ticketed |

---

## 5. Tier 2 — Fork-patch path (`full-chaos/container`)

These are gaps we **could** close in our own fork, mirroring the pattern that closed CHAOS-1319 through CHAOS-1324 (4 commits ahead of upstream). Each is a real engineering effort but doesn't require apple/container engagement.

| # | Feature | Why fork | Existing Linear |
| :-: | :--- | :--- | :--- |
| 1 | `--ipc / --pid / --uts` namespace mode flags | Common Linux primitive; no virtualization complication | NEW (sub-issue of Tier 0 sweep, OR fork-patch alternative) |
| 2 | `--security-opt` | Translates to virtio-fs / Apple Hypervisor seccomp profile | NEW |
| 3 | `--device` (file passthrough) | Some virtualization wiring needed; not trivial but tractable | NEW |
| 4 | `--userns` | Maps to a guest-userns config on the VM | NEW |
| 5 | `--memory-reservation`, `--memory-swap`, `--memory-swappiness`, `--pids-limit`, `--shm-size`, `--cpu-shares`, `--cpuset-cpus`, `--cpu-period`/`-quota`/`-rt-*`/`-count`/`-percent`, `--oom-*` | All map to `Linux.Container` cgroup config — moderate fork effort | NEW |
| 6 | Network IPAM extensions (`--driver-opts`, `--attachable`, `--ipv6` bare, `--ip-range`, `--gateway`, `--aux-addresses`, `--ipam-driver`/`--ipam-opt`) | `apple/container`'s `NetworkCreate` is intentionally minimal; fork can add | CHAOS-1334 (open) |
| 7 | `--add-host`, `--alias`, `--log-driver`/`--log-opt` | Already removed via CHAOS-1329/1330/1331; fork-patch is the alternative if/when needed | tracked in upstream-fork-status.md §1 |

**Pattern:** add an `@Option` / `@Flag` to the appropriate `Flags.*` struct in `apple/container/Sources/Services/ContainerAPIService/Client/Flags.swift`, plumb to `ContainerRun`/`ContainerCreate`, surface via `ContainerClient.Configuration`. Then drop the Tier 0 warn-skip and let the flag flow through.

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
| 8 | Template engine for `configs.template_driver` / `secrets.template_driver` | Compose-spec extension, no `apple/container` analog | NEW (FR) |
| 9 | `--log-driver` / `--log-opt` | Apple container log layout is fixed | upstream-fork-status.md §2.C |
| 10 | `--health-cmd`, `--health-interval`, etc. (CLI form) | Currently health is read via `ContainerSnapshot.health` (CHAOS-1319) but `container run` has no health-cmd flag | NEW (FR) |
| 11 | Per-container log file layout (signoz / alloy compatibility) | `/var/lib/docker/containers/*-json.log` equivalent | upstream-fork-status.md §2.F (no ticket yet) |
| 12 | `container create` (true create-without-start) | Container-Compose probes for support; today shells out to `run --no-start`-equivalent | upstream-fork-status.md §2.C |

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

Compose-spec features still evolving. Do not invest fork engineering until upstream stabilizes.

- `top.models` / `service.models` / `service.provider` — AI/LLM provider plumbing. Linear: CHAOS-1332.

---

## 9. Linear ticket map

### 9.1 Already Done (no action needed)

| Linear | Title | What it covers |
| :--- | :--- | :--- |
| CHAOS-1319 | Service-healthy enforcement via `ContainerSnapshot.health` | Tier 1 → done |
| CHAOS-1320 | Exit-code verification for `service_completed_successfully` | Tier 1 → done |
| CHAOS-1321 | `--restart` flag on `container run` | Tier 1 → done (fork) |
| CHAOS-1322 | `compose logs --since/--timestamps` | Tier 1 → done (fork) |
| CHAOS-1323 | Native `compose events` streaming | Tier 1 → done (fork) |
| CHAOS-1324 | Standard `-e/-u/-w/-d` flags on `compose run/exec` | Tier 1 → done (fork) |
| CHAOS-1327 | Map driver `bridge` → `container-network-vmnet` | Tier 0 → done |
| CHAOS-1328 | Auto-qualify short-form image refs | Tier 0 → done |
| CHAOS-1329 | Stop emitting `--log-driver` / `--log-opt` | Tier 0 → done |
| CHAOS-1330 | Stop emitting `--add-host` (extra_hosts) | Tier 0 → done |
| CHAOS-1331 | Stop emitting `--alias` (network aliases) | Tier 0 → done |
| CHAOS-1333 | Configs + secrets runtime bind-mount | Tier 1 → done |
| CHAOS-1338 | Decode-only "no equivalent" coverage flips | Tier 4 → done |
| CHAOS-1339 | Named-volume target truncation fix | Tier 1 → done |

### 9.2 Open backlog (already filed, valid)

| Linear | Title | Tier |
| :--- | :--- | :--- |
| CHAOS-1332 | Compose AI: wire `models` + `service.provider` runtime support | Tier 5 (frontier) |
| CHAOS-1334 | Network `driver_opts` / `attachable` / `enable_ipv6` / `internal` / `ipam` runtime | Tier 2 (fork) |
| CHAOS-1335 | Volume `driver_opts` runtime + improved named-volume handling | Tier 1 (wireable) + Tier 2 (fork) |
| CHAOS-1336 | `deploy.resources.reservations` runtime application | Tier 1 (wireable, blocked on Tier 0) |
| CHAOS-1337 | `build.entitlements` → `--allow` equivalent | Tier 3 (upstream FR) |
| CHAOS-1366 | `RuntimeError.imageNotFound` mapping | unrelated infra |
| CHAOS-1368 | Replace volume path-fallback with runtime CRUD | Tier 1 (wireable) |
| CHAOS-1345 | PRD: Architecture and Docker API compatibility plan | umbrella |

### 9.3 NEW tickets filed (this audit, 2026-05-01)

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
| [CHAOS-1384](https://linear.app/fullchaos/issue/CHAOS-1384) | FR upstream: template-driver engine for configs / secrets | Tier 3 |

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
- `-v, --volume <spec>`
- `--restart <no|always|on-failure[:N]|unless-stopped>`

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

### What is NOT in apple/container (Tier 0 + Tier 2/3 territory)
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

*This document supersedes earlier scattered notes in AGENTS.md §6, upstream-fork-status.md §2, and `docs/plans/no-upstream-refactor-and-linear.md` §2 as the single canonical inventory. Those documents remain valid for their original purposes; this one is the cross-cutting view.*
