//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Runtime

/// The runtime abstraction boundary introduced by CHAOS-1346 Phase 1
/// (`docs/plans/native-api-server.md`).
///
/// Why this exists:
/// - Container-Compose is moving AWAY from depending on `apple/container`'s
///   CLI/XPC daemon and toward direct calls into the `apple/containerization`
///   Swift package. This protocol is the seam that lets us swap the backend
///   without touching every call site.
/// - Phase 1 defines the protocol and ships two conformers:
///   `BridgeContainerClientRuntime` (the safe default that delegates read
///   paths to the existing `ContainerClientProvider`) and the skeletal
///   `AppleContainerizationRuntime` (`@available(macOS 26.0, *)`, gated).
/// - One Compose command is wired through it as proof-of-life
///   (`compose ps` → `Runtime.list(filters:)`).
///
/// Sendable contract: every type touching this protocol is `Sendable`-clean.
/// Conformers should be actor or value-typed; production conformers must hold
/// no mutable shared state outside an actor or a documented locked region.
public protocol Runtime: Sendable {
    // MARK: - Discovery

    /// Return runtime/server metadata for the Container REST API surface added
    /// by CHAOS-1347 Phase 2. The shape intentionally stays backend-neutral:
    /// callers learn the API version, container-compose daemon version,
    /// selected backend description, and host architecture without importing
    /// apple/container or apple/containerization types.
    func version() async throws -> RuntimeVersion

    /// Return all containers visible to this runtime that match `filters`.
    /// CHAOS-1347 Phase 2 extends filters with status and name-prefix fields;
    /// conformers should keep treating unknown or empty filters as no-ops
    /// rather than throwing.
    func list(filters: RuntimeListFilters) async throws -> [RuntimeContainer]

    /// Return runtime-side network summaries needed by CHAOS-1347 Phase 2 route
    /// handlers. This is deliberately smaller than the HTTP API's
    /// `APINetworkSummary`: conformers expose only backend identity, driver,
    /// labels, and attached container ids so the server layer can adapt the
    /// response without leaking backend-specific network models.
    func listNetworks() async throws -> [RuntimeNetwork]

    /// Look up a single container by id. Conformers throw
    /// `RuntimeError.notFound(id:)` when no container exists with that id, so
    /// call sites can `try?` to coerce to nil — matching the established
    /// `ContainerClientProvider.get(id:)` contract.
    func get(id: String) async throws -> RuntimeContainer

    // MARK: - Lifecycle

    /// Create a container from an image reference + configuration. Returns
    /// the freshly registered `RuntimeContainer` snapshot. The container is
    /// in `.created` state — call `start(id:)` to actually run it.
    func create(
        id: String,
        configuration: RuntimeCreateConfiguration
    ) async throws -> RuntimeContainer

    // MARK: - Container Lifecycle Writes (CHAOS-1354)

    /// Transition a `.created` container to `.running`. Throws
    /// `RuntimeError.invalidState(id:expected:actual:)` if the container is
    /// not in `.created`.
    func start(id: String) async throws

    /// Stop a running container. The default `RuntimeStopOptions` sends
    /// SIGTERM and waits up to 10s before force-killing. Conformers may
    /// translate this to a SIGKILL-only path on backends that don't support
    /// graceful shutdown.
    func stop(id: String, options: RuntimeStopOptions) async throws

    /// Send an arbitrary signal to the container's init process.
    func kill(id: String, signal: Int32) async throws

    /// Block until the container exits or `timeoutSeconds` elapses.
    func wait(id: String, timeoutSeconds: Int) async throws -> RuntimeExitStatus

    /// Remove a stopped container's metadata + writable layer. `force`
    /// allows removal of running containers (sends SIGKILL first).
    func remove(id: String, force: Bool) async throws

    // MARK: - Observability

    /// Replay (and optionally follow) the container's stdout+stderr log
    /// stream. Returns an `AsyncStream` of timestamped frames. Phase 1
    /// emits frames from a per-container `LogRingBuffer`; the upstream
    /// library has no native log replay so all replay state lives in our
    /// ring buffer.
    func logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame>

    /// Subscribe to lifecycle events synthesized at this runtime's call
    /// sites. Conformers emit events on every create / start / stop /
    /// kill / wait / remove transition. Polling-based event sources
    /// (e.g. OOM detection) deliver into the same stream.
    func events() async throws -> AsyncStream<RuntimeContainerEvent>

    /// Single polled statistics snapshot. For streaming, the API server's
    /// stats endpoint maintains its own polling loop on top of this.
    func statistics(for id: String) async throws -> RuntimeStatistics

    // MARK: - Image lifecycle (CHAOS-1425, Leak #14)

