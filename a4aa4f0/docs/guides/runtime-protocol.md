# Runtime Protocol Contract

> **Source:** `Sources/Container-Compose/Runtime/Runtime.swift`,
> `Sources/Container-Compose/Runtime/RuntimeTypes.swift`,
> `Sources/Container-Compose/Runtime/BridgeContainerClientRuntime.swift`,
> `Sources/Container-Compose/Runtime/AppleContainerizationRuntime.swift`
>
> **Background:** CHAOS-1346 Phase 1. The `Runtime` protocol is the seam that
> lets Container-Compose swap its container backend without touching call
> sites. See the inline header comment in `Runtime.swift` for the full
> architectural rationale.

---

## Overview

`Runtime` is a Swift protocol (`public protocol Runtime: Sendable`) that
defines the contract between Container-Compose's command and API-server layer
and any container backend. All methods are `async throws`.

Two production conformers ship today:

| Conformer | Type | Status | Default? |
| :--- | :--- | :--- | :--- |
| `BridgeContainerClientRuntime` | `struct` | Delegates read paths to `ContainerClientProvider` (apple/container XPC); write paths are mostly `.notSupported` | Yes (`RuntimeEnvironment.current` initial value) |
| `AppleContainerizationRuntime` | `actor` | Registry-backed skeleton; lifecycle methods drive registry state only (no real VM calls until Phase 2) | No |

A third conformer, `MockRuntime`, is used in tests (see
`Tests/Container-Compose-StaticTests/`).

---

## Sendable contract

Every type touching the `Runtime` protocol is `Sendable`-clean. Conformers
should be actor or value-typed and hold no mutable shared state outside an
actor or a documented locked region.

`AppleContainerizationRuntime` is declared `public actor` and isolates all
mutable state (log buffers, event continuations). `BridgeContainerClientRuntime`
is a value type (`struct`) and delegates state management to the injected
`ContainerClientEnvironment.current` actor.

---

## Method reference

### Discovery group

#### `version() async throws -> RuntimeVersion`

Returns backend metadata for the Container REST API version endpoint.

**Returns:** A `RuntimeVersion` with:
- `apiVersion` — currently `"v1"`
- `daemonVersion` — container-compose build version
- `serverName` — `"container-compose"`
- `backendDescription` — backend-specific string (e.g.
  `"bridge (apple/container CLI)"` or `"apple-containerization 0.31.0"`)
- `arch` — host architecture (`"arm64"` or `"x86_64"`)

**Errors:** Does not throw in either production conformer.

**Concurrency:** Reads compile-time constants only; safe to call from any
isolation domain.

**Example call site:**
`Sources/Container-Compose/Server/Routes/` — version route calls
`RuntimeEnvironment.current.version()` to populate the `/version` response.

---

#### `list(filters: RuntimeListFilters) async throws -> [RuntimeContainer]`

Returns all containers visible to this runtime that match `filters`.

**Filters:** `RuntimeListFilters` supports two optional fields:
- `status: [RuntimeContainerStatus]?` — keep only containers in one of these
  statuses. Empty array or `nil` = no filter.
- `namePrefix: String?` — keep only containers whose id starts with this
  prefix. Empty string or `nil` = no filter.
- `RuntimeListFilters.all` is the no-op preset.

**Behavior:** Conformers treat unknown or empty filters as no-ops rather than
throwing. The Bridge conformer fetches the full list from `ContainerClientProvider`
and applies filters in-process; `AppleContainerizationRuntime` applies filters
against its in-memory registry.

**Errors:** May throw `RuntimeError.backendFailure` if the XPC call fails
(Bridge backend only).

**Concurrency:** Safe to call concurrently. `AppleContainerizationRuntime`
applies actor isolation; the Bridge backend relies on the underlying XPC
client's thread safety.

**Example call site:**
`Sources/Container-Compose/Server/Routes/ContainerRoutes.swift:28`

