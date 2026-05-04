# Runtime Protocol Contract

> **Source files:**
> - `Sources/Container-Compose/Runtime/Runtime.swift` (protocol definition, `RuntimeError`, `RuntimeEnvironment`)
> - `Sources/Container-Compose/Runtime/RuntimeTypes.swift` (all `Runtime*` value types)
> - `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift` (Bridge conformer)
> - `Sources/Container-Compose/Runtime/AppleContainerizationRuntime.swift` (native conformer, macOS only)
> - `Sources/Container-Compose/Runtime/RuntimeVolumeClient.swift` (shared volume backend)
> - `Tests/TestHelpers/MockRuntime.swift` (stateful test fake)
> - `Tests/TestHelpers/RecordingRuntime.swift` (call-recording test fake)
>
> **Background:** CHAOS-1346 Phase 1. The `Runtime` protocol is the seam that
> lets Container-Compose swap its container backend without modifying call sites.
> See the header comment in `Runtime.swift:21-38` for the full architectural rationale.

---

## Overview

`Runtime` is a Swift protocol declared at `Runtime.swift:39`:

```swift
public protocol Runtime: Sendable { ... }
```

All methods are `async throws`. Every type crossing the protocol boundary is
`Sendable`-clean. The protocol has four conformers:

| Conformer | Kind | Where defined | Purpose |
| :--- | :--- | :--- | :--- |
| `BridgeContainerClientRuntime` | `struct` | `BridgeContainerClientRuntime.swift:49` | Delegates read paths to `ContainerClientProvider` (apple/container XPC); write paths mostly throw `.notSupported`. **Default conformer.** |
| `AppleContainerizationRuntime` | `actor` | `AppleContainerizationRuntime.swift:53` | Registry-backed; lifecycle drives state only (Phase 1 skeleton — no real VM calls). Requires macOS. |
| `MockRuntime` | `final actor` | `Tests/TestHelpers/MockRuntime.swift:46` | Full stateful fake for tests. Implements all methods including resource CRUD. |
| `RecordingRuntime` | `actor` | `Tests/TestHelpers/RecordingRuntime.swift:28` | Records every call as an `Entry`; returns stubbed data. Used to assert which calls a command makes. |

---

## Method Reference

### Discovery group

#### `version() async throws -> RuntimeVersion`

**Declared:** `Runtime.swift:47`

Returns backend metadata for the Container REST API version endpoint.
`RuntimeVersion` is declared at `RuntimeTypes.swift:116`.

**Parameters:** none

**Returns:** `RuntimeVersion` with five fields:
- `apiVersion: String` — currently `"v1"` in all conformers
- `daemonVersion: String` — build version from `Main.version`
- `serverName: String` — `"container-compose"` in all conformers
- `backendDescription: String` — backend-specific: `"bridge (apple/container CLI)"` (Bridge, `BridgeContainerClientRuntime.swift:60`), `"apple-containerization 0.31.0"` (Apple, `AppleContainerizationRuntime.swift:79`), `"mock-runtime"` (Mock, `MockRuntime.swift:29`), `"recording-runtime"` (Recording, `RecordingRuntime.swift:121`)
- `arch: String` — compile-time constant: `"arm64"` or `"x86_64"`

**Throws:** Never in any production or test conformer. The method is not declared `rethrows` because the protocol contract allows conformers to throw if a future backend requires a round-trip.

**Call sites:**
- `Sources/Container-Compose/Server/Routes/SystemRoutes.swift:25` — GET `/system/info`
- `Sources/Container-Compose/Server/Routes/SystemRoutes.swift:37` — GET `/version`

---

#### `list(filters: RuntimeListFilters) async throws -> [RuntimeContainer]`

**Declared:** `Runtime.swift:53`

Returns all containers visible to this runtime that match `filters`. Conformers treat unknown or empty filters as no-ops, never throw for them.

**Parameters:**
- `filters: RuntimeListFilters` — declared at `RuntimeTypes.swift:175`
  - `.all` (static preset) — no filtering
  - `status: [RuntimeContainerStatus]?` — keep containers in these states; empty or `nil` = no filter
  - `namePrefix: String?` — keep containers whose id starts with this; empty or `nil` = no filter
  - `func matches(_ container: RuntimeContainer) -> Bool` — per-container predicate (`RuntimeTypes.swift:188`)

**Returns:** `[RuntimeContainer]`, ordered by id ascending in `MockRuntime`; unordered in Bridge/Apple.

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:65-71`): calls `ContainerClientEnvironment.current.list(filters: .all)`, translates `ContainerSnapshot` → `RuntimeContainer`, then applies `filters.matches` in-process.
- **Apple** (`AppleContainerizationRuntime.swift:84-89`): calls `registry.list()`, maps records, applies `filters.matches`.
- **Mock** (`MockRuntime.swift:84-88`): filters from in-memory `containers` dictionary, returns sorted by id.
- **Recording** (`RecordingRuntime.swift:126-129`): appends `.list` to entries, filters stubbed containers.

**Throws:** May throw `RuntimeError.backendFailure` on XPC failure (Bridge only).

**Call sites:**
- `Sources/Container-Compose/Server/Routes/ContainerRoutes.swift:26` — GET `/containers`
- `Sources/Container-Compose/Server/Routes/ProjectRoutes.swift:33` — GET `/projects`
- `Sources/Container-Compose/Server/Routes/ProjectRoutes.swift:40` — used for project grouping

---

#### `listNetworks() async throws -> [RuntimeNetwork]`

**Declared:** `Runtime.swift:60`

Returns runtime-side network summaries. `RuntimeNetwork` is declared at `RuntimeTypes.swift:144`.

**Returns:** Each `RuntimeNetwork` carries: `id`, `name`, `driver`, `labels: [String: String]`, `attachedContainerIds: [String]`.

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:73-82`): always throws `RuntimeError.notSupported(operation: "listNetworks", conformer: "BridgeContainerClientRuntime")`. The `apple/container` XPC client has no network list API.
- **Apple** (`AppleContainerizationRuntime.swift:97-99`): returns `[]` (empty array). Network enumeration is deferred to Phase 3.
- **Mock** (`MockRuntime.swift:90-92`): returns stubbed networks sorted by name.
- **Recording** (`RecordingRuntime.swift:131-133`): records `.listNetworks`, returns stubbed networks.

