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

#if os(macOS)

import Containerization
import Foundation

// MARK: - AppleContainerizationRuntime

/// Native `Runtime` conformer that targets `apple/containerization` directly,
/// bypassing apple/container's CLI/XPC daemon. CHAOS-1346 Phase 1 ships this
/// in a SKELETAL state per the Oracle architecture review (2026-04-30):
///
/// - `list` / `get`: fully backed by `ContainerRegistry`.
/// - `create` / `start` / `stop` / `kill` / `wait` / `remove`: drive registry
///   state transitions and emit synthesized events. They do NOT yet invoke
///   `ContainerManager.create(...)` / `LinuxContainer.start()` etc. Phase 2
///   wires those through (and adds the kernel/initfs acquisition flow). The
///   `apple/containerization` import is present so the dependency wiring is
///   verified at build time and Phase 2 can fill the bodies in without
///   touching call sites.
/// - `logs`: drains a per-container `LogRingBuffer` (registered at create).
/// - `events`: replays from a per-instance event continuation registry.
/// - `statistics`: returns an empty snapshot tagged with `id`; Phase 2 wires
///   `LinuxContainer.statistics(...)`.
///
/// Gating: `#if os(macOS)` only in Phase 1 (apple/containerization does not
/// compile on Linux). Phase 1 does not yet call any macOS-26-only API on
/// `ContainerManager` / `LinuxContainer`; the `@available(macOS 26.0, *)`
/// gate documented in the Phase 0 spike report (§5) attaches to the methods
/// that actually invoke `Virtualization.framework` types in Phase 2 — adding
/// it now would prevent the unit tests below from compiling under
/// Swift Testing's `@Suite` macro.
///
/// Concurrency: the conformer is an actor. Mutable state (event subscribers
/// and per-container `LogRingBuffer` references) lives inside actor
/// isolation. The registry is itself an actor so cross-process safety is
/// handled there.
public actor AppleContainerizationRuntime: Runtime {

    // MARK: - State

    private let registry: ContainerRegistry
    private let logCapacity: Int

    private var stdoutBuffers: [String: LogRingBuffer] = [:]
    private var stderrBuffers: [String: LogRingBuffer] = [:]

    /// CHAOS-1424 PR1 scaffold: per-id map of live `LinuxContainer` instances
    /// produced by `ContainerManager.create(...)`. PR1 ships the empty map +
    /// test affordance only. PR2 populates it during `create()` (after
    /// `registry.register`) and evicts during `remove()`. Keys mirror
    /// `stdoutBuffers` / `stderrBuffers` — the same `id` used everywhere else.
    /// `LinuxContainer` is `Sendable` (verified at
    /// `.build/checkouts/containerization/Sources/Containerization/LinuxContainer.swift:30`)
    /// so the actor's isolation boundary suffices; we never expose raw
    /// `LinuxContainer` values across the actor edge — see
    /// `_testLifecycleMap(for:)` for the read-only Bool affordance pattern.
    private var liveContainers: [String: LinuxContainer] = [:]

    private var eventContinuations: [UUID: AsyncStream<RuntimeContainerEvent>.Continuation] = [:]

    // MARK: - Init

    public init(registry: ContainerRegistry, logCapacity: Int = 4_096) {
        self.registry = registry
        self.logCapacity = logCapacity
    }

    // MARK: - Discovery

    public func version() async throws -> RuntimeVersion {
        RuntimeVersion(
            apiVersion: "v1",
            daemonVersion: Main.version,
            serverName: "container-compose",
            backendDescription: "apple-containerization 0.31.0",
            arch: AppleContainerizationRuntime.runtimeArch
        )
    }

    public func list(filters: RuntimeListFilters) async throws -> [RuntimeContainer] {
        let records = await registry.list()
        return records
            .map { $0.toRuntimeContainer() }
            .filter { filters.matches($0) }
    }

    /// CHAOS-1347 Phase 3 wiring note: the native runtime does not yet keep
    /// durable network metadata alongside `ContainerRegistry` records, and
    /// Phase 2 route handlers need a successful empty response while the
    /// server/API surface lands. Network enumeration will be backed by the
    /// native networking model when lifecycle wiring moves beyond the
    /// registry-only skeleton.
    public func listNetworks() async throws -> [RuntimeNetwork] {
        []
    }

    public func get(id: String) async throws -> RuntimeContainer {
        guard let record = await registry.get(id: id) else {
            throw RuntimeError.notFound(id: id)
        }
        return record.toRuntimeContainer()
    }

    // MARK: - Lifecycle (registry-only in Phase 1)

    public func create(
        id: String,
        configuration: RuntimeCreateConfiguration
    ) async throws -> RuntimeContainer {
        if await registry.get(id: id) != nil {
            throw RuntimeError.alreadyExists(id: id)
        }
        let now = Date()
        let record = RuntimeContainerRecord(
            id: id,
            imageReference: configuration.imageReference,
            createdAt: now,
            state: .created,
            publishedPorts: configuration.publishedPorts
        )
        try await registry.register(record)
        stdoutBuffers[id] = LogRingBuffer(source: .stdout, capacity: logCapacity)
        stderrBuffers[id] = LogRingBuffer(source: .stderr, capacity: logCapacity)
        emit(.created(id: id, at: now))
        return record.toRuntimeContainer()
    }

    public func start(id: String) async throws {
        guard let record = await registry.get(id: id) else {
            throw RuntimeError.notFound(id: id)
        }
        guard record.state == .created || record.state == .stopped || record.state == .exited else {
            throw RuntimeError.invalidState(
                id: id,
                expected: .created,
                actual: record.state
            )
        }
        let now = Date()
        try await registry.updateState(id: id, state: .running, startedAt: now)
        emit(.started(id: id, at: now))
    }

    public func stop(id: String, options: RuntimeStopOptions) async throws {
        guard let record = await registry.get(id: id) else {
            throw RuntimeError.notFound(id: id)
        }
        guard record.state == .running else {
            return
        }
        let now = Date()
        try await registry.updateState(id: id, state: .stopping)
        let exit = RuntimeExitStatus(exitCode: 0, exitedAt: now)
        try await registry.recordExit(id: id, exitStatus: exit)
        try? stdoutBuffers[id]?.close()
        try? stderrBuffers[id]?.close()
        emit(.stopped(id: id, exitCode: exit.exitCode, at: now))
    }

    public func kill(id: String, signal: Int32) async throws {
        guard await registry.get(id: id) != nil else {
            throw RuntimeError.notFound(id: id)
        }
        emit(.killed(id: id, signal: signal, at: Date()))
    }

    public func wait(id: String, timeoutSeconds: Int) async throws -> RuntimeExitStatus {
        guard let record = await registry.get(id: id) else {
            throw RuntimeError.notFound(id: id)
        }
        if let exit = record.exitStatus {
            return exit
        }
        throw RuntimeError.timeout(id: id, seconds: timeoutSeconds)
    }

    public func remove(id: String, force: Bool) async throws {
        guard let record = await registry.get(id: id) else {
            throw RuntimeError.notFound(id: id)
        }
        if record.state == .running && !force {
            throw RuntimeError.invalidState(id: id, expected: .stopped, actual: record.state)
        }
        try await registry.remove(id: id)
        stdoutBuffers.removeValue(forKey: id)
        stderrBuffers.removeValue(forKey: id)
        emit(.removed(id: id, at: Date()))
    }

    // MARK: - Observability

    public func logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame> {
        guard await registry.get(id: id) != nil else {
            throw RuntimeError.notFound(id: id)
        }
        let stdout = stdoutBuffers[id]
        let stderr = stderrBuffers[id]
        let frames = AppleContainerizationRuntime.merge(
            stdout: stdout?.replay(options: options) ?? [],
            stderr: stderr?.replay(options: options) ?? []
        )
        return AsyncStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    public func events() async throws -> AsyncStream<RuntimeContainerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RuntimeContainerEvent>.makeStream()
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self, id] _ in
            Task { await self?.unsubscribe(eventID: id) }
        }
        return stream
    }

    public func statistics(for id: String) async throws -> RuntimeStatistics {
        guard await registry.get(id: id) != nil else {
            throw RuntimeError.notFound(id: id)
        }
        // CHAOS-1424 PR4 / closes CHAOS-1362: when PR3's lifecycle wiring has
        // populated `liveContainers`, route through the real vsock statistics
        // path. Until then (registry-only fallback) the map stays empty and we
        // emit the structurally valid empty snapshot — same behavior as
        // pre-PR4, so existing clients see no regression.
        if let container = liveContainers[id] {
            let raw = try await container.statistics(categories: .all)
            return Self.translate(raw, id: id)
        }
        return RuntimeStatistics(id: id, sampledAt: Date())
    }

    /// Pure value-to-value mapping from the `apple/containerization`
    /// `ContainerStatistics` shape to our backend-neutral `RuntimeStatistics`.
    /// Kept `internal static` so static-target tests can construct
    /// `ContainerStatistics` directly and exercise every field without a live
    /// `LinuxContainer`. Field mapping verified against
    /// `.build/checkouts/containerization/Sources/Containerization/ContainerStatistics.swift`
    /// (closes Leak #7 in `docs/plans/runtime-abstraction-leaks.md`).
    static func translate(_ raw: ContainerStatistics, id: String) -> RuntimeStatistics {
        RuntimeStatistics(
            id: id,
            cpuUsageUsec: raw.cpu?.usageUsec,
            memoryUsageBytes: raw.memory?.usageBytes,
            memoryLimitBytes: raw.memory?.limitBytes,
            oomKillCount: raw.memoryEvents?.oomKill,
            networks: (raw.networks ?? []).map {
                RuntimeStatistics.Network(
                    interface: $0.interface,
                    receivedBytes: $0.receivedBytes,
                    transmittedBytes: $0.transmittedBytes
                )
            },
            sampledAt: Date()
        )
    }

    // MARK: - Test affordances

    /// Snapshot of currently-registered log buffer for `id`. Returns nil if
    /// the container has not been created on this runtime instance. Used by
    /// static tests to assert ring-buffer wiring without exercising the
    /// `apple/containerization` Writer push path (which requires a live VM).
    public func _testStdoutBuffer(for id: String) -> LogRingBuffer? {
        stdoutBuffers[id]
    }

    public func _testStderrBuffer(for id: String) -> LogRingBuffer? {
        stderrBuffers[id]
    }

    /// CHAOS-1424 PR1: returns `true` iff a live `LinuxContainer` is currently
    /// registered for `id` in the lifecycle map. Returns a Bool rather than
    /// the raw `LinuxContainer` so the actor's isolation boundary is
    /// preserved — callers can't leak the upstream type across the edge. PR2
    /// populates the map; PR1 ships it empty so this affordance always
    /// returns `false` until lifecycle wiring lands.
    public func _testLifecycleMap(for id: String) -> Bool {
        liveContainers[id] != nil
    }

    // MARK: - Private

    private func unsubscribe(eventID: UUID) {
        eventContinuations.removeValue(forKey: eventID)
    }

    private func emit(_ event: RuntimeContainerEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    /// Merge two pre-sorted-by-timestamp frame lists into a single stable
    /// chronological order. Callers pass already-filtered frames from the
    /// per-source `LogRingBuffer.replay(...)`, so each input is sorted
    /// already; we just zip-merge.
    private static func merge(
        stdout: [RuntimeLogFrame],
        stderr: [RuntimeLogFrame]
    ) -> [RuntimeLogFrame] {
        var merged: [RuntimeLogFrame] = []
        merged.reserveCapacity(stdout.count + stderr.count)
        var i = 0
        var j = 0
        while i < stdout.count && j < stderr.count {
            if stdout[i].timestamp <= stderr[j].timestamp {
                merged.append(stdout[i])
                i += 1
            } else {
                merged.append(stderr[j])
                j += 1
            }
        }
        if i < stdout.count { merged.append(contentsOf: stdout[i...]) }
        if j < stderr.count { merged.append(contentsOf: stderr[j...]) }
        return merged
    }

    private static var runtimeArch: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    // MARK: - Error mapping

    /// Map an upstream error from `apple/containerization` (or any other
    /// source) into the backend-neutral `RuntimeError` vocabulary via the
    /// shared `RuntimeErrorMapper`. See `RuntimeErrorMapper.map(_:id:)` for
    /// the full mapping table.
    ///
    /// In Phase 1, the only upstream errors that reach this conformer come from
    /// `ContainerRegistry` disk persistence (already mapped to
    /// `RuntimeError.persistenceFailure`) or from `apple/containerization`
    /// lifecycle APIs that Phase 2 will wire. Using the shared mapper ensures
    /// that Phase 2 lifecycle bodies get consistent translation for free —
    /// `ContainerizationError(.notFound)`, `VolumeError`, and NSCocoaErrors
    /// all map correctly without any per-call-site catch blocks.
    nonisolated private func mapUpstreamError(
        _ error: Error,
        id: String? = nil
    ) -> RuntimeError {
        RuntimeErrorMapper.map(error, id: id)
    }

    // MARK: - Phase 2 anchor

    /// Compile-time anchor that documents the `apple/containerization` types
    /// Phase 2 will wire into the lifecycle bodies above. Never called.
    /// Removing this would silently drop the `import Containerization`
    /// dependency check on a clean build.
    @inline(never)
    private static func _phase2DependencyAnchor() {
        let _: ContainerManager.Type = ContainerManager.self
        let _: LinuxContainer.Type = LinuxContainer.self
    }
}