```swift
let runtime = RuntimeEnvironment.current
let containers = try await runtime.list(filters: filters)
```

---

#### `listNetworks() async throws -> [RuntimeNetwork]`

Returns runtime-side network summaries.

**Returns:** Each `RuntimeNetwork` carries `id`, `name`, `driver`, `labels`,
and `attachedContainerIds`.

**Errors:**
- `BridgeContainerClientRuntime`: always throws
  `RuntimeError.notSupported(operation: "listNetworks", conformer: "BridgeContainerClientRuntime")`.
  The apple/container XPC client has no network list API.
- `AppleContainerizationRuntime`: returns an empty array in Phase 1 (network
  enumeration is deferred to Phase 3).

See Leak #9 in
[`docs/plans/runtime-abstraction-leaks.md`](../plans/runtime-abstraction-leaks.md).

---

#### `get(id: String) async throws -> RuntimeContainer`

Returns a single container by id.

**Errors:**
- `RuntimeError.notFound(id:)` when no container with that id exists. This is
  the documented contract; callers can `try?` to coerce to `nil`.

**Example call site:**
`Sources/Container-Compose/Server/Routes/ContainerRoutes.swift:36`

```swift
do {
    let container = try await runtime.get(id: id)
    // ...
} catch RuntimeError.notFound {
    // return 404
}
```

---

### Lifecycle group

#### `create(id: String, configuration: RuntimeCreateConfiguration) async throws -> RuntimeContainer`

Creates a container from an image reference + configuration. Returns the
container in `.created` state. Call `start(id:)` separately to run it.

**Configuration:** `RuntimeCreateConfiguration` exposes:
- `imageReference: String` — OCI image reference
- `cpus: Int` — CPU count (default 1)
- `memoryInBytes: UInt64` — memory limit (default 256 MB)
- `hostname: String?`
- `environment: [String]` — `KEY=VALUE` pairs
- `command: [String]`
- `workingDirectory: String?`
- `publishedPorts: [RuntimePublishedPort]`

**Errors:**
- `RuntimeError.alreadyExists(id:)` if a container with this id is already
  registered (`AppleContainerizationRuntime`).
- `RuntimeError.notSupported(operation: "create", conformer: "BridgeContainerClientRuntime")`
  — the Bridge conformer cannot translate `RuntimeCreateConfiguration` to the
  XPC create call (Leak #13 in
  [`docs/plans/runtime-abstraction-leaks.md`](../plans/runtime-abstraction-leaks.md)).

**Note for Bridge users:** Use `compose up` (which calls `container run` via
`RunCommandRunner`) instead of the REST API's `POST /containers/create` when
the Bridge backend is active.

---

#### `start(id: String) async throws`

Transitions a container from `.created`, `.stopped`, or `.exited` to
`.running`.