**Throws:** `RuntimeError.notSupported` for Bridge (always). See also [error-codes.md — notSupported](./error-codes.md#notsupportedoperation-string-conformer-string).

**Call sites:**
- `Sources/Container-Compose/Server/Routes/NetworkRoutes.swift:28` — GET `/networks`

---

#### `get(id: String) async throws -> RuntimeContainer`

**Declared:** `Runtime.swift:66`

Returns a single container by id. Callers may `try?` to coerce to `nil`.

**Parameters:**
- `id: String` — the container id (convention: `<project>-<service>`)

**Returns:** `RuntimeContainer` if found.

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:84-92`): calls `ContainerClientProvider.get(id:)`, translates to `RuntimeContainer`. Catches all errors and rethrows as `RuntimeError.notFound(id: id)` — including cases that might be XPC failures rather than true not-found (see Leak #12 in `docs/plans/runtime-abstraction-leaks.md`).
- **Apple** (`AppleContainerizationRuntime.swift:101-106`): checks registry; throws `RuntimeError.notFound` when `registry.get(id:)` returns `nil`.
- **Mock** (`MockRuntime.swift:94-99`): dictionary lookup; throws `notFound` when absent.
- **Recording** (`RecordingRuntime.swift:136-142`): appends `.get(id:)`, returns first stub match or throws `notFound`.

**Throws:** `RuntimeError.notFound(id:)` when no container with that id exists.

**Call sites:**
- `Sources/Container-Compose/Server/Routes/ContainerRoutes.swift:34` — GET `/containers/{id}`
- `Sources/Container-Compose/Server/Routes/LifecycleRoutes.swift:54` — container lifecycle operations

---

### Lifecycle group

#### `create(id: String, configuration: RuntimeCreateConfiguration) async throws -> RuntimeContainer`

**Declared:** `Runtime.swift:73-76`

Creates a container from an image reference and configuration. Returns the freshly registered container in `.created` state. Call `start(id:)` to run it.

**Parameters:**
- `id: String` — desired container id
- `configuration: RuntimeCreateConfiguration` — declared at `RuntimeTypes.swift:448`:
  - `imageReference: String` — OCI image reference
  - `cpus: Int` — CPU count (default `1`)
  - `memoryInBytes: UInt64` — memory limit (default `256 * 1024 * 1024`, i.e., 256 MB)
  - `hostname: String?`
  - `environment: [String]` — `KEY=VALUE` pairs
  - `command: [String]`
  - `workingDirectory: String?`
  - `publishedPorts: [RuntimePublishedPort]`

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:112-119`): always throws `RuntimeError.notSupported(operation: "create", conformer: "BridgeContainerClientRuntime")`. The XPC create path requires a `Kernel` binary reference and a `ContainerConfiguration` shape not exposed by `RuntimeCreateConfiguration`. Documented as Leak #13.
- **Apple** (`AppleContainerizationRuntime.swift:110-129`): checks registry for duplicate, allocates `RuntimeContainerRecord` in `.created` state, registers it, initializes `LogRingBuffer` entries for stdout/stderr, emits `.created` event. No real `ContainerManager.create` call in Phase 1.
- **Mock** (`MockRuntime.swift:101-120`): throws `alreadyExists` on duplicate, stores container in memory, publishes `.created` event.
- **Recording** (`RecordingRuntime.swift:144-156`): records `.create(id:)`, returns a freshly constructed `.created` container.

**Throws:**
- `RuntimeError.alreadyExists(id:)` if a container with this id exists (Apple, Mock)
- `RuntimeError.notSupported(operation: "create", conformer: "BridgeContainerClientRuntime")` (Bridge, always)

**Call sites:**
- `Sources/Container-Compose/Server/Routes/ContainerCreateRoute.swift` — POST `/containers/create`

---

#### `start(id: String) async throws`

**Declared:** `Runtime.swift:83`