    /// Pull one or more images and emit a stream of `RuntimePullEvent`s.
    /// The daemon's typical caller passes one spec per registry-resident
    /// service; conformers iterate sequentially and emit `started` →
    /// `completed`/`failed` per spec. When `ignoreFailures` is true the
    /// stream continues after a `failed` frame; otherwise the stream
    /// terminates (the consumer decides whether to surface the failure).
    /// Conformers that lack pull capability (e.g. fully synthetic mocks)
    /// MAY emit synthetic frames instead of throwing.
    func pull(
        specs: [RuntimePullSpec],
        ignoreFailures: Bool
    ) async throws -> AsyncStream<RuntimePullEvent>

    /// Build one or more images and emit a stream of `RuntimeBuildEvent`s.
    /// Today most conformers throw `RuntimeError.notSupported(...)` because
    /// the daemon does not yet receive compose-file context (Dockerfile
    /// path, build context directory) — CHAOS-1426 unblocks that. The
    /// protocol method exists so the route layer can stop emitting fully
    /// synthetic frames and instead respond to the conformer's actual
    /// capability.
    func build(
        specs: [RuntimeBuildSpec]
    ) async throws -> AsyncStream<RuntimeBuildEvent>

    // MARK: - Commands

    /// Execute a command inside a running container and return captured output.
    func exec(id: String, command: [String], options: RuntimeExecOptions) async throws -> RuntimeExecResult

    /// Return a process-list snapshot for a running container.
    func processes(id: String) async throws -> RuntimeProcessList

    /// Push an image reference from the runtime host to its configured registry.
    func pushImage(reference: String) async throws -> RuntimeImagePushResult

    // MARK: - Resource CRUD (CHAOS-1353)

    // MARK: Networks

    /// Create a network from the given spec. Returns the newly created network.
    /// Conformers throw `RuntimeError.alreadyExists(id:)` (using the name as id)
    /// if a network with that name already exists.
    func createNetwork(spec: RuntimeCreateNetworkSpec) async throws -> RuntimeNetwork

    /// Remove a network by id. Conformers throw `RuntimeError.notFound(id:)` if
    /// no network with that id exists.
    func removeNetwork(id: String) async throws

    // MARK: Volumes

    /// Return all volumes visible to this runtime.
    func listVolumes() async throws -> [RuntimeVolume]

    /// Create a volume from the given spec. Returns the newly created volume.
    /// Conformers throw `RuntimeError.alreadyExists(id:)` (using the name as id)
    /// if a volume with that name already exists.
    func createVolume(spec: RuntimeCreateVolumeSpec) async throws -> RuntimeVolume

    /// Remove a volume by name. Conformers throw `RuntimeError.notFound(id:)` if
    /// no volume with that name exists.
    func removeVolume(name: String) async throws

    // MARK: Secrets

    /// Return all secret metadata visible to this runtime. Secret values are
    /// NEVER included in the response; only metadata (name, labels, createdAt).
    func listSecrets() async throws -> [RuntimeSecret]

    /// Create a secret from the given spec. Returns the newly created secret
    /// metadata (the value is not echoed back). Conformers throw
    /// `RuntimeError.alreadyExists(id:)` (using the name as id) if a secret
    /// with that name already exists.
    func createSecret(spec: RuntimeCreateSecretSpec) async throws -> RuntimeSecret

    /// Remove a secret by name. Conformers throw `RuntimeError.notFound(id:)`
    /// if no secret with that name exists.
    func removeSecret(name: String) async throws
}

public extension Runtime {
    func pull(
        specs: [RuntimePullSpec],
        ignoreFailures: Bool
    ) async throws -> AsyncStream<RuntimePullEvent> {
        throw RuntimeError.notSupported(
            operation: "pull",
            conformer: String(describing: Self.self)
        )
    }

    func build(
        specs: [RuntimeBuildSpec]
    ) async throws -> AsyncStream<RuntimeBuildEvent> {
        throw RuntimeError.notSupported(
            operation: "build",
            conformer: String(describing: Self.self)
        )
    }
}

// MARK: - RuntimeError

