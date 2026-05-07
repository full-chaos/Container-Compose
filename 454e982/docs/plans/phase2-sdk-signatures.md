# Phase 2 SDK Signatures — Verified API Surface

**Ticket:** CHAOS-1424 (PR1 deliverable)
**SDK source:** `apple/containerization` 0.31.x — locally available at `.build/checkouts/containerization/`
**Verified:** May 2026 against `Package.resolved`
**Replaces:** Section A of the original research-pass plan posted on CHAOS-1424 (which was inferred because the checkout was absent at research time)

This doc is the canonical source of truth for the apple/containerization API surface that PR2/3/4 will wire into `AppleContainerizationRuntime`. Every signature below is cited file:line against the local SDK checkout. Implementers — verify against this doc before writing code that calls into the SDK.

---

## A. ContainerManager

**File:** `.build/checkouts/containerization/Sources/Containerization/ContainerManager.swift`

```swift
public struct ContainerManager: Sendable {
    public let imageStore: ImageStore
    // private: vmm, network
}
```

**Critical:** `ContainerManager` is **`Sendable`** but several of its methods are **`mutating`**. To use it inside an actor, hold it as an actor-isolated stored property; the actor's serialization handles the `mutating` requirement.

### Initializers (5 overloads)

`ContainerManager.swift:42` — kernel + initfs Mount + imageStore:
```swift
public init(
    kernel: Kernel,
    initfs: Mount,
    imageStore: ImageStore,
    network: Network? = nil,
    rosetta: Bool = false,
    nestedVirtualization: Bool = false
) throws
```

`:64` — kernel + initfs Mount + optional root URL:
```swift
public init(
    kernel: Kernel,
    initfs: Mount,
    root: URL? = nil,
    network: Network? = nil,
    rosetta: Bool = false,
    nestedVirtualization: Bool = false
) throws
```

`:90` — kernel + initfs **reference** (string) + imageStore (async; pulls initfs):
```swift
public init(
    kernel: Kernel,
    initfsReference: String,
    imageStore: ImageStore,
    network: Network? = nil,
    rosetta: Bool = false,
    nestedVirtualization: Bool = false
) async throws
```

`:130` and `:173` — additional convenience overloads (read source for full signatures).

**Acquisition story:** the manager itself takes a pre-constructed `Kernel` value. The caller is responsible for kernel acquisition — there is **no `getDefaultKernel(for:)` method** in apple/containerization (the inferred plan referenced one obliquely; in practice the caller constructs a `Kernel` directly — see Section C). The `apple/container` fork *may* expose a higher-level `ClientKernel.getDefaultKernel`, but that is fork territory and out of scope for CHAOS-1424.

### `create(...)` — 3 overloads, all `mutating async throws -> LinuxContainer`

`:201` — by image **reference** (resolves + pulls):
```swift
public mutating func create(
    _ id: String,
    reference: String,
    rootfsSizeInBytes: UInt64 = 8.gib(),
    writableLayerSizeInBytes: UInt64? = nil,
    readOnly: Bool = false,
    networking: Bool = true,
    progress: ProgressHandler? = nil,
    configuration: (inout LinuxContainer.Configuration) throws -> Void
) async throws -> LinuxContainer
```

`:235` — by resolved `Image` value (skips the lookup):
```swift
public mutating func create(
    _ id: String,
    image: Image,
    rootfsSizeInBytes: UInt64 = 8.gib(),
    writableLayerSizeInBytes: UInt64? = nil,
    readOnly: Bool = false,
    networking: Bool = true,
    progress: ProgressHandler? = nil,
    configuration: (inout LinuxContainer.Configuration) throws -> Void
) async throws -> LinuxContainer
```

`:287` — by image + pre-prepared rootfs Mount (lowest-level, used by the other two internally):
```swift
public mutating func create(
    _ id: String,
    image: Image,
    rootfs: Mount,
    writableLayer: Mount? = nil,
    networking: Bool = true,
    configuration: (inout LinuxContainer.Configuration) throws -> Void
) async throws -> LinuxContainer
```