Transitions a container from `.created`, `.stopped`, or `.exited` to `.running`.

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:124-130`): delegates to `ContainerClientEnvironment.current.start(id:)`, maps errors via `mapUpstreamError`. Note: Bridge catches all errors from the XPC call and maps them to `backendFailure` or `notFound` — it does not produce `invalidState`.
- **Apple** (`AppleContainerizationRuntime.swift:132-146`): verifies container exists (throws `notFound`), verifies state is `.created`, `.stopped`, or `.exited` (throws `invalidState`), updates registry to `.running`, emits `.started` event. No `LinuxContainer.start()` call in Phase 1.
- **Mock** (`MockRuntime.swift:123-139`): verifies container exists, verifies state is `.created` (throws `invalidState` for any other state), sets to `.running`, publishes `.started` event.
- **Recording** (`RecordingRuntime.swift:158-160`): records `.start(id:)`, returns without error.

**Throws:**
- `RuntimeError.notFound(id:)` — container does not exist (Apple, Mock, Bridge via mapUpstreamError)
- `RuntimeError.invalidState(id:expected:actual:)` — state check failed (Apple: accepts created/stopped/exited; Mock: accepts only created)
- `RuntimeError.backendFailure(message:)` — XPC error (Bridge)

**Call sites:**
- `Sources/Container-Compose/Server/Routes/LifecycleRoutes.swift:77` — POST `/containers/{id}/start`
- `Sources/Container-Compose/Server/Routes/ProjectLifecycleRoutes.swift:106` — POST `/projects/{name}/start`

---

#### `stop(id: String, options: RuntimeStopOptions) async throws`

**Declared:** `Runtime.swift:89`

Stops a running container. `RuntimeStopOptions` is declared at `RuntimeTypes.swift:201`:
- `signal: Int32` (default `15` / SIGTERM)
- `timeoutSeconds: Int` (default `10`)
- `RuntimeStopOptions.default` — the standard preset

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:133-140`): translates to `ContainerStopOptions`, delegates to `ContainerClientProvider.stop`. Propagates XPC errors without remapping (no `mapUpstreamError` call here).
- **Apple** (`AppleContainerizationRuntime.swift:148-162`): throws `notFound` if container absent; returns silently if not `.running` (idempotent); transitions through `.stopping`, records exit with code `0`, closes log buffers, emits `.stopped` event.
- **Mock** (`MockRuntime.swift:142-158`): throws `notFound` if absent, throws `invalidState` if not `.running`, sets to `.stopped` with `lastExitCode: 0`, publishes `.stopped` event. **Note:** Mock is stricter than Apple — it throws `invalidState` for non-running containers; Apple returns silently.
- **Recording** (`RecordingRuntime.swift:162-164`): records `.stop(id:)`, returns without error.

**Throws:**
- `RuntimeError.notFound(id:)` — container not found (Apple, Mock)
- `RuntimeError.invalidState(id:expected:actual:)` — not running (Mock only; Apple is idempotent)
- XPC errors propagated raw from Bridge (not remapped here)

**Call sites:**
- `Sources/Container-Compose/Server/Routes/LifecycleRoutes.swift:102` — POST `/containers/{id}/stop`
- `Sources/Container-Compose/Server/Routes/ProjectLifecycleRoutes.swift:138` — POST `/projects/{name}/stop`

---

#### `kill(id: String, signal: Int32) async throws`

**Declared:** `Runtime.swift:92`

Sends an arbitrary signal to the container's init process.

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:142-149`): delegates to `ContainerClientProvider.kill(id:signal:)`, maps via `mapUpstreamError`.
- **Apple** (`AppleContainerizationRuntime.swift:164-168`): verifies existence (throws `notFound`), emits `.killed` event. Does not invoke a real vsock kill in Phase 1.
- **Mock** (`MockRuntime.swift:161-177`): verifies existence, verifies `.running` state (throws `invalidState`), sets to `.stopped` with `lastExitCode: 128 + signal`, publishes `.killed` event.
- **Recording** (`RecordingRuntime.swift:166-168`): records `.kill(id:signal:)`.

**Throws:**
- `RuntimeError.notFound(id:)` — container not found (Apple, Mock, Bridge via mapUpstreamError)
- `RuntimeError.invalidState(id:expected:actual:)` — not running (Mock only)
- `RuntimeError.backendFailure(message:)` — XPC error (Bridge via mapUpstreamError)

**Call sites:**
- `Sources/Container-Compose/Server/Routes/LifecycleRoutes.swift:135` — POST `/containers/{id}/kill`
- `Sources/Container-Compose/Server/Routes/ProjectLifecycleRoutes.swift:168` — POST `/projects/{name}/kill`

---

#### `wait(id: String, timeoutSeconds: Int) async throws -> RuntimeExitStatus`

**Declared:** `Runtime.swift:95`

Blocks until the container exits or `timeoutSeconds` elapses. `RuntimeExitStatus` is declared at `RuntimeTypes.swift:215`:
- `exitCode: Int32`
- `exitedAt: Date`

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:151-155`): always throws `RuntimeError.notSupported(operation: "wait", conformer: "BridgeContainerClientRuntime")`. The apple/container XPC client has no blocking wait equivalent.
- **Apple** (`AppleContainerizationRuntime.swift:171-179`): throws `notFound` if absent; returns existing `exitStatus` if present; otherwise throws `RuntimeError.timeout(id:seconds:)` immediately (Phase 1 does not have a real wait mechanism — the container never genuinely exits).
- **Mock** (`MockRuntime.swift:180-191`): polls every 10ms until status is `.stopped`/`.exited` or deadline passes (throws `RuntimeError.timeout`). Returns `RuntimeExitStatus` with `lastExitCode`.
- **Recording** (`RecordingRuntime.swift:170-173`): records `.wait(id:)`, returns `RuntimeExitStatus(exitCode: 0, exitedAt: Date())`.

**Throws:**
- `RuntimeError.notFound(id:)` — container not found
- `RuntimeError.timeout(id:seconds:)` — timeout elapsed (Apple, Mock)
- `RuntimeError.notSupported(operation: "wait", conformer: "BridgeContainerClientRuntime")` — Bridge, always

**Call sites:**
- `Sources/Container-Compose/Server/Routes/LifecycleRoutes.swift:160` — POST `/containers/{id}/wait`

