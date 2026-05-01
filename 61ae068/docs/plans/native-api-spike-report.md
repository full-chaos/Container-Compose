# Native API Spike — Phase 0 Feasibility Report

> **Date:** 2026-04-30  
> **Status:** Complete  
> **Spike location:** `/Users/chris/projects/full-chaos/container/native-api-spike/`  
> **Inputs:** lifecycle research (`/tmp/spike-lifecycle-apis.md`), observability research (`/tmp/spike-observability-apis.md`)  
> **Related plan:** `docs/plans/native-api-server.md`

---

## 1. Verdict

**Direct-from-containerization is viable.** Importing `apple/containerization` (v0.31.0) as a SwiftPM dependency from a third-party executable compiles cleanly against the full API surface required for container lifecycle management, log streaming, and stats collection. The dependency resolved from GitHub in one step with no fork or local-path workaround required. All lifecycle operations (create, start, stop, kill, wait) and all observability hooks (Writer injection, `statistics(categories:)`) are reachable as public, `async/await`-native, `Sendable` API. Three gaps exist — no native container listing, no native event stream, no native log replay — but none are blockers: each is buildable in ≤ a few hundred lines of application-level Swift inside container-compose. The library is ready to back an `AppleContainerizationRuntime` conformer in Phase 1.

---

## 2. What We Verified

The following API methods were exercised as type-checked Swift code in `Sources/SpikeMain/SpikeMain.swift`. All compiled against `apple/containerization` 0.31.0 with zero errors.

### Lifecycle (from lifecycle research report)

| API | Demonstrated in | Notes |
|---|---|---|
| `ContainerManager.init(kernel:initfs:root:network:)` | `demonstrateManagerInit()` | Sync `throws` variant; struct requires `var` |
| `ContainerManager.create(_:reference:rootfsSizeInBytes:networking:configuration:)` | `demonstrateContainerCreate(manager:)` | Overload 1; pulls image if absent |
| `LinuxContainer.Configuration` — all public fields | `demonstrateContainerCreate(manager:)` | `cpus`, `memoryInBytes`, `hostname`, `process.*`, `sysctl`, `mounts`, `useInit` |
| `LinuxProcessConfiguration.environmentVariables` | `demonstrateContainerCreate(manager:)` | `[String]` (KEY=VALUE), not a dictionary — one compile error caught and fixed |
| `LinuxProcessConfiguration.stdout` / `.stderr` (Writer injection) | `demonstrateContainerCreate(manager:)` | Only at launch; no retrospective attach |
| `LinuxContainer.create()` | `demonstrateTwoStepStart(container:)` | Boots VM, mounts rootfs |
| `LinuxContainer.start()` | `demonstrateTwoStepStart(container:)` | Runs OCI runtime + init process |
| `LinuxContainer.id`, `.config`, `.rootfs`, `.writableLayer`, `.cpus`, `.memoryInBytes`, `.interfaces` | `demonstrateInspection(container:)` | All public, all available before start |
| `LinuxContainer.kill(_ signal: Int32)` | `demonstrateGracefulShutdown(container:registry:)` | SIGTERM graceful path |
| `LinuxContainer.wait(timeoutInSeconds:)` → `ExitStatus` | `demonstrateGracefulShutdown(container:registry:)` | `ExitStatus.exitCode`, `.exitedAt` |
| `LinuxContainer.stop()` | `demonstrateForceStop(container:)` and `demonstrateGracefulShutdown(container:registry:)` | Force-kill; idempotent when already stopped |

### Observability (from observability research report)

| API | Demonstrated in | Notes |
|---|---|---|
| `Writer` protocol | `BufferingWriter` class | `write(_ data: Data) throws`, `close() throws`; `@unchecked Sendable` needed for wrapping state |
| `LinuxContainer.statistics(categories:)` → `ContainerStatistics` | `demonstrateStatistics(container:)` | Polled snapshot; single vsock round-trip per call |
| `StatCategory` option set | `demonstrateStatistics(container:)` | `.all`, `[.cpu, .memory]`, `.memoryEvents` |
| `ContainerStatistics` — all fields | `demonstrateStatistics(container:)` | `cpu`, `memory`, `blockIO`, `networks`, `memoryEvents`, `process` |
| `ContainerStatistics.CPUStatistics` | `demonstrateStatistics(container:)` | `usageUsec`, `userUsec`, `systemUsec` |
| `ContainerStatistics.MemoryStatistics` | `demonstrateStatistics(container:)` | `usageBytes`, `limitBytes` |
| `ContainerStatistics.MemoryEventStatistics` | `demonstrateStatistics(container:)` | `oomKill` (cumulative counter — must diff between polls) |
| `ContainerStatistics.NetworkStatistics` | `demonstrateStatistics(container:)` | `interface`, `receivedBytes`, `transmittedBytes` |
| Polling loop pattern for streaming stats | `demonstrateStatsPollingLoop(container:)` | `Task.isCancelled`, delta-based OOM detection |

### Registry and event bus (our implementation — gaps we own)