### Other public methods

- `:323` — `releaseNetwork(_ id: String) throws` (mutating)
- `:329` — `delete(_ id: String) throws` (mutating)

**Important:** `ContainerManager` does **not** have `start`/`stop`/`statistics` methods. Lifecycle calls go directly to the returned `LinuxContainer` (see Section B).

---

## B. LinuxContainer

**File:** `.build/checkouts/containerization/Sources/Containerization/LinuxContainer.swift`

```swift
public final class LinuxContainer: Container, Sendable {
    public let id: String
    public let rootfs: Mount
    public let writableLayer: Mount?
    public let config: Configuration
}
```

**Sendability:** explicitly `Sendable` (verified `:30`). Risk #4 from the original research plan ("`LinuxContainer` Sendability is unverified locally") is **resolved**.

### Initializers

`:266` — convenience init with closure config:
```swift
public convenience init(
    _ id: String,
    rootfs: Mount,
    writableLayer: Mount? = nil,
    vmm: VirtualMachineManager,
    logger: Logger? = nil,
    configuration: (inout Configuration) throws -> Void
) throws
```

`:298` — full init:
```swift
public init(
    _ id: String,
    rootfs: Mount,
    writableLayer: Mount? = nil,
    vmm: VirtualMachineManager,
    configuration: LinuxContainer.Configuration,
    logger: Logger? = nil
) throws
```

In practice we will use **`ContainerManager.create(...)`** (Section A) rather than calling these inits directly — `ContainerManager` constructs the `vmm` internally.

### Lifecycle methods (all `public func ... async throws`)

| Method | Line | Notes |
|---|---|---|
| `create() async throws` | `:511` | Boots the VM and prepares the container rootfs. |
| `start() async throws` | `:631` | Starts the init process. |
| `stop() async throws` | `:708` | Graceful stop. |
| `kill(_ signal: Int32) async throws` | `:821` | Force-kill with signal. |
| `wait(timeoutInSeconds: Int64? = nil) async throws -> ExitStatus` | `:830` | Block until exit. |
| `resize(to: Terminal.Size) async throws` | `:843` | TTY resize. |
| `closeStdin() async throws` | `:936` | Close stdin pipe. |

### `statistics(...)` — closes CHAOS-1362 in PR3

`:955`:
```swift
public func statistics(categories: StatCategory = .all) async throws -> ContainerStatistics
```

The `categories` parameter is defaulted to `.all`. Implementer can omit at call site.

### Process-attach methods (out of scope for CHAOS-1424)

The `:852`, `:891`, `:927`, `:1010`, `:1116` methods (process attach, vsock, file copy in/out) belong to a separate "process-attach bridge" effort, NOT this ticket.

---

## C. Kernel

**File:** `.build/checkouts/containerization/Sources/Containerization/Kernel.swift`

```swift
public struct Kernel: Sendable, Codable {
    public var path: URL                     // :70 — vmlinux binary location
    public var platform: SystemPlatform      // :72
    public var commandLine: Self.CommandLine // :74

    public var kernelArgs: [String] { ... }  // :77
    public var initArgs: [String] { ... }    // :82

    public init(...)                          // :86

    public struct CommandLine: Sendable, Codable {
        public var kernelArgs: [String]      // :41
        public var initArgs: [String]        // :43
        public init(...)                      // :47, :58
        // mutating addDebug() :31, addPanic(level:) :36
    }
}
```

**Acquisition strategy** — the `Kernel` value is constructed directly with a vmlinux URL. There is **no SDK-provided default-kernel API**. Implications for CHAOS-1424:

1. The runtime must locate or fetch a vmlinux binary itself. Options:
   - **Bundled**: ship vmlinux in `Resources/` (license + size cost — likely a no-go).
   - **Pulled-on-first-use**: fetch from a known URL into `~/.container-compose/cache/vmlinux-<platform>`; verify checksum; surface `RuntimeError.kernelUnavailable(reason:)` on failure (case added in PR1, see `Runtime.swift`).
   - **User-provided path**: env var `CONTAINER_COMPOSE_KERNEL_PATH` overrides; if unset, fall through to pulled-on-first-use.

2. PR4 of the 4-PR plan owns kernel acquisition. PR2 can stub `Kernel` construction with a single hard-coded path + a TODO; the dynamic test target supplies a real vmlinux out-of-band.

---

## D. ContainerStatistics — closes CHAOS-1362 in PR3

**File:** `.build/checkouts/containerization/Sources/Containerization/ContainerStatistics.swift:18-46`

```swift
public struct ContainerStatistics: Sendable {
    public var id: String
    public var process: ProcessStatistics?
    public var memory: MemoryStatistics?
    public var cpu: CPUStatistics?
    public var blockIO: BlockIOStatistics?
    public var networks: [NetworkStatistics]?
    public var memoryEvents: MemoryEventStatistics?
}
```

**Sub-structs** (all `Sendable`, all-`public`-stored-properties — easy translation to the existing `RuntimeStatistics` shape):

- `ProcessStatistics` — `current: UInt64`, `limit: UInt64`
- `MemoryStatistics` — `usageBytes`, `limitBytes`, `swapUsageBytes`, `swapLimitBytes`, `cacheBytes`, `kernelStackBytes`, `slabBytes`, `pageFaults`, `majorPageFaults`, `inactiveFile`, `anon` (all `UInt64`) — the original Leak #7 inference of "`memory.usageBytes` / `memory.limitBytes`" was correct.
- `CPUStatistics` — read source for fields (PR3 implementer)
- `BlockIOStatistics` — read source for fields
- `NetworkStatistics` — array, per-interface counters (`receivedBytes`, `transmittedBytes`)
- `MemoryEventStatistics` — `oomKill: UInt64` and friends

**Mapping to `RuntimeStatistics`** is a PR3 deliverable. The translator should be a pure value-to-value function, easy to unit-test without a live VM.

---

## E. Confirmed deltas vs the original (inferred) research plan

| Item | Inferred plan | Verified reality |
|---|---|---|
| `ContainerManager.create` signature | `(configuration:image:kernel:options:)` | `(_:image:rootfs:writableLayer:networking:configuration:)` (3 overloads). **Kernel passed at `ContainerManager.init`, NOT per-create.** |
| `LinuxContainer.statistics` signature | `() async throws -> ContainerStatistics` | `(categories: StatCategory = .all) async throws -> ContainerStatistics` |
| `LinuxContainer` Sendability | "unverified" | **Sendable** (`LinuxContainer.swift:30`) |
| Kernel acquisition | "`ClientKernel.getDefaultKernel(for:)` (referenced obliquely)" | **No such method in apple/containerization.** Caller constructs `Kernel` from a URL. |
| `ContainerManager` mutability | not noted | **`mutating` on `create`/`releaseNetwork`/`delete`** — actor-isolated stored property required |

These corrections will save PR2 implementer 0.5–1 day of code-then-discover-API-doesn't-match.

---

## F. Out-of-scope but worth noting

- **Image / ImageStore types** are referenced extensively but not detailed here — PR2 implementer should read `Sources/Containerization/Image.swift` and `Sources/Containerization/ImageStore.swift` directly when wiring `create()`.
- **VirtualMachineManager** is internal to `ContainerManager.init`; we never construct it directly.
- **`@available(macOS 26.0, *)`** isn't on the SDK types directly — gating is by `#if os(macOS)` + `import Virtualization` (see `ContainerManager.swift:17-29`). Our `RuntimeError.requiresMacOS26(operation:)` (added in PR1) is the explicit chokepoint when we add platform-version checks in PR2.
- **`Mount` type** (used pervasively as rootfs / writableLayer / initfs) is in the same SDK — not detailed here, PR2 implementer reads on demand.
