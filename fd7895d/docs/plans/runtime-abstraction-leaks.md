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
  `listNetworks`, `create`, `start`, `kill`, `wait`, `logs`, `events`, and
  `statistics`. These are conformance gaps in the bridge adapter, not protocol
  gaps; `MockRuntime` implements the full surface in memory.
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
