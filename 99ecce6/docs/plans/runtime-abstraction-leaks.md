# Runtime Abstraction Leaks — CHAOS-1348 Phase 3

Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.

This note records abstraction leaks found while adding `MockRuntime`, the
second `Runtime` conformer used to prove the Phase 3 portability boundary from
`docs/plans/native-api-server.md`. `MockRuntime` itself has no dependency on
apple/container, apple/containerization, virtualization entitlements, or the
macOS 26 native runtime path.

## Leaks discovered during Phase 3 / MockRuntime implementation

### 1. Native runtime skeleton tests exercise apple/containerization-backed types

- **Location:** `Tests/Container-Compose-StaticTests/AppleContainerizationRuntimeTests.swift:17`, `:43`, `:44`
- **Nature:** The static test target still includes macOS-only tests that
  instantiate `ContainerRegistry` and `AppleContainerizationRuntime`. The file
  is already gated by `#if os(macOS)`, but it remains integration-shaped
  coverage for the native backend rather than backend-neutral `Runtime`
  contract coverage.
- **Proposed fix:** Tier 2 integration-test scope. Keep it quarantined behind
  the existing macOS conditional for now; move it to a dedicated native-runtime
  test target once the macOS 26 + virtualization entitlement path is fully wired.

### 2. Runtime extension tests include AppleContainerizationRuntime placeholders

- **Location:** `Tests/Container-Compose-StaticTests/RuntimeProtocolExtensionsTests.swift:75`, `:80`, `:91`, `:95`
- **Nature:** The protocol extension test suite includes two direct
  `AppleContainerizationRuntime` checks for version metadata and the Phase 3
  empty-network placeholder. These are useful backend smoke tests, but they are
  not portability proof; `MockRuntime` now covers the backend-neutral filter
  semantics in the same file.
- **Proposed fix:** Won't fix immediately. Keep the tests while the native
  skeleton is still landing; split backend-specific smoke tests out with item 1
  when the native-runtime target exists.

### 3. BridgeContainerClientRuntime is intentionally apple/container-specific

- **Location:** `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift:17`, `:18`
- **Nature:** The bridge conformer imports `ContainerAPIClient` and
  `ContainerResource`, then translates `ContainerSnapshot` into
  `RuntimeContainer`. This is a backend adapter, so the imports are expected,
  but the adapter remains the default runtime in `RuntimeEnvironment.current`.
- **Proposed fix:** Won't fix — backend-specific by design. Track default
  backend selection separately; the adapter should remain the apple/container
  shim until native lifecycle support is deployment-ready.

### 4. BridgeContainerClientRuntime advertises unsupported protocol members

- **Location:** `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift:77`, `:99`, `:106`, `:122`, `:129`, `:143`, `:150`, `:157`
- **Nature:** `RuntimeError.notSupported` is thrown for bridge-only gaps:
  `listNetworks`, `wait`, and secret CRUD. Earlier Phase 1 bridge gaps for
  `create`, `start`, `kill`, `logs`, `events`, and `statistics` now delegate
  through `ContainerClientProvider`. Remaining gaps are adapter limitations,
  not protocol gaps; `MockRuntime` implements the full surface in memory.
- **Proposed fix:** Incrementally shrink this list as commands migrate from
  apple/container CLI/XPC paths to a native runtime. Keep `notSupported` visible
  so API routes can return explicit 501/adapter-gap responses instead of
  silently fabricating data.

### 5. LogRingBuffer imports Containerization for production writer plumbing

- **Location:** `Sources/Container-Compose/Runtime/LogRingBuffer.swift:17`
- **Nature:** The reusable log buffer imports `Containerization` because the
  native backend's stdout/stderr writer path is tied to apple/containerization
  writer APIs. `MockRuntime` bypasses this by storing `RuntimeLogFrame` values
  directly in test memory.