---

#### `remove(id: String, force: Bool) async throws`

**Declared:** `Runtime.swift:99`

Removes a stopped container's metadata and writable layer.

**Parameters:**
- `force: Bool` — if `true`, running containers are killed before removal. If `false`, attempting to remove a running container throws `invalidState`.

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:158-161`): delegates to `ContainerClientProvider.delete(id:force:)`. No error remapping — propagates raw XPC errors.
- **Apple** (`AppleContainerizationRuntime.swift:181-191`): throws `notFound` if absent; throws `invalidState(expected: .stopped, actual: .running)` when `!force && record.state == .running`; removes from registry, clears log buffers, emits `.removed` event.
- **Mock** (`MockRuntime.swift:194-205`): throws `notFound` if absent; throws `invalidState` if running and `!force`; removes from all in-memory stores, finishes log subscribers, publishes `.removed` event.
- **Recording** (`RecordingRuntime.swift:175-177`): records `.remove(id:force:)`.

**Throws:**
- `RuntimeError.notFound(id:)` — container not found (Apple, Mock)
- `RuntimeError.invalidState(id:expected:actual:)` — running and `force == false` (Apple, Mock)

**Call sites:**
- `Sources/Container-Compose/Server/Routes/LifecycleRoutes.swift:184` — DELETE `/containers/{id}`

---

### Observability group

#### `logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame>`

**Declared:** `Runtime.swift:108`

Replays (and optionally follows) the container's stdout and stderr log stream.

**Parameters:**
- `options: RuntimeLogOptions` — declared at `RuntimeTypes.swift:291`:
  - `follow: Bool` — continue streaming after replay (default `false`)
  - `tail: Int?` — limit to last N frames; `nil` = all
  - `since: Date?` — skip frames older than this date
  - `timestamps: Bool` — include timestamps in frame metadata
  - `RuntimeLogOptions.default` — no-follow, no-tail, no-since preset

**Returns:** `AsyncStream<RuntimeLogFrame>`. Each `RuntimeLogFrame` (declared `RuntimeTypes.swift:307`) has:
- `timestamp: Date`
- `source: RuntimeLogFrame.Source` — `.stdout` or `.stderr`
- `data: Data` — raw log line bytes (newlines stripped by bridge log collection)

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:165-178`): fetches `[FileHandle]` via `ContainerClientProvider.logs(id:options:)`. Throws `RuntimeError.notFound(id:)` on any error from that call (`BridgeContainerClientRuntime.swift:174`). Collects all frames from handles (`collectLogFrames`), sorts by timestamp, applies `tail`. The stream finishes immediately after replay — `follow` is not honoured in Phase 1.
- **Apple** (`AppleContainerizationRuntime.swift:196-212`): throws `notFound` if container absent. Drains `stdoutBuffers[id]` and `stderrBuffers[id]` via `LogRingBuffer.replay(options:)`, merges in timestamp order (`merge(stdout:stderr:)`), yields all frames, finishes. No live-follow in Phase 1.
- **Mock** (`MockRuntime.swift:207-226`): throws `notFound` if absent. Replays filtered log frames. If `follow: true`, registers a continuation in `logContinuations` and keeps the stream open until cancellation. Test code injects frames via `injectLogFrame(_:forContainerID:)`.
- **Recording** (`RecordingRuntime.swift:179-191`): records `.logs(id:options:)`. Throws `logsError` if configured, otherwise returns stubbed frames.

**Throws:**
- `RuntimeError.notFound(id:)` — container not found or no log handles (Apple, Bridge, Mock)
- Configured `logsError` (Recording only)

**Call sites:**
- `Sources/Container-Compose/Server/Routes/LogsRoutes.swift` — GET `/containers/{id}/logs`

---

#### `events() async throws -> AsyncStream<RuntimeContainerEvent>`

**Declared:** `Runtime.swift:114`