**Errors:**
- `RuntimeError.notFound(id:)` if the container does not exist.
- `RuntimeError.invalidState(id:expected:actual:)` if the container is in an
  incompatible state (only in `AppleContainerizationRuntime`; the Bridge
  conformer wraps state mismatches as `backendFailure` — see Leak #12).
- `RuntimeError.backendFailure(message:)` if the underlying XPC start call
  fails (Bridge backend).

**Note:** In `AppleContainerizationRuntime` Phase 1, `start` drives only
registry state — it does not invoke `LinuxContainer.start()`. Real VM
lifecycle wiring is Phase 2.

---

#### `stop(id: String, options: RuntimeStopOptions) async throws`

Stops a running container.

**Options:** `RuntimeStopOptions` has:
- `signal: Int32` — signal to send (default 15 / SIGTERM)
- `timeoutSeconds: Int` — wait before force-killing (default 10)
- `RuntimeStopOptions.default` is the preset.

**Behavior:**
- If the container is not running, `AppleContainerizationRuntime` returns
  without error (idempotent).
- `BridgeContainerClientRuntime` delegates to `ContainerClientProvider.stop`.

**Errors:** May throw `RuntimeError.backendFailure` on XPC failure (Bridge).

---

#### `kill(id: String, signal: Int32) async throws`

Sends an arbitrary signal to the container's init process.

**Errors:**
- `RuntimeError.notFound(id:)` if the container does not exist.
- `RuntimeError.backendFailure(message:)` on XPC failure (Bridge).

**Note:** `AppleContainerizationRuntime` records the kill event in the event
stream but does not invoke a real vsock kill in Phase 1.

---

#### `wait(id: String, timeoutSeconds: Int) async throws -> RuntimeExitStatus`

Blocks until the container exits or `timeoutSeconds` elapses.

**Returns:** `RuntimeExitStatus` with `exitCode: Int32` and `exitedAt: Date`.

**Errors:**
- `RuntimeError.notFound(id:)` if the container does not exist.
- `RuntimeError.timeout(id:seconds:)` if the container has not exited within
  the timeout.
- `RuntimeError.notSupported(operation: "wait", conformer: "BridgeContainerClientRuntime")`
  — the Bridge backend has no blocking wait equivalent.

---

#### `remove(id: String, force: Bool) async throws`

Removes a stopped container's metadata and writable layer.

**Parameters:**
- `force: Bool` — if `true`, sends SIGKILL to running containers before
  removing. If `false`, throws for running containers.

**Errors:**
- `RuntimeError.notFound(id:)` if the container does not exist.
- `RuntimeError.invalidState(id:expected:actual:)` if `force` is `false` and
  the container is running (`AppleContainerizationRuntime`).

---

### Observability group

#### `logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame>`

Replays (and optionally follows) the container's stdout and stderr log stream.

**Options:** `RuntimeLogOptions` has:
- `follow: Bool` — continue streaming after replay
- `tail: Int?` — limit to last N frames; `nil` = all
- `since: Date?` — skip frames older than this date
- `timestamps: Bool` — include timestamps in frames
- `RuntimeLogOptions.default` is the no-follow, no-tail, no-since preset.

**Returns:** `AsyncStream<RuntimeLogFrame>` where each `RuntimeLogFrame` has:
- `timestamp: Date`
- `source: RuntimeLogFrame.Source` (`.stdout` or `.stderr`)
- `data: Data` — raw log line bytes

**Implementation notes:**
- `BridgeContainerClientRuntime`: fetches log file handles via
  `ContainerClientProvider.logs(id:options:)`, drains them, and applies
  `tail`. The `follow` option is not supported in Phase 1 (the bridge returns
  a finished stream after draining buffered output).
- `AppleContainerizationRuntime`: drains the per-container `LogRingBuffer`,
  merges stdout/stderr in timestamp order, then finishes. Real follow-mode
  will require Phase 2 lifecycle wiring.

**Errors:**
- `RuntimeError.notFound(id:)` if the container does not exist or has no log
  handles (Bridge).

---

#### `events() async throws -> AsyncStream<RuntimeContainerEvent>`

Subscribes to lifecycle events. Each call returns a new independent stream.

**Events emitted:**
- `.created(id:at:)`
- `.started(id:at:)`
- `.stopped(id:exitCode:at:)`
- `.killed(id:signal:at:)`
- `.oomKilled(id:at:)`
- `.removed(id:at:)`

**Implementation notes:**
- `AppleContainerizationRuntime`: events are synthesized at every lifecycle
  call site and broadcast to all active subscribers.
- `BridgeContainerClientRuntime`: polls `ContainerClient.events()` at 1-second
  intervals and yields only events newer than the last emitted timestamp.
  `oomKilled` events are not generated by the Bridge backend in Phase 1.

**Errors:** Does not throw; the stream finishes on cancellation or on a
persistent polling error (Bridge).

---

#### `statistics(for id: String) async throws -> RuntimeStatistics`

Returns a single polled statistics snapshot.

**Returns:** `RuntimeStatistics` with:
- `id: String`
- `cpuUsageUsec: UInt64?`
- `memoryUsageBytes: UInt64?`
- `memoryLimitBytes: UInt64?`
- `oomKillCount: UInt64?`
- `networks: [RuntimeStatistics.Network]` — per-interface rx/tx bytes
- `sampledAt: Date`

**Implementation notes:**
- `BridgeContainerClientRuntime`: translates `ContainerStats` from the XPC
  client. All network traffic is aggregated into a single synthetic `"eth0"`
  entry (Leak #6 in runtime-abstraction-leaks.md).
- `AppleContainerizationRuntime`: returns an empty snapshot (all CPU/memory
  fields `nil`) in Phase 1 because `LinuxContainer.statistics()` requires a
  live VM instance (Leak #7).

**Errors:**
- `RuntimeError.notFound(id:)` if the container does not exist.
- `RuntimeError.backendFailure(message:)` on XPC error (Bridge).

---

### Resource CRUD group (CHAOS-1353)

#### Networks

| Method | Signature | Bridge | Apple |
| :--- | :--- | :--- | :--- |
| `createNetwork` | `(spec: RuntimeCreateNetworkSpec) async throws -> RuntimeNetwork` | `.notSupported` | `.notSupported` |
| `removeNetwork` | `(id: String) async throws` | `.notSupported` | `.notSupported` |

Both production conformers throw `.notSupported` for network CRUD — neither
the `apple/container` XPC client nor `apple/containerization` exposes a Swift
API for network creation/deletion. See Leak #9 in
[`docs/plans/runtime-abstraction-leaks.md`](../plans/runtime-abstraction-leaks.md).

`RuntimeCreateNetworkSpec` fields: `name`, `driver` (default `"bridge"`),
`subnet: String?`, `gateway: String?`, `labels`.

---

#### Volumes

| Method | Signature | Bridge | Apple |
| :--- | :--- | :--- | :--- |
| `listVolumes` | `() async throws -> [RuntimeVolume]` | Via `RuntimeVolumeClient` | Via `RuntimeVolumeClient` |
| `createVolume` | `(spec: RuntimeCreateVolumeSpec) async throws -> RuntimeVolume` | Via `RuntimeVolumeClient` | Via `RuntimeVolumeClient` |
| `removeVolume` | `(name: String) async throws` | Via `RuntimeVolumeClient` | Via `RuntimeVolumeClient` |

Both conformers delegate to `RuntimeVolumeClient`, which calls the
apple/container XPC volume registry. Only the `local` driver is fully supported
(Leak #10). `createVolume` throws `RuntimeError.alreadyExists` if a volume
with that name already exists.

`RuntimeCreateVolumeSpec` fields: `name`, `driver` (default `"local"`),
`labels`, `driverOptions`.

---

#### Secrets

| Method | Signature | Bridge | Apple |
| :--- | :--- | :--- | :--- |
| `listSecrets` | `() async throws -> [RuntimeSecret]` | `.notSupported` | `.notSupported` |
| `createSecret` | `(spec: RuntimeCreateSecretSpec) async throws -> RuntimeSecret` | `.notSupported` | `.notSupported` |
| `removeSecret` | `(name: String) async throws` | `.notSupported` | `.notSupported` |

Both production conformers throw `.notSupported`. In-memory secret storage is
implemented only by `MockRuntime` (Phase 8); a durable backend is deferred.
See Leak #11.

Secret values are passed in `RuntimeCreateSecretSpec.value`; subsequent
`listSecrets` responses never include values — only metadata (`name`,
`labels`, `createdAt`).

---

## Conformer patterns

### BridgeContainerClientRuntime

```
                       ┌──────────────────────────────────────┐
  Container-Compose    │  BridgeContainerClientRuntime        │
  call site            │  (struct, value type)                │
  ────────────────► list│ ──► ContainerClientEnvironment.current│──► XPC daemon
                   ► get│ ──► ContainerClientProvider.get      │
                   ► start│──► ContainerClientProvider.start   │
              .notSupported for: create, wait, listNetworks,   │
                   listSecrets, createSecret, removeSecret      │
                       └──────────────────────────────────────┘
```

The Bridge conformer is the production default because `AppleContainerizationRuntime`
requires macOS 26, the virtualization entitlement, and a vmlinux kernel staged
at the expected path — none of which is available on typical contributor
laptops or CI runners.

### AppleContainerizationRuntime

```
                       ┌──────────────────────────────────────┐
  Container-Compose    │  AppleContainerizationRuntime        │
  call site            │  (actor, isolated)                   │
                 list  │ ──► ContainerRegistry (actor)        │
                 get   │     (in-memory registry of           │
                 create│      RuntimeContainerRecord values)  │
                 start │                                      │
                       │  Phase 2 (not yet wired):            │
                       │  ContainerManager / LinuxContainer   │──► apple/containerization
                       └──────────────────────────────────────┘
```

`AppleContainerizationRuntime` is `public actor`. All mutable state (log
buffers `stdoutBuffers`/`stderrBuffers`, event continuations
`eventContinuations`) lives inside actor isolation.

---

## RuntimeEnvironment — task-local injection

`RuntimeEnvironment` is the task-local holder for the active `Runtime`:

```swift
public enum RuntimeEnvironment {
    @TaskLocal public static var current: any Runtime = BridgeContainerClientRuntime()
}
```

**Production code** reads `RuntimeEnvironment.current`:

```swift
// From Sources/Container-Compose/Server/Routes/ContainerRoutes.swift:26
let runtime = RuntimeEnvironment.current
let containers = try await runtime.list(filters: filters)
```

**Tests** bind a mock/recording conformer for the duration of a task:

```swift
// From Tests/Container-Compose-StaticTests/ComposeUpVolumeIdempotencyTests.swift:46
let didCreate = try await RuntimeEnvironment.$current.withValue(runtime) {
    // code under test runs against `runtime`
}
```

This pattern mirrors `ContainerClientEnvironment` (the existing injection
point for `ContainerClientProvider`) and `RunnerEnvironment`.

---

## Known leaks and gaps

The `Runtime` protocol is not yet fully wired across all backends. The
canonical record of every known gap is
[`docs/plans/runtime-abstraction-leaks.md`](../plans/runtime-abstraction-leaks.md).
Key items relevant to protocol users:

| Leak | Description | Impact |
| :--- | :--- | :--- |
| #4 | Bridge throws `.notSupported` for `create`, `wait`, `logs` (in some cases), `events`, `statistics` write-paths | REST API returns 501 for these on Bridge |
| #6 | Bridge aggregates all network stats into one synthetic `"eth0"` entry | Per-interface stats unavailable on Bridge |
| #7 | `AppleContainerizationRuntime.statistics` returns empty snapshot | All CPU/memory fields are `nil` on native backend |
| #9 | Both conformers throw `.notSupported` for `createNetwork`/`removeNetwork` | POST /networks → 501 always |
| #11 | Both conformers throw `.notSupported` for all secret CRUD | POST /secrets → 501 always |
| #12 | Bridge `start(id:)` wraps container-not-found as `backendFailure` | Route returns 500 instead of 404 for missing containers |
| #13 | Bridge `create(id:)` always throws `.notSupported` | POST /containers/create → 501 on Bridge |
| #14 | Neither conformer implements `Runtime.build/pull`; project build/pull routes emit "not supported" frames | POST /projects/{name}/build never triggers real build |

---

## See also

- [Error Codes Reference](./error-codes.md) — full `RuntimeError` case documentation
- [Migration from Docker Compose](./migration-from-docker-compose.md) — user-facing impact of protocol gaps
- [Feature Parity Inventory](../feature-parity.md) — compose-spec field coverage
- [Runtime Abstraction Leaks](../plans/runtime-abstraction-leaks.md) — canonical gap catalogue
- [Reviews](../reviews/) — code review notes and context
