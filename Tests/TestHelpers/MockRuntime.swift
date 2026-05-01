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
@testable import ContainerComposeCore

public extension RuntimeVersion {
    /// Stable version payload for CHAOS-1348's in-memory runtime portability
    /// proof (`docs/plans/native-api-server.md`, Phase 3).
    static var mockDefault: RuntimeVersion {
        RuntimeVersion(
            apiVersion: "v1",
            daemonVersion: Main.version,
            serverName: "container-compose",
            backendDescription: "mock-runtime",
            arch: MockRuntime.runtimeArch
        )
    }
}

/// In-memory `Runtime` conformer for CHAOS-1348 Phase 3
/// (`docs/plans/native-api-server.md`).
///
/// Unlike `RecordingRuntime`, this fake is a state machine: lifecycle calls
/// mutate an actor-isolated registry, list/get observe that state, and events
/// plus log-follow streams broadcast to every active subscriber. That proves
/// the production `Runtime` boundary can host a non-apple/container backend
/// while keeping static tests independent of virtualization entitlements.
///
/// Concurrency: the actor owns every mutable collection. `AsyncStream`
/// continuations are `Sendable`; termination callbacks hop back onto the actor
/// with `Task { [weak self] ... }` before mutating subscriber dictionaries.
public final actor MockRuntime: Runtime {

    // MARK: - State

    private var containers: [String: RuntimeContainer]
    private var networks: [RuntimeNetwork]
    private var volumes: [String: RuntimeVolume]
    private var secrets: [String: RuntimeSecret]
    private let mockVersion: RuntimeVersion

    private var eventContinuations: [UUID: AsyncStream<RuntimeContainerEvent>.Continuation] = [:]
    private var logBuffers: [String: [RuntimeLogFrame]] = [:]
    private var logContinuations: [String: [UUID: AsyncStream<RuntimeLogFrame>.Continuation]] = [:]
    private var statisticsSnapshots: [String: RuntimeStatistics] = [:]

    // MARK: - Init

    public init(
        containers: [RuntimeContainer] = [],
        networks: [RuntimeNetwork] = [],
        volumes: [RuntimeVolume] = [],
        secrets: [RuntimeSecret] = [],
        version: RuntimeVersion = .mockDefault
    ) {
        self.containers = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
        self.networks = networks
        self.volumes = Dictionary(uniqueKeysWithValues: volumes.map { ($0.name, $0) })
        self.secrets = Dictionary(uniqueKeysWithValues: secrets.map { ($0.name, $0) })
        self.mockVersion = version
        self.logBuffers = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, []) })
    }

    // MARK: - Runtime

    public func version() async throws -> RuntimeVersion {
        mockVersion
    }

    public func list(filters: RuntimeListFilters) async throws -> [RuntimeContainer] {
        containers.values
            .filter { filters.matches($0) }
            .sorted { $0.id < $1.id }
    }

    public func listNetworks() async throws -> [RuntimeNetwork] {
        networks.sorted { $0.name < $1.name }
    }

    public func get(id: String) async throws -> RuntimeContainer {
        guard let container = containers[id] else {
            throw RuntimeError.notFound(id: id)
        }
        return container
    }

    public func create(
        id: String,
        configuration: RuntimeCreateConfiguration
    ) async throws -> RuntimeContainer {
        guard containers[id] == nil else {
            throw RuntimeError.alreadyExists(id: id)
        }

        let now = Date()
        let container = RuntimeContainer(
            id: id,
            imageReference: configuration.imageReference,
            status: .created,
            publishedPorts: configuration.publishedPorts,
            createdAt: now
        )
        containers[id] = container
        logBuffers[id] = []
        publish(.created(id: id, at: now))
        return container
    }

    public func start(id: String) async throws {
        let container = try requireContainer(id: id)
        guard container.status == .created else {
            throw RuntimeError.invalidState(id: id, expected: .created, actual: container.status)
        }

        let now = Date()
        containers[id] = RuntimeContainer(
            id: container.id,
            imageReference: container.imageReference,
            status: .running,
            publishedPorts: container.publishedPorts,
            createdAt: container.createdAt,
            startedAt: now,
            lastExitCode: container.lastExitCode
        )
        publish(.started(id: id, at: now))
    }

    public func stop(id: String, options: RuntimeStopOptions) async throws {
        let container = try requireContainer(id: id)
        guard container.status == .running else {
            throw RuntimeError.invalidState(id: id, expected: .running, actual: container.status)
        }

        let now = Date()
        containers[id] = RuntimeContainer(
            id: container.id,
            imageReference: container.imageReference,
            status: .stopped,
            publishedPorts: container.publishedPorts,
            createdAt: container.createdAt,
            startedAt: container.startedAt,
            lastExitCode: 0
        )
        publish(.stopped(id: id, exitCode: 0, at: now))
    }

    public func kill(id: String, signal: Int32) async throws {
        let container = try requireContainer(id: id)
        guard container.status == .running else {
            throw RuntimeError.invalidState(id: id, expected: .running, actual: container.status)
        }

        let now = Date()
        containers[id] = RuntimeContainer(
            id: container.id,
            imageReference: container.imageReference,
            status: .stopped,
            publishedPorts: container.publishedPorts,
            createdAt: container.createdAt,
            startedAt: container.startedAt,
            lastExitCode: 128 + signal
        )
        publish(.killed(id: id, signal: signal, at: now))
    }

    public func wait(id: String, timeoutSeconds: Int) async throws -> RuntimeExitStatus {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            let container = try requireContainer(id: id)
            if container.status == .stopped || container.status == .exited {
                return RuntimeExitStatus(exitCode: container.lastExitCode ?? 0, exitedAt: Date())
            }
            if Date() >= deadline {
                throw RuntimeError.timeout(id: id, seconds: timeoutSeconds)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    public func remove(id: String, force: Bool) async throws {
        let container = try requireContainer(id: id)
        if container.status == .running && !force {
            throw RuntimeError.invalidState(id: id, expected: .stopped, actual: container.status)
        }

        containers.removeValue(forKey: id)
        logBuffers.removeValue(forKey: id)
        finishLogSubscribers(forContainerID: id)
        statisticsSnapshots.removeValue(forKey: id)
        publish(.removed(id: id, at: Date()))
    }

    public func logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame> {
        _ = try requireContainer(id: id)
        let replay = filteredLogFrames(forContainerID: id, options: options)
        let (stream, continuation) = AsyncStream<RuntimeLogFrame>.makeStream()
        for frame in replay {
            continuation.yield(frame)
        }

        guard options.follow else {
            continuation.finish()
            return stream
        }

        let subscriptionID = UUID()
        logContinuations[id, default: [:]][subscriptionID] = continuation
        continuation.onTermination = { @Sendable [weak self, id, subscriptionID] _ in
            Task { await self?.unsubscribeLog(containerID: id, subscriptionID: subscriptionID) }
        }
        return stream
    }

    public func events() async throws -> AsyncStream<RuntimeContainerEvent> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<RuntimeContainerEvent>.makeStream()
        eventContinuations[subscriptionID] = continuation
        continuation.onTermination = { @Sendable [weak self, subscriptionID] _ in
            Task { await self?.unsubscribeEvent(subscriptionID: subscriptionID) }
        }
        return stream
    }

    public func statistics(for id: String) async throws -> RuntimeStatistics {
        _ = try requireContainer(id: id)
        if let snapshot = statisticsSnapshots[id] {
            return snapshot
        }
        return RuntimeStatistics(id: id, sampledAt: Date())
    }

    // MARK: - Test affordances

    public func injectLogFrame(_ frame: RuntimeLogFrame, forContainerID id: String) async {
        logBuffers[id, default: []].append(frame)
        if let continuations = logContinuations[id]?.values {
            for continuation in continuations {
                continuation.yield(frame)
            }
        }
    }

    public func injectEvent(_ event: RuntimeContainerEvent) async {
        publish(event)
    }

    public func injectStatistics(_ statistics: RuntimeStatistics, forContainerID id: String) async throws {
        _ = try requireContainer(id: id)
        statisticsSnapshots[id] = statistics
    }

    public func snapshot() async -> [String: RuntimeContainer] {
        containers
    }

    // MARK: - Private

    private func requireContainer(id: String) throws -> RuntimeContainer {
        guard let container = containers[id] else {
            throw RuntimeError.notFound(id: id)
        }
        return container
    }

    private func publish(_ event: RuntimeContainerEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func filteredLogFrames(
        forContainerID id: String,
        options: RuntimeLogOptions
    ) -> [RuntimeLogFrame] {
        var frames = logBuffers[id, default: []]
        if let since = options.since {
            frames = frames.filter { $0.timestamp >= since }
        }
        frames.sort { $0.timestamp < $1.timestamp }
        if let tail = options.tail, tail >= 0, frames.count > tail {
            frames = Array(frames.suffix(tail))
        }
        return frames
    }

    private func unsubscribeEvent(subscriptionID: UUID) {
        eventContinuations.removeValue(forKey: subscriptionID)
    }

    private func unsubscribeLog(containerID: String, subscriptionID: UUID) {
        logContinuations[containerID]?.removeValue(forKey: subscriptionID)
        if logContinuations[containerID]?.isEmpty == true {
            logContinuations.removeValue(forKey: containerID)
        }
    }

    private func finishLogSubscribers(forContainerID id: String) {
        let continuations = logContinuations.removeValue(forKey: id) ?? [:]
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    public static var runtimeArch: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

// MARK: - Resource CRUD (CHAOS-1353)

extension MockRuntime {

    // MARK: Networks

    public func createNetwork(spec: RuntimeCreateNetworkSpec) async throws -> RuntimeNetwork {
        if networks.contains(where: { $0.name == spec.name }) {
            throw RuntimeError.alreadyExists(id: spec.name)
        }
        let network = RuntimeNetwork(
            id: UUID().uuidString,
            name: spec.name,
            driver: spec.driver,
            labels: spec.labels,
            attachedContainerIds: []
        )
        networks.append(network)
        return network
    }

    public func removeNetwork(id: String) async throws {
        guard let index = networks.firstIndex(where: { $0.id == id }) else {
            throw RuntimeError.notFound(id: id)
        }
        networks.remove(at: index)
    }

    // MARK: Volumes

    public func listVolumes() async throws -> [RuntimeVolume] {
        volumes.values.sorted { $0.name < $1.name }
    }

    public func createVolume(spec: RuntimeCreateVolumeSpec) async throws -> RuntimeVolume {
        if volumes[spec.name] != nil {
            throw RuntimeError.alreadyExists(id: spec.name)
        }
        let volume = RuntimeVolume(
            name: spec.name,
            driver: spec.driver,
            labels: spec.labels,
            createdAt: Date()
        )
        volumes[spec.name] = volume
        return volume
    }

    public func removeVolume(name: String) async throws {
        guard volumes[name] != nil else {
            throw RuntimeError.notFound(id: name)
        }
        volumes.removeValue(forKey: name)
    }

    // MARK: Secrets

    public func listSecrets() async throws -> [RuntimeSecret] {
        secrets.values.sorted { $0.name < $1.name }
    }

    public func createSecret(spec: RuntimeCreateSecretSpec) async throws -> RuntimeSecret {
        if secrets[spec.name] != nil {
            throw RuntimeError.alreadyExists(id: spec.name)
        }
        let secret = RuntimeSecret(
            name: spec.name,
            labels: spec.labels,
            createdAt: Date()
        )
        // Value is stored but never exposed via the protocol — in-memory only.
        secrets[spec.name] = secret
        return secret
    }

    public func removeSecret(name: String) async throws {
        guard secrets[name] != nil else {
            throw RuntimeError.notFound(id: name)
        }
        secrets.removeValue(forKey: name)
    }

    // MARK: - Test affordances (CHAOS-1353)

    public func networksSnapshot() async -> [RuntimeNetwork] { networks }
    public func volumesSnapshot() async -> [RuntimeVolume] { Array(volumes.values) }
    public func secretsSnapshot() async -> [RuntimeSecret] { Array(secrets.values) }
}
