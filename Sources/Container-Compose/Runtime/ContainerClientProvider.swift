//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
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
import Logging

// MARK: - ContainerClientProvider

/// Abstracts the upstream `ContainerClient` and `NetworkClient` programmatic
/// API surfaces that `Container-Compose` reaches into for container lifecycle
/// queries (list / get / stop / delete) and network existence probing.
///
/// This is the second seam in the test-harness story (per
/// `docs/plans/PLAN-recorder-seam.md` §10 Q2). The first seam,
/// `RunCommandRunner`, intercepts argv-emitting upstream calls (`container run`,
/// `Application.ImagePull.parse(...).run()` etc.). `ContainerClientProvider`
/// covers the orthogonal class of upstream calls — pure Swift API
/// invocations that talk to the API server over XPC and return values, with
/// no argv at all.
///
/// Production binding (`ProductionContainerClientProvider`) wraps the real
/// `ContainerClient()` / `NetworkClient()` byte-for-byte. Tests can substitute
/// `RecordingContainerClientProvider` (in `Tests/TestHelpers/`) to record
/// calls and stub responses, so a `RuntimeArgvTests`-style test never
/// reaches the live runtime — even on hosts where Apple `container` is not
/// installed.
public protocol ContainerClientProvider: Sendable {
    /// Mirrors `ContainerClient.create(configuration:options:kernel:initImage:)`
    /// after constructing the upstream `ContainerConfiguration` shape from the
    /// runtime-neutral create configuration.
    func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> ContainerSnapshot

    /// Mirrors `ContainerClient.list(filters:)`.
    func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot]

    /// Mirrors `ContainerClient.get(id:)`. Throws `ContainerizationError(.notFound)`
    /// when no container exists with the given id (existing call sites already
    /// wrap with `try?` to coerce this to `nil`).
    func get(id: String) async throws -> ContainerSnapshot

    /// Mirrors `ContainerClient.stop(id:opts:)`.
    func stop(id: String, opts: ContainerStopOptions) async throws

    /// Mirrors `ContainerClient.delete(id:force:)`.
    func delete(id: String, force: Bool) async throws

    /// Mirrors `ContainerClient.logs(id:)`. Returns the live log file handles
    /// for the given container. The recorder fake throws "no container" so
    /// `ComposeLogs` falls into its existing error-print branch and exits
    /// cleanly under tests, never blocking on a real `ContainerClient` call.
    func logs(id: String) async throws -> [FileHandle]

    func logs(id: String, options: ContainerLogOptions) async throws -> [FileHandle]

    /// Mirrors `NetworkClient.get(id:)`. Returns `NetworkState` — note this is
    /// `NetworkState`, not `NetworkConfiguration`, per the upstream API. Throws
    /// `ContainerizationError(.notFound)` when no network with the given id
    /// exists (existing call sites use `try?` + `== nil` to mean "create it").
    func networkGet(id: String) async throws -> NetworkState

    /// Mirrors `ContainerClient.events()`. Returns buffered lifecycle events
    /// recorded by the container runtime (create, start, stop, die, destroy).
    func events() async throws -> [ContainerEvent]

    /// Mirrors the static `ClientImage.list()` upstream call. Used by
    /// `pullImage` and `buildService` paths to short-circuit a pull when the
    /// image already exists locally. The recorder fake returns `[]` so those
    /// short-circuits never fire under tests — the seam-routed pull / build
    /// invocation always proceeds and is captured by the `RunCommandRunner`
    /// recorder.
    func imageList() async throws -> [ClientImage]

    /// Mirrors `ContainerClient.stats(id:)`. Returns a single polled statistics
    /// snapshot for the container, suitable for feeding into the stats stream
    /// polling loop of `BridgeContainerClientRuntime.statistics(for:)`.
    /// Throws `ContainerizationError(.notFound)` when no container with `id`
    /// exists — call sites translate this to `RuntimeError.notFound`.
    func stats(id: String) async throws -> ContainerStats

    // MARK: - Lifecycle Provider Methods (CHAOS-1354)

    /// Mirrors `ContainerClient.kill(id:signal:)`. Sends an arbitrary POSIX
    /// signal to the container's init process. Call sites translate any
    /// upstream `ContainerizationError` to the appropriate `RuntimeError`.
    func kill(id: String, signal: Int32) async throws

    /// Bootstrap the container's init process and start it in detached mode.
    /// This is the combined "start" operation for an already-created container:
    /// `ContainerClient.bootstrap(id:stdio:)` + `ClientProcess.start()`.
    /// Throws `ContainerizationError` on any failure; call sites translate to
    /// `RuntimeError.backendFailure`.
    func start(id: String) async throws
}