// MARK: - Resource CRUD (CHAOS-1353)

extension AppleContainerizationRuntime {

    // MARK: Networks

    /// The native `apple/containerization` Swift package has no public Swift API
    /// for programmatic network creation or deletion as of Phase 8. The `container`
    /// CLI wraps platform networking via shell process invocations; we do not
    /// replicate those here. Documented as abstraction leak in
    /// `docs/plans/runtime-abstraction-leaks.md` (Leak #9).
    ///
    /// CHAOS-1409 IPAM note: when this conformer eventually supports
    /// `createNetwork`, it must plumb `spec.subnet` and `spec.gateway` into the
    /// returned `RuntimeNetwork`. If the `apple/containerization` API does not
    /// surface IPAM details after creation, leave `subnet`/`gateway` as `nil`
    /// on `RuntimeNetwork` and document the limitation here.
    public func createNetwork(spec: RuntimeCreateNetworkSpec) async throws -> RuntimeNetwork {
        throw RuntimeError.notSupported(
            operation: "createNetwork",
            conformer: "AppleContainerizationRuntime"
        )
    }

    /// See `createNetwork` for rationale. Documented as Leak #9.
    public func removeNetwork(id: String) async throws {
        throw RuntimeError.notSupported(
            operation: "removeNetwork",
            conformer: "AppleContainerizationRuntime"
        )
    }