/// Errors a `Runtime` conformer can throw. Distinct from
/// `ContainerizationError` (the upstream Swift package's error type) so call
/// sites stay independent of any specific backend.
///
/// ## Upstream-error mapping convention
///
/// Each conformer is responsible for mapping its own backend-specific error
/// types into the `RuntimeError` vocabulary at the point where it calls the
/// upstream API. The mapping must be exhaustive: well-known upstream cases map
/// to the specific `RuntimeError` that best describes the situation (e.g.
/// `ContainerizationError(.notFound)` → `.notFound(id:)`), and every other
/// upstream error falls back to `.backendFailure(message:)` so the abstraction
/// boundary is never breached. Each conformer encapsulates this logic in a
/// private `mapUpstreamError(_ error: Error, id: String? = nil) -> RuntimeError`
/// helper so throw sites stay readable and the mapping is tested in one place.
/// Example for the Bridge conformer:
///
/// ```swift
/// private func mapUpstreamError(_ error: Error, id: String? = nil) -> RuntimeError {
///     if let ce = error as? ContainerizationError, BridgeContainerClientRuntime.isNotFound(ce) {
///         return .notFound(id: id ?? "unknown")
///     }
///     return .backendFailure(message: error.localizedDescription)
/// }
/// ```
public enum RuntimeError: Error, Sendable, Equatable {
    case notFound(id: String)
    case alreadyExists(id: String)
    case invalidState(id: String, expected: RuntimeContainerStatus, actual: RuntimeContainerStatus)
    case timeout(id: String, seconds: Int)
    case imageNotFound(reference: String)
    case notSupported(operation: String, conformer: String)
    case backendFailure(message: String)
    case persistenceFailure(message: String)
    /// Apple's `container` (or `container-compose`) binary could not be located
    /// in the resolution PATH. CHAOS-1421 — see
    /// `docs/reviews/path-execution-audit-2026-05-05.md`.
    case cliBinaryNotFound(binary: String, searchPath: String)
    /// An explicit env-var override was set but does not point to an executable
    /// file. Setting the override is a user contract, so we fail loudly rather
    /// than silently falling back to the resolution PATH.
    case binaryOverrideInvalid(envVar: String, path: String)
    /// The native `apple/containerization` lifecycle requires macOS 26+ APIs
    /// (Virtualization.framework + the `@available(macOS 26.0, *)` SDK gate).
    /// CHAOS-1424 — Phase 2 lifecycle methods short-circuit with this on
    /// pre-26 hosts rather than silently writing a registry-only record.
    case requiresMacOS26(operation: String)
    /// vmlinux kernel could not be acquired by the native runtime (missing
    /// binary, unreadable cache, or network failure during fetch). CHAOS-1424
    /// — Phase 2 surfaces this when `LinuxContainer` cannot be instantiated
    /// because the `Kernel` value is unobtainable.
    case kernelUnavailable(reason: String)
}

extension Runtime {
    public func exec(id: String, command: [String], options: RuntimeExecOptions) async throws -> RuntimeExecResult {
        throw RuntimeError.notSupported(operation: "exec", conformer: String(describing: Self.self))
    }

    public func processes(id: String) async throws -> RuntimeProcessList {
        throw RuntimeError.notSupported(operation: "processes", conformer: String(describing: Self.self))
    }

    public func pushImage(reference: String) async throws -> RuntimeImagePushResult {
        throw RuntimeError.notSupported(operation: "pushImage", conformer: String(describing: Self.self))
    }
}

extension RuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Runtime: container '\(id)' not found"
        case .alreadyExists(let id):
            return "Runtime: container '\(id)' already exists"
        case .invalidState(let id, let expected, let actual):
            return "Runtime: container '\(id)' has invalid state (expected \(expected.rawValue), actual \(actual.rawValue))"
        case .timeout(let id, let seconds):
            return "Runtime: container '\(id)' timed out after \(seconds)s"
        case .imageNotFound(let reference):
            return "Runtime: image '\(reference)' not found"
        case .notSupported(let operation, let conformer):
            return "Runtime: operation '\(operation)' is not supported by '\(conformer)'"
        case .backendFailure(let message):
            return "Runtime backend failure: \(message)"
        case .persistenceFailure(let message):
            return "Runtime persistence failure: \(message)"
        case .cliBinaryNotFound(let binary, let searchPath):
            return "Runtime: '\(binary)' CLI not found in PATH (\(searchPath)). Install Apple's container CLI or set CONTAINER_COMPOSE_CONTAINER_BIN to its absolute path."
        case .binaryOverrideInvalid(let envVar, let path):
            return "Runtime: \(envVar)='\(path)' is not an executable file. Unset the env var or point it at an executable."
        case .requiresMacOS26(let operation):
            return "Runtime: operation '\(operation)' requires macOS 26.0 or later. Upgrade the host or use a remote daemon over tls://."
        case .kernelUnavailable(let reason):
            return "Runtime: vmlinux kernel unavailable — \(reason)."
        }
    }
}

// MARK: - RuntimeEnvironment (task-local injection)

/// Task-local holder for the active `Runtime`. Mirrors the established
/// `ContainerClientEnvironment` and `RunnerEnvironment` patterns: production
/// code reads `RuntimeEnvironment.current`; tests bind a recording conformer
/// via `RuntimeEnvironment.$current.withValue(recorder) { ... }`.
///
/// Default conformer is `BridgeContainerClientRuntime`. This keeps existing
/// dev / CI flows byte-identical (the bridge delegates read paths to the
/// already-injected `ContainerClientProvider`) while still proving the
/// abstraction at the call site of `compose ps`.
///
/// On a deployment-ready macOS 26 host with the virtualization entitlement
/// and a vmlinux kernel staged, an opt-in selector (env var or hidden flag,
/// to be wired in Phase 2) swaps in `AppleContainerizationRuntime`.
public enum RuntimeEnvironment {
    @TaskLocal public static var current: any Runtime = BridgeContainerClientRuntime()
}