- **Proposed fix:** Consider extracting a backend-neutral ring buffer from the
  writer-facing adapter if log replay moves into more non-native conformers.
  Not required for CHAOS-1348 because the public `Runtime.logs` surface remains
  `RuntimeLogFrame`-only.

## Leaks discovered during Phase 4 / CHAOS-1358 (stats backend)

### 6. BridgeContainerClientRuntime aggregates network stats into a single eth0 entry

- **Location:** `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift` — `translate(stats:)` method added in CHAOS-1358
- **Nature:** `ContainerStats` (from `ContainerResource`) provides only aggregate
  network receive and transmit byte totals (`networkRxBytes`, `networkTxBytes`),
  not per-interface breakdown. The bridge translates these into a single synthetic
  `RuntimeStatistics.Network` entry with `interface: "eth0"`. Real multi-interface
  containers will see their network traffic rolled up into one entry with a
  misleading interface name.
- **Proposed fix:** Wire per-interface stats from the vsock path once
  `AppleContainerizationRuntime` has full lifecycle support. `ContainerStats` may
  gain a per-interface breakdown in a future `apple/container` release; update
  `translate(stats:)` when that happens.

### 7. AppleContainerizationRuntime.statistics returns empty snapshot (no vsock call)

- **Location:** `Sources/Container-Compose/Runtime/AppleContainerizationRuntime.swift` — `statistics(for:)` method
- **Nature:** The native conformer cannot call `LinuxContainer.statistics()` because
  Phase 1's skeleton does not hold a `[String: LinuxContainer]` map — the registry
  stores `RuntimeContainerRecord` values, not live `LinuxContainer` instances. The
  `statistics(for:)` implementation confirms the container exists in the registry
  and returns an empty snapshot (all CPU/memory fields `nil`). Clients streaming
  `/containers/{id}/stats` against the Apple runtime see structurally valid NDJSON
  frames with null metric fields.
- **Proposed fix:** When Phase 2 lifecycle wiring adds real `LinuxContainer`
  instances, extend `AppleContainerizationRuntime` with a `containers:
  [String: LinuxContainer]` or similar map, then call `container.statistics()`
  in this method. The `ContainerStatistics` → `RuntimeStatistics` translation
  should map `cpu.usageUsec`, `memory.usageBytes`, `memory.limitBytes`,
  `memoryEvents.oomKill`, and `networks[].receivedBytes/transmittedBytes` directly.

### 8. ✅ RESOLVED — BridgeContainerClientRuntime.statistics no longer translates all errors as notFound

- **Location:** `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift` — `statistics(for:)` error catch block
- **Nature:** `ContainerClient.stats(id:)` can throw various upstream errors
  (XPC timeout, auth failure, container not found). The catch block translates all
  errors uniformly to `RuntimeError.notFound(id:)` to avoid leaking
  `ContainerizationError` types across the abstraction boundary. This means an XPC
  timeout is indistinguishable from a missing container at the route layer — the
  client receives 404 rather than 503.