| Component | Demonstrated in | Notes |
|---|---|---|
| `ContainerRegistry` actor | `ContainerRegistry` actor body | `register`, `list`, `get`, `updateState`, `recordExit`, `subscribe`, `emit` |
| `ContainerLifecycleState` enum | `ContainerLifecycleState` enum | Mirrors internal states; we track externally |
| `ContainerRecord` struct | `ContainerRecord` struct | Holds `LinuxContainer?`; nil after server restart |
| `ContainerEvent` enum | `ContainerEvent` enum | Synthesized from call sites |
| Event synthesis at lifecycle call sites | `demonstrateGracefulShutdown(container:registry:)`, `runFullLifecycleDemo()` | Emit at create/start/stop/kill |

---

## 3. Work Items We Own

These are gaps confirmed by the two research agents. None blocks Phase 1; all are application-level work inside container-compose.

### 3.1 ContainerRegistry actor
`ContainerManager` has no `list()` method and no registry of created containers. We own a `ContainerRegistry` actor (skeleton in the spike) that:
- Maps `String` (container ID) → `ContainerRecord` holding the live `LinuxContainer?` reference
- Persists a metadata snapshot (id, image reference, created-at, config) to disk (JSON) so listings survive daemon restart
- Reconstructs the metadata index on startup; live `LinuxContainer` references are not reconstructable after restart

Estimated effort: ~100–150 lines of Swift.

### 3.2 Per-container ring buffer for log replay (`since` parity)
`apple/containerization` delivers log bytes via the synchronous `Writer.write(_ data: Data)` push model, starting from process launch. There is no `since`-parameter or log replay. The API server's `Writer` wrapper must:
- Maintain a bounded ring buffer (e.g., last N bytes or last N seconds of timestamped frames) per container
- Timestamp each frame on arrival (the library sends raw `Data` with no timestamp metadata)
- Replay the ring buffer to newly connected HTTP clients, then switch to live streaming

This is the most significant observability work item. Estimated effort: ~200–300 lines.

### 3.3 Event synthesis at lifecycle call sites
No lifecycle event stream exists in the library (`ProgressEvent` is image-pull only; no `ContainerEvent`, `AsyncSequence`, or lifecycle callback). The API server must:
- Wrap every `container.create()`, `.start()`, `.stop()`, `.kill()`, `.wait()`, `.exec()` call site
- Yield a `ContainerEvent` to the registry's event bus at each call site
- For OOM: poll `statistics(categories: .memoryEvents)` on an interval (5s recommended) and compare `oomKill` counter between polls

Estimated effort: ~150 lines for the event bus + wrappers; OOM polling is ~30 lines inside the stats polling loop.

### 3.4 Stats polling loop for streaming endpoints
`statistics()` is a polled snapshot, not a push stream. Each call opens a vsock connection to vminitd inside the VM. For streaming stats endpoints (e.g., `/v1/containers/{id}/stats?stream=true`):
- The API server must implement a per-container polling loop (1-second default interval)
- A **benchmark is needed** before committing to 1-second × N containers at scale. Each call is a vsock open+close; at 100 containers that is 100 vsock connections/second. The observability research flags this as the key scaling concern.

Estimated effort: ~50 lines; benchmark before finalising interval.

### 3.5 Recovery: "no retrospective attach" after server restart
The `Writer` protocol must be supplied at container launch time. If the API server restarts while containers are running, it cannot re-attach to their stdout/stderr. The API server must:
- Accept that log streaming is lost for pre-restart containers (only the ring buffer content survives)
- Communicate this clearly via the API (e.g., `logs-available: false` flag on containers created before restart)
- On restart, mark pre-existing container records as `state: .running` (inferred from disk) but `writer: nil`

No library change required; this is a restart-semantics design decision for Phase 1.

### 3.6 `ContainerManager` is a value type with mutating methods
All code holding a `ContainerManager` must use `var`. In the runtime abstraction layer, wrap it in a reference-type `actor` or `class` so lifecycle operations remain mutation-safe across concurrent calls.

---

## 4. Compilation Outcome

### Dependency resolution

```
swift package resolve — SUCCESS (all from GitHub cache)

containerization          0.31.0   (exact pin)
grpc-swift-2              2.4.0
grpc-swift-nio-transport  2.7.0
grpc-swift-protobuf       2.3.0
async-http-client         1.33.1
swift-algorithms          1.2.1
swift-argument-parser     1.7.1
swift-asn1                1.7.0
swift-async-algorithms    1.1.3
swift-atomics             1.3.0
swift-certificates        1.19.1
swift-collections         1.4.1
swift-configuration       1.2.0
swift-crypto              3.15.1
swift-distributed-tracing 1.4.1
swift-http-structured-headers 1.7.0
swift-http-types          1.5.1
swift-log                 1.12.0
swift-nio                 2.99.0
swift-nio-extras          1.34.0
swift-nio-http2           1.43.0
swift-nio-ssl             2.37.0
swift-nio-transport-services 1.28.0
swift-numerics            1.1.1
swift-protobuf            1.37.0
swift-service-context     1.3.0
swift-service-lifecycle   2.11.0
swift-system              1.6.4
zstd                      1.5.7
```

