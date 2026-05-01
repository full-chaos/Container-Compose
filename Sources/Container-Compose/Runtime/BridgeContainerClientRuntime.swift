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

import ContainerAPIClient
import ContainerResource
import Foundation

// MARK: - BridgeContainerClientRuntime

/// `Runtime` conformer that delegates the read paths (`list`, `get`) to the
/// existing `ContainerClientProvider` (which talks to apple/container's
/// XPC daemon under the hood). Lifecycle / write paths
/// (`create` / `start` / `stop` / `kill` / `wait` / `remove`) intentionally
/// throw `RuntimeError.notSupported`: those continue to flow through
/// `RunCommandRunner` until Phase 2/3 migrates each command to the native
/// `AppleContainerizationRuntime`.
///
/// Why this conformer is the Phase 1 default
/// (`RuntimeEnvironment.current` initial value):
/// - Strategically, container-compose is moving AWAY from apple/container's
///   CLI/XPC daemon. Operationally, we cannot move the read paths there
///   yet because the native conformer needs macOS 26 + the virtualization
///   entitlement + a kernel binary — none of which is on a typical
///   contributor laptop or CI runner.
/// - The bridge gives us the `Runtime` seam at the call site of
///   `compose ps` with zero behavior change. When the deployment story is
///   solved, the default flips (or an explicit selector swaps in
///   `AppleContainerizationRuntime`).
///
/// Read translation: `ContainerSnapshot` → `RuntimeContainer`. We translate
/// once at the boundary so call sites observe only `RuntimeContainer`. The
/// translation is intentionally lossy on fields the Phase 1 surface does not
/// expose (e.g. `networks`, `health`, `platform`); add them to
/// `RuntimeContainer` as more commands migrate.
public struct BridgeContainerClientRuntime: Runtime {

    public init() {}

    // MARK: - Discovery

    public func version() async throws -> RuntimeVersion {
        RuntimeVersion(
            apiVersion: "v1",
            daemonVersion: Main.version,
            serverName: "container-compose",
            backendDescription: "bridge (apple/container CLI)",
            arch: BridgeContainerClientRuntime.runtimeArch
        )
    }

    public func list(filters: RuntimeListFilters) async throws -> [RuntimeContainer] {
        let provider = ContainerClientEnvironment.current
        let snapshots = try await provider.list(filters: .all)
        return snapshots
            .map(BridgeContainerClientRuntime.translate(snapshot:))
            .filter { filters.matches($0) }
    }