- **Resolution:** Fixed in [`b18a9ce`](https://github.com/full-chaos/container-compose/commit/b18a9ce9df7a3d36ab27847e1c93cefb8370fe29). `BridgeContainerClientRuntime.statistics(for:)`
  now inspects typed `ContainerizationError` values, preserves not-found semantics,
  and maps all other upstream failures to `RuntimeError.backendFailure(message:)`.
  `StatsRoutes` now returns 502 for backend failures while keeping genuine
  missing-container cases on 404.

## Leaks discovered during Phase 8 / CHAOS-1353 (resource CRUD)

### 9. BridgeContainerClientRuntime and AppleContainerizationRuntime both throw .notSupported for all network CRUD operations

- **Location:**
  - `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift` — `createNetwork(spec:)` and `removeNetwork(id:)` extension
  - `Sources/Container-Compose/Runtime/AppleContainerizationRuntime.swift` — same extension
- **Nature:** Neither the `apple/container` XPC client (`ContainerAPIClient`) nor the `apple/containerization` Swift package exposes a public Swift API for programmatic network creation or deletion. The `container` CLI handles network management via shell invocations to platform networking tools; `container-compose` currently replicates this in Compose command paths (e.g. `compose up` calls `container network create` via `RunCommandRunner`). Because the `Runtime` protocol is the boundary for API-server operations and neither backend supports these operations, both conformers return `.notSupported`.
- **Proposed fix:** When `apple/containerization` adds network management APIs (tracked upstream), wire `AppleContainerizationRuntime` first. The bridge conformer can follow when the XPC surface grows. The `POST /networks` and `DELETE /networks/{id}` routes already translate `.notSupported` to HTTP 501.

### 10. AppleContainerizationRuntime local volume CRUD still delegates through apple/container's volume registry

- **Location:**
  - `Sources/Container-Compose/Runtime/RuntimeVolumeClient.swift`
  - `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift` — volume CRUD extension
  - `Sources/Container-Compose/Runtime/AppleContainerizationRuntime.swift` — same extension
- **Nature:** CHAOS-1368 closed the functional gap for local named volumes by routing `listVolumes` / `createVolume` / `removeVolume` through `ClientVolume` (apple/container's XPC-backed volume registry). That makes the `Runtime` surface usable for Compose named volumes and REST volume routes. The remaining abstraction leak is architectural: `AppleContainerizationRuntime` still cannot manage volumes through `apple/containerization` alone, so its volume CRUD path depends on the apple/container service instead of the native containerization package.
- **Proposed fix:** When `apple/containerization` grows a public named-volume API, replace `RuntimeVolumeClient` with a truly native backend for `AppleContainerizationRuntime`. Keep the bridge backend on `ClientVolume` unless and until the bridge itself is retired.

### 11. BridgeContainerClientRuntime and AppleContainerizationRuntime both throw .notSupported for all secret CRUD operations

- **Location:**
  - `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift` — secret CRUD extension
  - `Sources/Container-Compose/Runtime/AppleContainerizationRuntime.swift` — same extension
- **Nature:** Neither `apple/containerization` nor `apple/container`'s XPC surface has a concept of secrets. Phase 8 ships in-memory secret storage only via `MockRuntime`; a durable backend (macOS Keychain, encrypted file store, or a dedicated secrets daemon) is deferred. Cross-host secret distribution is explicitly out of scope for CHAOS-1353.
- **Proposed fix:** Implement `AppleContainerizationRuntime.createSecret` / `listSecrets` / `removeSecret` backed by the macOS Keychain (`Security.framework`, `SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`) for single-host use. When container-compose gains multi-host support (Phase N), bridge to a dedicated secrets manager (e.g. HashiCorp Vault, AWS Secrets Manager) via a pluggable backend interface.

## Leaks discovered during Phase 5 / CHAOS-1354 (lifecycle write endpoints)

### 12. BridgeContainerClientRuntime.start does not distinguish container-not-found from other errors

- **Location:** `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift` — `start(id:)` implementation added in CHAOS-1354
- **Nature:** `ContainerClientProvider.start(id:)` calls `ContainerClient.bootstrap(id:stdio:)` + `process.start()`. If the container does not exist, the XPC call throws `ContainerizationError(.notFound)`, but the catch block wraps all errors as `RuntimeError.backendFailure(message:)` to avoid leaking `ContainerizationError` types across the abstraction boundary. The route layer therefore returns 500 instead of 404 for a missing container when using the Bridge backend.
- **Proposed fix:** Inspect the upstream error code and map `ContainerizationError(.notFound)` to `RuntimeError.notFound(id:)` before wrapping everything else as `backendFailure`. This matches the established pattern in `BridgeContainerClientRuntime.get(id:)`.

## Leaks discovered during Phase 6 / CHAOS-1352 (POST /containers/create)

### 13. ✅ RESOLVED — BridgeContainerClientRuntime.create no longer throws .notSupported

- **Location:** `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift` — `create(id:configuration:)`; `Sources/Container-Compose/Runtime/ContainerClientProvider.swift` — `create(id:configuration:)`
- **Resolution:** Fixed in CHAOS-1365. `BridgeContainerClientRuntime.create()` delegates to `ContainerClientProvider.create(id:configuration:)`. The production provider reuses apple/container's `Utility.containerConfigFromFlags(...)` helper to fetch/unpack the image, resolve the default kernel via `ClientKernel`, map process/resource/publish/capability fields, call `ContainerClient.create(configuration:options:kernel:initImage:)`, then read back the created snapshot.
- **Remaining caveat:** The bridge path still depends on the apple/container XPC daemon and image/kernel resolution side effects. Upstream create failures are mapped through `RuntimeErrorMapper`, so duplicate containers can surface as `alreadyExists` and other XPC failures surface as `backendFailure` rather than a route-level 501.

## Leaks discovered during Phase 7 / CHAOS-1360 (project lifecycle endpoints)

### 14. ProjectOrchestrator.build and .pull emit synthetic frames — no Runtime.build/pull protocol method

- **Location:** `Sources/Container-Compose/Server/ProjectOrchestrator.swift` — `buildStream(...)` and `pullStream(...)` static methods
- **Nature:** `POST /projects/{name}/build` and `POST /projects/{name}/pull` are supposed to emit real build/pull progress. The `ProjectOrchestrator` uses only the existing `Runtime` protocol methods (`list`, `get`, `create`, `start`, `stop`, `remove`). There is no `Runtime.build(image:options:)` or `Runtime.pull(image:options:)` protocol method. The `buildStream` and `pullStream` methods emit "not supported via daemon API" frames instead of actual build or pull output. Real image build/pull requires the `RunCommandRunner` seam (a CLI-level concern), which is not accessible from the `Runtime` protocol layer.
- **Impact:** `POST /projects/{name}/build` and `POST /projects/{name}/pull` always return "notSupported" frames regardless of runtime backend. The NDJSON stream shape is correct, so clients can parse it, but no actual build or pull is triggered.
- **Proposed fix:** Add `build(service:context:options:) -> AsyncStream<BuildFrame>` and `pull(imageReference:) -> AsyncStream<PullFrame>` to the `Runtime` protocol. `BridgeContainerClientRuntime` can delegate to `RunCommandRunner.run(.swiftAPI(name: "BuildCommand"), ...)` and `RunCommandRunner.run(.swiftAPI(name: "ImagePull"), ...)`. `MockRuntime` can emit synthetic frames for testing. This decouples project lifecycle routes from CLI internals while using the existing runner seam architecture.

## Leaks discovered during Phase 9 / CHAOS-1359 (TCP/TLS transport)

### 15. ListenAddress shape leaks into idempotence probe — TCPProbe is transport-aware

- **Location:** `Sources/Container-Compose/Commands/TCPProbe.swift` — `canConnect(to:port:timeoutSeconds:)` and `ServeDaemon.isAlreadyServing(listenAddress:)` in `ComposeServe.swift`
- **Nature:** `ServeDaemon.isAlreadyServing(listenAddress:)` branches on the concrete `ListenAddress` case to choose between `UnixSocketProbe` (for `.unix`) and `TCPProbe` (for `.tcp`/`.tls`). This means the daemon startup code is now explicitly aware of the transport layer type at the idempotence-check site. In a cleaner abstraction, the probe logic would be fully encapsulated behind `ListenAddress.probe()` or a `ListenAddressProber` protocol, hiding the branch from the call site.
- **Impact:** Low. The branch is already co-located with `ListenAddress` semantics and both probe implementations are small (< 50 lines each). The leak does not cross the `Runtime` protocol boundary and does not affect testability.
- **Proposed fix:** Introduce `ListenAddress.isAlreadyBound() -> Bool` to encapsulate the dispatch behind the enum itself. Not required for CHAOS-1359 — save for a future "daemon client cleanup" PR.