Subscribes to lifecycle events. Each call returns an independent stream. `RuntimeContainerEvent` is declared at `RuntimeTypes.swift:234`:
- `.created(id: String, at: Date)`
- `.started(id: String, at: Date)`
- `.stopped(id: String, exitCode: Int32, at: Date)`
- `.killed(id: String, signal: Int32, at: Date)`
- `.oomKilled(id: String, at: Date)`
- `.removed(id: String, at: Date)`

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:180-217`): polls `ContainerClientProvider.events()` at 1-second intervals. Filters to events newer than last emitted timestamp, sorts, yields translated events. Finishes the stream on persistent error or cancellation. `oomKilled` is not generated — `ContainerEvent.action` has no OOM case. Translation at `BridgeContainerClientRuntime.swift:289-300`: `die` and `stop` actions map to `.stopped` with `exitCode: 0` (exit code is not available from `ContainerEvent`).
- **Apple** (`AppleContainerizationRuntime.swift:214-222`): registers a `UUID`-keyed continuation in `eventContinuations`. Events are broadcast to all active continuations by the private `emit(_:)` method at `AppleContainerizationRuntime.swift:263`. Cancellation removes the continuation via `unsubscribe(eventID:)`.
- **Mock** (`MockRuntime.swift:228-236`): same pattern as Apple — registers UUID-keyed continuation. Tests inject events via `injectEvent(_:)` at `MockRuntime.swift:257`.
- **Recording** (`RecordingRuntime.swift:193-203`): records `.events`. Returns stubbed event list as a finished stream. Throws `eventsError` if configured.

**Throws:** Does not throw in production conformers. The Bridge stream finishes silently on persistent XPC error. Recording throws configured `eventsError`.

**Call sites:**
- `Sources/Container-Compose/Server/Routes/EventsRoutes.swift:26` — GET `/events`

---

#### `statistics(for id: String) async throws -> RuntimeStatistics`

**Declared:** `Runtime.swift:118`

Returns a single polled statistics snapshot. `RuntimeStatistics` is declared at `RuntimeTypes.swift:249`:
- `id: String`
- `cpuUsageUsec: UInt64?`
- `memoryUsageBytes: UInt64?`
- `memoryLimitBytes: UInt64?`
- `oomKillCount: UInt64?`
- `networks: [RuntimeStatistics.Network]` — per-interface rx/tx bytes
- `sampledAt: Date`

**Conformer behaviour:**
- **Bridge** (`BridgeContainerClientRuntime.swift:219-227`): calls `ContainerClientProvider.stats(id:)`, translates via `translate(stats:)` at `BridgeContainerClientRuntime.swift:231-250`. All network traffic is aggregated into a single synthetic `"eth0"` entry because `ContainerStats` does not expose per-interface breakdown. `oomKillCount` is always `nil` — it requires `MemoryEventStatistics` which is not available via `ContainerStats`.
- **Apple** (`AppleContainerizationRuntime.swift:224-241`): throws `notFound` if absent; returns an empty `RuntimeStatistics(id: id, sampledAt: Date())` — all optional fields are `nil`. Real vsock stats require a live `LinuxContainer` instance (Phase 2).
- **Mock** (`MockRuntime.swift:238-244`): throws `notFound` if absent; returns stubbed statistics injected via `injectStatistics(_:forContainerID:)`, or an empty snapshot if none was injected.
- **Recording** (`RecordingRuntime.swift:207-227`): records `.statistics(id:)`. Supports three stub modes: single snapshot (`stubbedStatistics`), sequence of snapshots (`stubbedStatisticsSequence` — throws `notFound` when exhausted), or empty snapshot.

**Throws:**
- `RuntimeError.notFound(id:)` — container not found (Apple, Mock, Bridge via mapUpstreamError)
- `RuntimeError.backendFailure(message:)` — XPC error (Bridge)
- Configured `statisticsError` (Recording)

**Call sites:**
- `Sources/Container-Compose/Server/Routes/StatsRoutes.swift:52` — GET `/containers/{id}/stats`

---

### Resource CRUD group (CHAOS-1353)

#### Networks

##### `createNetwork(spec: RuntimeCreateNetworkSpec) async throws -> RuntimeNetwork`

**Declared:** `Runtime.swift:127`

`RuntimeCreateNetworkSpec` declared at `RuntimeTypes.swift:420`: `name`, `driver` (default `"bridge"`), `subnet: String?`, `gateway: String?`, `labels`.

| Conformer | Behaviour | Source |
| :--- | :--- | :--- |
| Bridge | Always throws `notSupported(operation: "createNetwork", conformer: "BridgeContainerClientRuntime")` | `BridgeContainerClientRuntime.swift:441-446` |
| Apple | Always throws `notSupported(operation: "createNetwork", conformer: "AppleContainerizationRuntime")` | `AppleContainerizationRuntime.swift:359-364` |
| Mock | Creates in-memory `RuntimeNetwork` with UUID id; throws `alreadyExists` on duplicate name | `MockRuntime.swift:335-348` |
| Recording | Records `.createNetwork(name:)`; throws `createNetworkError` if configured; returns stub network | `RecordingRuntime.swift:231-243` |

**Rationale for `notSupported`:** Neither the apple/container XPC client nor `apple/containerization` expose a Swift API for network creation. Documented as Leak #9 in `docs/plans/runtime-abstraction-leaks.md`.

---

##### `removeNetwork(id: String) async throws`

**Declared:** `Runtime.swift:131`

| Conformer | Behaviour | Source |
| :--- | :--- | :--- |
| Bridge | Always throws `notSupported(operation: "removeNetwork", conformer: "BridgeContainerClientRuntime")` | `BridgeContainerClientRuntime.swift:449-454` |
| Apple | Always throws `notSupported(operation: "removeNetwork", conformer: "AppleContainerizationRuntime")` | `AppleContainerizationRuntime.swift:367-372` |
| Mock | Removes by id; throws `notFound` if absent | `MockRuntime.swift:350-356` |
| Recording | Records `.removeNetwork(id:)`; throws `removeNetworkError` if configured | `RecordingRuntime.swift:245-252` |

---

#### Volumes

Both production conformers delegate volume operations to `RuntimeVolumeClient` (declared at `RuntimeVolumeClient.swift:22`), which calls the apple/container XPC volume registry via `ClientVolume`. Only the `"local"` driver is fully supported — non-local drivers throw `notSupported(operation: "createVolume(driver=<driver>)", conformer: "RuntimeVolumeClient")` at `RuntimeVolumeClient.swift:30`.

##### `listVolumes() async throws -> [RuntimeVolume]`

**Declared:** `Runtime.swift:136`

`RuntimeVolume` declared at `RuntimeTypes.swift:331`: `name`, `driver`, `labels`, `createdAt: Date?`.

| Conformer | Behaviour | Source |
| :--- | :--- | :--- |
| Bridge | Delegates to `RuntimeVolumeClient.list()` → `ClientVolume.list()` | `BridgeContainerClientRuntime.swift:458` |
| Apple | Delegates to `RuntimeVolumeClient.list()` | `AppleContainerizationRuntime.swift:376` |
| Mock | Returns in-memory volume dictionary values sorted by name | `MockRuntime.swift:359-361` |
| Recording | Records `.listVolumes`; returns stubbed volumes | `RecordingRuntime.swift:255-258` |

---

##### `createVolume(spec: RuntimeCreateVolumeSpec) async throws -> RuntimeVolume`

**Declared:** `Runtime.swift:141`

`RuntimeCreateVolumeSpec` declared at `RuntimeTypes.swift:351`: `name`, `driver` (default `"local"`), `labels`, `driverOptions`.

| Conformer | Behaviour | Source |
| :--- | :--- | :--- |
| Bridge | Delegates to `RuntimeVolumeClient.create(spec:)` | `BridgeContainerClientRuntime.swift:462` |
| Apple | Delegates to `RuntimeVolumeClient.create(spec:)` | `AppleContainerizationRuntime.swift:380` |
| Mock | Creates in-memory; throws `alreadyExists` on duplicate | `MockRuntime.swift:363-375` |
| Recording | Records `.createVolume(name:)`; returns stub volume | `RecordingRuntime.swift:260-266` |

`RuntimeVolumeClient.create` error mapping (`RuntimeVolumeClient.swift:28-55`):
- `VolumeError.volumeAlreadyExists` → `RuntimeError.alreadyExists(id: name)` (line 44)
- `ContainerizationError` with message containing `"already exists"` → `RuntimeError.alreadyExists(id: spec.name)` (line 50)
- All other errors → `RuntimeError.backendFailure(message:)` (lines 46, 52, 54)

---

##### `removeVolume(name: String) async throws`

**Declared:** `Runtime.swift:145`

| Conformer | Behaviour | Source |
| :--- | :--- | :--- |
| Bridge | Delegates to `RuntimeVolumeClient.remove(name:)` | `BridgeContainerClientRuntime.swift:466` |
| Apple | Delegates to `RuntimeVolumeClient.remove(name:)` | `AppleContainerizationRuntime.swift:384` |
| Mock | Removes from dictionary; throws `notFound` if absent | `MockRuntime.swift:377-381` |
| Recording | Records `.removeVolume(name:)`; throws `notFound` if name not in stubs | `RecordingRuntime.swift:270-274` |

`RuntimeVolumeClient.remove` error mapping (`RuntimeVolumeClient.swift:58-76`):
- `VolumeError.volumeNotFound` → `RuntimeError.notFound(id: missing)` (line 64)
- `ContainerizationError` with message containing `"not found"` → `RuntimeError.notFound(id: name)` (line 70)
- All other errors → `RuntimeError.backendFailure(message:)` (lines 66, 72, 74)

**Call sites:**
- `Sources/Container-Compose/Server/Routes/VolumeRoutes.swift:78` — DELETE `/volumes/{name}`
- `Sources/Container-Compose/Commands/ComposeDown.swift` — `compose down -v`

---

#### Secrets

All production conformers throw `notSupported` for every secret method. `MockRuntime` is the only conformer with a working in-memory secret store.

`RuntimeSecret` declared at `RuntimeTypes.swift:378`: `name`, `labels`, `createdAt`. The secret value is never stored in `RuntimeSecret` — it is accepted only in `RuntimeCreateSecretSpec.value` during creation and discarded after.

##### `listSecrets() async throws -> [RuntimeSecret]`

**Declared:** `Runtime.swift:151`

| Conformer | Behaviour | Source |
| :--- | :--- | :--- |
| Bridge | Throws `notSupported(operation: "listSecrets", conformer: "BridgeContainerClientRuntime")` | `BridgeContainerClientRuntime.swift:475-479` |
| Apple | Throws `notSupported(operation: "listSecrets", conformer: "AppleContainerizationRuntime")` | `AppleContainerizationRuntime.swift:394-398` |
| Mock | Returns in-memory secrets sorted by name | `MockRuntime.swift:386-388` |
| Recording | Records `.listSecrets`; returns stubbed secrets | `RecordingRuntime.swift:277-280` |

---

##### `createSecret(spec: RuntimeCreateSecretSpec) async throws -> RuntimeSecret`

**Declared:** `Runtime.swift:157`

`RuntimeCreateSecretSpec` declared at `RuntimeTypes.swift:398`: `name`, `value: String`, `labels`.

| Conformer | Behaviour | Source |
| :--- | :--- | :--- |
| Bridge | Throws `notSupported(operation: "createSecret", conformer: "BridgeContainerClientRuntime")` | `BridgeContainerClientRuntime.swift:483-487` |
| Apple | Throws `notSupported(operation: "createSecret", conformer: "AppleContainerizationRuntime")` | `AppleContainerizationRuntime.swift:402-406` |
| Mock | Creates in-memory (value stored but never returned); throws `alreadyExists` on duplicate | `MockRuntime.swift:390-403` |
| Recording | Records `.createSecret(name:)`; returns stub secret | `RecordingRuntime.swift:282-288` |

---

##### `removeSecret(name: String) async throws`

**Declared:** `Runtime.swift:161`

| Conformer | Behaviour | Source |
| :--- | :--- | :--- |
| Bridge | Throws `notSupported(operation: "removeSecret", conformer: "BridgeContainerClientRuntime")` | `BridgeContainerClientRuntime.swift:491-495` |
| Apple | Throws `notSupported(operation: "removeSecret", conformer: "AppleContainerizationRuntime")` | `AppleContainerizationRuntime.swift:410-414` |
| Mock | Removes by name; throws `notFound` if absent | `MockRuntime.swift:404-408` |
| Recording | Records `.removeSecret(name:)`; throws `notFound` if name not in stubs | `RecordingRuntime.swift:290-295` |

**Rationale for `notSupported`:** Neither the apple/container XPC client nor `apple/containerization` exposes a secret management API. A durable backend (e.g. macOS Keychain) is deferred. Documented as Leak #11 in `docs/plans/runtime-abstraction-leaks.md`.

---

## Conformer Comparison Matrix

| Method | Bridge | Apple | Mock | Recording |
| :--- | :---: | :---: | :---: | :---: |
| `version` | returns constant | returns constant | returns constant | returns constant |
| `list` | XPC → filter | registry → filter | memory → filter | stub |
| `listNetworks` | `.notSupported` | `[]` | memory | stub |
| `get` | XPC | registry | memory | stub or `notFound` |
| `create` | `.notSupported` | registry + events | memory + events | stub |
| `start` | XPC | registry + events | memory + events | no-op |
| `stop` | XPC (raw errors) | registry + events (idempotent) | memory + events (strict) | no-op |
| `kill` | XPC + map | events only | memory + events (strict) | no-op |
| `wait` | `.notSupported` | immediate timeout | polling loop | stub exit 0 |
| `remove` | XPC (raw errors) | registry + events | memory + events | no-op |
| `logs` | file handles (no follow) | ring buffer (no follow) | memory + optional follow | stub |
| `events` | 1s poll loop | push broadcast | push broadcast | stub (finished) |
| `statistics` | XPC + eth0 agg | empty snapshot | memory or stub | stub or seq |
| `createNetwork` | `.notSupported` | `.notSupported` | memory | stub |
| `removeNetwork` | `.notSupported` | `.notSupported` | memory | stub |
| `listVolumes` | XPC (`RuntimeVolumeClient`) | XPC (`RuntimeVolumeClient`) | memory | stub |
| `createVolume` | XPC (`RuntimeVolumeClient`, local only) | XPC (`RuntimeVolumeClient`, local only) | memory | stub |
| `removeVolume` | XPC (`RuntimeVolumeClient`) | XPC (`RuntimeVolumeClient`) | memory | stub |
| `listSecrets` | `.notSupported` | `.notSupported` | memory | stub |
| `createSecret` | `.notSupported` | `.notSupported` | memory | stub |
| `removeSecret` | `.notSupported` | `.notSupported` | memory | stub |

---

## Threading Model and TaskLocal Injection

### RuntimeEnvironment

`RuntimeEnvironment` is declared at `Runtime.swift:240`:

```swift
public enum RuntimeEnvironment {
    @TaskLocal public static var current: any Runtime = BridgeContainerClientRuntime()
}
```

`@TaskLocal` means the value is inherited by child tasks and can be overridden for the duration of a closure via `withValue`. Every `RuntimeEnvironment.current` access reads the innermost binding from the task's task-local storage chain. The default value (`BridgeContainerClientRuntime()`) is the initial binding for the root task.

### Production usage

Production route handlers read `RuntimeEnvironment.current` directly. Example from `ContainerRoutes.swift:26`:

```swift
let runtime = RuntimeEnvironment.current
let containers = try await runtime.list(filters: filters)
```

Full set of production call sites:
- `Sources/Container-Compose/Server/Routes/ContainerRoutes.swift` (lines 26, 34)
- `Sources/Container-Compose/Server/Routes/LifecycleRoutes.swift` (lines 54, 77, 102, 135, 160, 184)
- `Sources/Container-Compose/Server/Routes/ProjectLifecycleRoutes.swift` (lines 66, 106, 138, 168, 194, 220)
- `Sources/Container-Compose/Server/Routes/ProjectRoutes.swift` (lines 33, 40)
- `Sources/Container-Compose/Server/Routes/NetworkRoutes.swift` (lines 28, 36, 66)
- `Sources/Container-Compose/Server/Routes/VolumeRoutes.swift` (lines 32, 49, 78)
- `Sources/Container-Compose/Server/Routes/SecretRoutes.swift` (lines 39, 55)
- `Sources/Container-Compose/Server/Routes/EventsRoutes.swift` (line 26)
- `Sources/Container-Compose/Server/Routes/StatsRoutes.swift` (line 52)
- `Sources/Container-Compose/Server/Routes/SystemRoutes.swift` (lines 25, 37)

### Test injection

Tests bind a mock or recording conformer for the duration of a task:

```swift
// From Tests/Container-Compose-StaticTests/ComposeUpVolumeIdempotencyTests.swift:46
let didCreate = try await RuntimeEnvironment.$current.withValue(runtime) {
    // code under test runs against `runtime`
}
```

The `$current` prefix accesses the `TaskLocal` projected value, whose `withValue(_:operation:)` method establishes a scoped override. Tests that exercise the Bridge conformer instead use `ContainerClientEnvironment.$current.withValue(provider) { ... }` (e.g. `ComposeDownConfigsSecretsCleanupTests.swift:58`).

### Sendable contract

- `BridgeContainerClientRuntime` is a value type (`struct`) — no captured mutable state. It reads from `ContainerClientEnvironment.current` (an actor) at each call site.
- `AppleContainerizationRuntime` is `public actor` — actor isolation covers `stdoutBuffers`, `stderrBuffers`, and `eventContinuations`. `ContainerRegistry` is itself an actor (`ContainerRegistry.swift`).
- `MockRuntime` and `RecordingRuntime` are `final actor` — all mutations are actor-isolated.

---

## Conformer-Specific Quirks

### BridgeContainerClientRuntime quirks

1. **`get` maps all errors to `notFound`** (`BridgeContainerClientRuntime.swift:89`): any XPC failure during `get(id:)` is caught and rethrown as `RuntimeError.notFound(id: id)`. This means a daemon crash during a `get` looks like a not-found to the route handler and returns 404 instead of 500. Documented as Leak #12.

2. **`stop` does not remap errors** (`BridgeContainerClientRuntime.swift:133-140`): unlike `start` and `kill`, the `stop` method calls `provider.stop` directly without `mapUpstreamError`. XPC failures propagate as raw errors that route handlers do not catch, producing 500 responses with backend error detail.

3. **Log follow not supported** (`BridgeContainerClientRuntime.swift:345-366`): the `streamLogs` helper drains file handles and finishes the stream immediately. The `RuntimeLogOptions.follow` flag is accepted but ignored.

4. **Events: exit code always 0** (`BridgeContainerClientRuntime.swift:295`): `ContainerEvent.action` `.stop`/`.die` map to `.stopped(exitCode: 0)` because the `ContainerEvent` type does not carry an exit code. Real exit codes are only available via `ContainerSnapshot.lastExitCode`.

5. **Stats: network aggregation** (`BridgeContainerClientRuntime.swift:235-239`): `ContainerStats` provides aggregate rx/tx bytes. The bridge synthesizes a single `RuntimeStatistics.Network(interface: "eth0", ...)` entry regardless of the container's actual network interfaces.

### AppleContainerizationRuntime quirks

1. **Phase 1 skeleton** (`AppleContainerizationRuntime.swift:29-47`): lifecycle methods (`create`, `start`, `stop`, `kill`, `wait`, `remove`) drive registry state only. No `LinuxContainer` or `ContainerManager` methods are called. The `Containerization` import exists for compile-time dependency verification via `_phase2DependencyAnchor()` at `AppleContainerizationRuntime.swift:341`.

2. **`wait` throws timeout immediately** (`AppleContainerizationRuntime.swift:171-179`): if a container has no `exitStatus` recorded, `wait` throws `RuntimeError.timeout` immediately regardless of `timeoutSeconds`. There is no actual blocking poll in Phase 1.

3. **`stop` is idempotent** (`AppleContainerizationRuntime.swift:148-162`): if the container is not `.running`, `stop` returns without error. This diverges from `MockRuntime` which throws `invalidState` for non-running containers.

4. **Empty statistics** (`AppleContainerizationRuntime.swift:224-241`): `statistics(for:)` returns `RuntimeStatistics(id: id, sampledAt: Date())` with all CPU/memory fields `nil`. Clients see `null` in NDJSON stats frames.

5. **`listNetworks` returns `[]`** (`AppleContainerizationRuntime.swift:97-99`): unlike Bridge which throws `notSupported`, Apple returns an empty array. This is intentional per the Phase 2 comment — the route handler gets a valid empty list while network backing is deferred.

### MockRuntime quirks

1. **`stop` is strict** (`MockRuntime.swift:142-158`): throws `invalidState` if the container is not `.running`. Apple's conformer is idempotent for non-running containers; Mock is not.

2. **`start` accepts only `.created`** (`MockRuntime.swift:123-138`): throws `invalidState` for any state other than `.created`. The Apple conformer also accepts `.stopped` and `.exited`.

3. **Full secret support** (`MockRuntime.swift:386-409`): the only conformer where secret CRUD works end-to-end. Secret value is stored in the actor state but never returned through the protocol — `RuntimeSecret` never carries values.

4. **`resetToCreated`** (`MockRuntime.swift:425-437`): test-only affordance to reset a stopped/exited container back to `.created` state, enabling re-`start` sequences in tests.

---

## Known Protocol Gaps

The canonical gap catalogue is `docs/plans/runtime-abstraction-leaks.md`. Key items:

| Leak # | Description | Protocol impact |
| :---: | :--- | :--- |
| #4 | Bridge: `create`, `wait` throw `.notSupported`; `logs` follow ignored; `events` OOM not emitted | REST routes return 501 for these paths on Bridge |
| #6 | Bridge: all network stats aggregated into synthetic `"eth0"` | `statistics.networks` always has at most 1 entry on Bridge |
| #7 | Apple: `statistics` returns empty snapshot | All `cpuUsageUsec`, `memoryUsageBytes` etc. are `nil` on Apple |
| #9 | Both production conformers: `createNetwork`/`removeNetwork` throw `.notSupported` | POST/DELETE `/networks` always returns 501 |
| #11 | Both production conformers: all secret CRUD throws `.notSupported` | POST/DELETE `/secrets` always returns 501 |
| #12 | Bridge `get`: all XPC errors mapped to `notFound` | Bridge may return 404 when daemon is unresponsive (should be 500) |
| #13 | Bridge `create`: always throws `.notSupported` | POST `/containers/create` returns 501 on Bridge |

---

## See also

- [Error Codes Reference](./error-codes.md) — full `RuntimeError`, `ComposeError`, and other error type documentation
- [Migration from Docker Compose](../guides/migration-from-docker-compose.md) — user-facing impact of protocol gaps
- [Feature Parity Inventory](../feature-parity.md) — compose-spec field coverage
- [Runtime Abstraction Leaks](../plans/runtime-abstraction-leaks.md) — canonical gap catalogue
- [Native API Server Plan](../plans/native-api-server.md) — phased migration roadmap