    public func listNetworks() async throws -> [RuntimeNetwork] {
        // ContainerClientProvider currently exposes networkGet(id:) for
        // existence probing but no NetworkClient.list equivalent. Keep this
        // explicit so CHAOS-1347 Phase 3 can wire network enumeration when the
        // provider grows that API instead of silently returning partial data.
        throw RuntimeError.notSupported(
            operation: "listNetworks",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    public func get(id: String) async throws -> RuntimeContainer {
        let provider = ContainerClientEnvironment.current
        do {
            let snapshot = try await provider.get(id: id)
            return BridgeContainerClientRuntime.translate(snapshot: snapshot)
        } catch {
            throw RuntimeError.notFound(id: id)
        }
    }

    // MARK: - Lifecycle (intentionally not supported in Phase 1)

    public func create(
        id: String,
        configuration: RuntimeCreateConfiguration
    ) async throws -> RuntimeContainer {
        throw RuntimeError.notSupported(
            operation: "create",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    public func start(id: String) async throws {
        throw RuntimeError.notSupported(
            operation: "start",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    public func stop(id: String, options: RuntimeStopOptions) async throws {
        let provider = ContainerClientEnvironment.current
        let opts = ContainerStopOptions(
            timeoutInSeconds: Int32(options.timeoutSeconds),
            signal: options.signal
        )
        try await provider.stop(id: id, opts: opts)
    }

    public func kill(id: String, signal: Int32) async throws {
        throw RuntimeError.notSupported(
            operation: "kill",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    public func wait(id: String, timeoutSeconds: Int) async throws -> RuntimeExitStatus {
        throw RuntimeError.notSupported(
            operation: "wait",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    public func remove(id: String, force: Bool) async throws {
        let provider = ContainerClientEnvironment.current
        try await provider.delete(id: id, force: force)
    }

    // MARK: - Observability

    public func logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame> {
        let provider = ContainerClientEnvironment.current
        let handles: [FileHandle]
        do {
            handles = try await provider.logs(
                id: id,
                options: ContainerLogOptions(since: options.since, timestamps: options.timestamps)
            )
        } catch {
            throw RuntimeError.notFound(id: id)
        }

        return BridgeContainerClientRuntime.streamLogs(from: handles, options: options)
    }

    public func events() async throws -> AsyncStream<RuntimeContainerEvent> {
        let provider = ContainerClientEnvironment.current
        return AsyncStream { continuation in
            let task = Task {
                var lastTimestamp: Date?

                // `ContainerClient.events()` returns the daemon's buffered
                // lifecycle event snapshot rather than a push stream. Poll at
                // the CLI's existing 1s cadence and yield only events newer
                // than the last emitted timestamp.
                while !Task.isCancelled {
                    do {
                        let events = try await provider.events()
                            .filter { event in
                                guard let lastTimestamp else { return true }
                                return event.timestamp > lastTimestamp
                            }
                            .sorted { $0.timestamp < $1.timestamp }

                        for event in events {
                            continuation.yield(BridgeContainerClientRuntime.translate(event: event))
                            if lastTimestamp == nil || event.timestamp > lastTimestamp! {
                                lastTimestamp = event.timestamp
                            }
                        }

                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch is CancellationError {
                        break
                    } catch {
                        continuation.finish()
                        break
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func statistics(for id: String) async throws -> RuntimeStatistics {
        let provider = ContainerClientEnvironment.current
        let raw: ContainerStats
        do {
            raw = try await provider.stats(id: id)
        } catch {
            // Translate ContainerizationError(.notFound) and any other upstream
            // error to the appropriate RuntimeError so route handlers can handle
            // them without importing ContainerAPIClient.
            throw RuntimeError.notFound(id: id)
        }
        return BridgeContainerClientRuntime.translate(stats: raw)
    }

    // MARK: - Stats translation

    static func translate(stats: ContainerStats) -> RuntimeStatistics {
        let network: [RuntimeStatistics.Network]
        if let rx = stats.networkRxBytes, let tx = stats.networkTxBytes {
            // The bridge rolls all interfaces into one aggregate "eth0" entry;
            // per-interface breakdown is not available via ContainerStats today.
            // Abstraction leak documented in docs/plans/runtime-abstraction-leaks.md.
            network = [RuntimeStatistics.Network(interface: "eth0", receivedBytes: rx, transmittedBytes: tx)]
        } else {
            network = []
        }
        return RuntimeStatistics(
            id: stats.id,
            cpuUsageUsec: stats.cpuUsageUsec,
            memoryUsageBytes: stats.memoryUsageBytes,
            memoryLimitBytes: stats.memoryLimitBytes,
            oomKillCount: nil, // Not available via ContainerStats; MemoryEventStatistics needed
            networks: network,
            sampledAt: Date()
        )
    }

    // MARK: - Translation

    /// Translate an upstream `ContainerSnapshot` into the apple-free
    /// `RuntimeContainer` shape. The `id` from `configuration.id` matches
    /// what the existing `compose ps` filter logic expects (project-prefix
    /// match), so call sites see byte-identical IDs.
    static func translate(snapshot: ContainerSnapshot) -> RuntimeContainer {
        RuntimeContainer(
            id: snapshot.configuration.id,
            imageReference: snapshot.configuration.image.reference,
            status: translate(status: snapshot.status),
            publishedPorts: snapshot.configuration.publishedPorts.map(translate(port:)),
            createdAt: nil,
            startedAt: snapshot.startedDate,
            lastExitCode: snapshot.lastExitCode
        )
    }

    static func translate(status: RuntimeStatus) -> RuntimeContainerStatus {
        switch status {
        case .running: return .running
        case .stopped: return .stopped
        case .stopping: return .stopping
        case .unknown: return .unknown
        }
    }

    static func translate(port: PublishPort) -> RuntimePublishedPort {
        RuntimePublishedPort(
            hostAddress: port.hostAddress.description,
            hostPort: port.hostPort,
            containerPort: port.containerPort,
            proto: port.proto == .udp ? .udp : .tcp,
            count: port.count
        )
    }

    static func translate(event: ContainerEvent) -> RuntimeContainerEvent {
        switch event.action {
        case .create:
            return .created(id: event.containerId, at: event.timestamp)
        case .start:
            return .started(id: event.containerId, at: event.timestamp)
        case .stop, .die:
            return .stopped(id: event.containerId, exitCode: 0, at: event.timestamp)
        case .destroy:
            return .removed(id: event.containerId, at: event.timestamp)
        }
    }

    private static func streamLogs(
        from handles: [FileHandle],
        options: RuntimeLogOptions
    ) -> AsyncStream<RuntimeLogFrame> {
        AsyncStream { continuation in
            let task = Task {
                let frames = await collectLogFrames(from: handles)
                let selected = applyTail(options.tail, to: frames)
                for frame in selected {
                    continuation.yield(frame)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
                for handle in handles {
                    try? handle.close()
                }
            }
        }
    }

    private static func collectLogFrames(from handles: [FileHandle]) async -> [RuntimeLogFrame] {
        var frames: [RuntimeLogFrame] = []
        for (index, handle) in handles.enumerated() {
            let source: RuntimeLogFrame.Source = index == 0 ? .stdout : .stderr
            frames.append(contentsOf: await collectLogFrames(from: handle, source: source))
        }
        return frames.sorted { $0.timestamp < $1.timestamp }
    }

    private static func collectLogFrames(
        from handle: FileHandle,
        source: RuntimeLogFrame.Source
    ) async -> [RuntimeLogFrame] {
        var frames: [RuntimeLogFrame] = []
        var line = Data()

        do {
            for try await byte in handle.bytes {
                if Task.isCancelled { break }
                if byte == 10 {
                    appendLogFrame(line: &line, source: source, to: &frames)
                } else {
                    line.append(byte)
                }
            }
            appendLogFrame(line: &line, source: source, to: &frames)
        } catch {
            appendLogFrame(line: &line, source: source, to: &frames)
        }

        return frames
    }

    private static func appendLogFrame(
        line: inout Data,
        source: RuntimeLogFrame.Source,
        to frames: inout [RuntimeLogFrame]
    ) {
        if line.last == 13 {
            line.removeLast()
        }
        guard !line.isEmpty else { return }
        frames.append(RuntimeLogFrame(timestamp: Date(), source: source, data: line))
        line.removeAll(keepingCapacity: true)
    }

    private static func applyTail(_ tail: Int?, to frames: [RuntimeLogFrame]) -> [RuntimeLogFrame] {
        guard let tail, tail >= 0, tail < frames.count else { return frames }
        return Array(frames.suffix(tail))
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
}
