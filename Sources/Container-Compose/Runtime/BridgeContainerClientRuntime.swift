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

    public func list(filters: RuntimeListFilters) async throws -> [RuntimeContainer] {
        let provider = ContainerClientEnvironment.current
        let snapshots = try await provider.list(filters: .all)
        return snapshots.map(BridgeContainerClientRuntime.translate(snapshot:))
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

    // MARK: - Observability (intentionally not supported in Phase 1)

    public func logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame> {
        throw RuntimeError.notSupported(
            operation: "logs",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    public func events() async throws -> AsyncStream<RuntimeContainerEvent> {
        throw RuntimeError.notSupported(
            operation: "events",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    public func statistics(for id: String) async throws -> RuntimeStatistics {
        throw RuntimeError.notSupported(
            operation: "statistics",
            conformer: "BridgeContainerClientRuntime"
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
}