    // MARK: Volumes

    public func listVolumes() async throws -> [RuntimeVolume] {
        try await RuntimeVolumeClient.list()
    }

    public func createVolume(spec: RuntimeCreateVolumeSpec) async throws -> RuntimeVolume {
        try await RuntimeVolumeClient.create(spec: spec)
    }

    public func removeVolume(name: String) async throws {
        try await RuntimeVolumeClient.remove(name: name)
    }

    // MARK: Secrets

    /// The native `apple/containerization` Swift package has no secret management
    /// surface. Phase 8 ships in-memory secrets only via `MockRuntime`; a durable
    /// backend (e.g. macOS Keychain) is deferred to Phase 9+. Documented as
    /// abstraction leak in `docs/plans/runtime-abstraction-leaks.md` (Leak #11).
    public func listSecrets() async throws -> [RuntimeSecret] {
        throw RuntimeError.notSupported(
            operation: "listSecrets",
            conformer: "AppleContainerizationRuntime"
        )
    }

    /// See `listSecrets` for rationale. Documented as Leak #11.
    public func createSecret(spec: RuntimeCreateSecretSpec) async throws -> RuntimeSecret {
        throw RuntimeError.notSupported(
            operation: "createSecret",
            conformer: "AppleContainerizationRuntime"
        )
    }

    /// See `listSecrets` for rationale. Documented as Leak #11.
    public func removeSecret(name: String) async throws {
        throw RuntimeError.notSupported(
            operation: "removeSecret",
            conformer: "AppleContainerizationRuntime"
        )
    }
}

#endif