One warning during resolve: `swift-collections` cache entry missing a blob (`4a5a3cc417daf7908a9bf14515753588a568fc`); resolved by falling back to full fetch. Not an error; Package.resolved now contains the correct revision.

### Build

```
swift build — BUILD COMPLETE, 0 errors, 2 warnings

Warnings (non-blocking):
  SpikeMain.swift:241  — 'manager' never mutated; change to 'let'
  SpikeMain.swift:460  — 'record' never mutated; change to 'let'
```

Both warnings are intentional: the spike preserves `var` to document that `ContainerManager` is a value type with `mutating` methods (a design constraint for Phase 1). They are not errors in Swift 6 strict concurrency mode.

### Compile error discovered and fixed

During the first build attempt, `LinuxProcessConfiguration.environment` was referenced as a `[String: String]` dictionary.  The actual property is:

```swift
public var environmentVariables: [String] = ["PATH=..."]  // KEY=VALUE strings, not a dictionary
```

This was corrected to `config.process.environmentVariables = ["HOME=/root", "PATH=..."]` before the build succeeded. The API shape difference is notable: the property name and type differ from what a Docker-API developer would expect. Phase 1 should document this in the `AppleContainerizationRuntime` adapter.

### No local checkout pivot required

`apple/containerization` resolved cleanly from `https://github.com/apple/containerization.git` at v0.31.0. No fallback to the local checkout at `container/.build/checkouts/containerization/` was needed or used.

---

## 5. Phase 1 Prerequisites

These are not solved by this spike. They must be addressed before any container can actually start.

| Prerequisite | Detail |
|---|---|
| **macOS 26 + Apple Silicon** | `VmnetNetwork`, `NATNetworkInterface` are `@available(macOS 26.0, *)`. `ContainerManager`, `VZVirtualMachineManager` are `#if os(macOS)` only. No Linux support. Hard requirement. |
| **`com.apple.security.virtualization` entitlement** | Required by `Virtualization.framework` for VM creation. `container-compose` must be code-signed with this entitlement in its `.entitlements` plist. Without it, `ContainerManager.init` or `container.create()` will fail at the system level. |
| **`com.apple.vm.networking` entitlement** | Required by `VmnetNetwork` for vmnet NAT networking. Needed for containers with `networking: true` (the default). |
| **vmlinux kernel binary** | A `vmlinux` ELF binary for the target architecture must be available on disk before `ContainerManager.init(kernel:)` is called. `apple/container` CLI ships one via `system kernel set`. container-compose needs its own kernel management story (download on first run, pin version, verify hash). Kernel 6.14.9+ recommended per the library README. |
| **initfs block image** | An `initfs.img` ext4 block file (containing `vminitd`, the in-VM agent) must be available. Can be pulled from the OCI registry reference `ghcr.io/apple/containerization/vminit:0.31.0` using `ContainerManager.init(kernel:initfsReference:root:network:)` — the async overload that pulls on first boot. |
| **Xcode 16 / Swift 6.0 toolchain** | The package builds against swift-tools-version 6.0. Xcode 16 or the Swift 6.0 open-source toolchain is required. |
| **Code-signing infrastructure** | Entitlement injection requires a Developer ID Application certificate or an Apple Development certificate. Ad-hoc signing (`codesign -s -`) will NOT satisfy the `com.apple.security.virtualization` entitlement check on macOS. |

---

## 6. Recommended Next Step

**Phase 1, first task:** Define and stub `protocol Runtime` with the five lifecycle methods (`create`, `start`, `stop`, `kill`, `wait`) and the three observability hooks (`logWriter(for:)`, `statistics(for:categories:)`, `events()`), then implement `AppleContainerizationRuntime: Runtime` that wraps `ContainerManager` in an actor and routes calls to the verified API surface. Gate the implementation behind `#if os(macOS)` and `@available(macOS 26.0, *)` from the start. Wire up a `ContainerRegistry` actor for listing and state tracking, and add the kernel/initfs acquisition flow (download `vmlinux` + pull initfs image on first `serve` invocation). This gives Phase 1 a working end-to-end container lifecycle without needing the HTTP server layer.

---

## 7. References

- **Lifecycle research report:** `/tmp/spike-lifecycle-apis.md` (Agent 1, Phase 0)
- **Observability research report:** `/tmp/spike-observability-apis.md` (Agent 2, Phase 0)
- **Architecture plan this supports:** `docs/plans/native-api-server.md`
- **Spike source:** `/Users/chris/projects/full-chaos/container/native-api-spike/Sources/SpikeMain/SpikeMain.swift`
- **Package manifest:** `/Users/chris/projects/full-chaos/container/native-api-spike/Package.swift`
- **apple/containerization repository:** https://github.com/apple/containerization
- **Version pinned:** `exact: "0.31.0"` (revision `f1ee6f8b737ab8dffbd620bfa47283f6f0bc1822`)