public extension ContainerClientProvider {
    func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> ContainerSnapshot {
        throw RuntimeError.notSupported(
            operation: "create",
            conformer: String(describing: Self.self)
        )
    }
}

// MARK: - ProductionContainerClientProvider

/// The default binding used in production. Each method instantiates a fresh
/// upstream client — matches the previous direct-instantiation pattern at
/// every call site (`let client = ContainerClient()` followed by a single
/// call), so behavior is unchanged.
public struct ProductionContainerClientProvider: ContainerClientProvider {
    public init() {}

    public func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> ContainerSnapshot {
        var process = Flags.Process()
        process.env = configuration.environment
        process.cwd = configuration.workingDirectory
        process.user = configuration.user

        var management = Flags.Management()
        management.capAdd = configuration.capabilities?.add ?? []
        management.capDrop = configuration.capabilities?.drop ?? []
        management.name = id
        management.publishPorts = configuration.publishedPorts.map(Self.publishArg)
        management.readOnly = configuration.readOnly ?? false

        var resource = Flags.Resource()
        resource.cpus = Int64(configuration.cpus)
        resource.memory = "\(configuration.memoryInBytes)"

        let (containerConfig, kernel, initImage) = try await Utility.containerConfigFromFlags(
            id: id,
            image: configuration.imageReference,
            arguments: configuration.command,
            process: process,
            management: management,
            resource: resource,
            registry: Flags.Registry(),
            imageFetch: Flags.ImageFetch(),
            progressUpdate: { _ in },
            log: Logger(label: "container-compose.bridge-create")
        )

        let client = ContainerClient()
        try await client.create(
            configuration: containerConfig,
            options: .default,
            kernel: kernel,
            initImage: initImage
        )
        return try await client.get(id: id)
    }

    public func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] {
        try await ContainerClient().list(filters: filters)
    }

    public func get(id: String) async throws -> ContainerSnapshot {
        try await ContainerClient().get(id: id)
    }

    public func stop(id: String, opts: ContainerStopOptions) async throws {
        try await ContainerClient().stop(id: id, opts: opts)
    }

    public func delete(id: String, force: Bool) async throws {
        try await ContainerClient().delete(id: id, force: force)
    }

    public func logs(id: String) async throws -> [FileHandle] {
        try await ContainerClient().logs(id: id)
    }

    public func logs(id: String, options: ContainerLogOptions) async throws -> [FileHandle] {
        try await ContainerClient().logs(id: id, options: options)
    }

    public func events() async throws -> [ContainerEvent] {
        try await ContainerClient().events()
    }

    public func networkGet(id: String) async throws -> NetworkState {
        try await NetworkClient().get(id: id)
    }

    public func imageList() async throws -> [ClientImage] {
        try await ClientImage.list()
    }

    public func stats(id: String) async throws -> ContainerStats {
        try await ContainerClient().stats(id: id)
    }

    // MARK: - Lifecycle Provider Methods (CHAOS-1354)

    public func kill(id: String, signal: Int32) async throws {
        try await ContainerClient().kill(id: id, signal: signal)
    }

    public func start(id: String) async throws {
        // Bootstrap the container's init process in detached mode (no stdio
        // attached — the container-compose daemon does not hold a tty for an
        // already-created container launched via the REST API). The bootstrap
        // call is idempotent on an already-running container.
        let client = ContainerClient()
        let process = try await client.bootstrap(
            id: id,
            stdio: [nil, nil, nil],
            dynamicEnv: [:]
        )
        try await process.start()
    }

    private static func publishArg(for port: RuntimePublishedPort) -> String {
        let hostPort = port.count > 1 ? "\(port.hostPort)-\(port.hostPort + port.count - 1)" : "\(port.hostPort)"
        let containerPort = port.count > 1 ? "\(port.containerPort)-\(port.containerPort + port.count - 1)" : "\(port.containerPort)"
        let proto = port.proto == .udp ? "/udp" : ""
        return "\(port.hostAddress):\(hostPort):\(containerPort)\(proto)"
    }
}

// MARK: - ContainerClientEnvironment (task-local injection)

/// Task-local holder for the active `ContainerClientProvider`. Production code
/// reads `ContainerClientEnvironment.current` directly; tests bind a recording
/// provider via
/// `ContainerClientEnvironment.$current.withValue(provider) { … }`.
///
/// Mirrors the `RunnerEnvironment` task-local pattern used for the
/// argv-emitting seam (`RunCommandRunner`). Per Swift concurrency rules, the
/// binding propagates to unstructured `Task { }` blocks (only `Task.detached`
/// resets it, and we don't use that anywhere).
public enum ContainerClientEnvironment {
    /// Default is the production binding so call sites can read
    /// `ContainerClientEnvironment.current` without nil-checking.
    @TaskLocal public static var current: any ContainerClientProvider = ProductionContainerClientProvider()
}
