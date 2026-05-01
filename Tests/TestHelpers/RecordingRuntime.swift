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

/// Recording fake for the `Runtime` protocol introduced by CHAOS-1346 Phase 1
/// (`docs/plans/native-api-server.md`).
///
/// Captures every method call as an `Entry` in time order and returns a
/// stubbed response, so static tests can assert which `Runtime` calls were
/// made by a Compose subcommand without ever reaching apple/containerization
/// or apple/container. Mirrors the established `RecordingRunner` and
/// `RecordingContainerClientProvider` patterns.
public actor RecordingRuntime: Runtime {

    public enum Entry: Sendable, Equatable {
        case version
        case list
        case listNetworks
        case get(id: String)
        case create(id: String)
        case start(id: String)
        case stop(id: String)
        case kill(id: String, signal: Int32)
        case wait(id: String)
        case remove(id: String, force: Bool)
        case logs(id: String, options: RuntimeLogOptions)
        case events
        case statistics(id: String)
        // CHAOS-1353
        case createNetwork(name: String)
        case removeNetwork(id: String)
        case listVolumes
        case createVolume(name: String)
        case removeVolume(name: String)
        case listSecrets
        case createSecret(name: String)
        case removeSecret(name: String)
    }

    public private(set) var entries: [Entry] = []
    private let stubbedContainers: [RuntimeContainer]
    private let stubbedNetworks: [RuntimeNetwork]
    private let stubbedVolumes: [RuntimeVolume]
    private let stubbedSecrets: [RuntimeSecret]
    private let stubbedEvents: [RuntimeContainerEvent]
    private let stubbedLogFrames: [RuntimeLogFrame]
    private let eventsError: RuntimeError?
    private let logsError: RuntimeError?
    private let statisticsError: RuntimeError?
    /// Single-snapshot shorthand. If set, `statistics(for:)` always returns this value.
    private let stubbedStatistics: RuntimeStatistics?
    /// Sequence of snapshots for streaming tests. The polling loop drains the
    /// sequence (one snapshot per call) and finishes the stream when exhausted.
    private let stubbedStatisticsSequence: [RuntimeStatistics]
    private var statisticsCallIndex: Int = 0

    public init(
        stubbedContainers: [RuntimeContainer] = [],
        stubbedNetworks: [RuntimeNetwork] = [],
        stubbedVolumes: [RuntimeVolume] = [],
        stubbedSecrets: [RuntimeSecret] = [],
        stubbedEvents: [RuntimeContainerEvent] = [],
        stubbedLogFrames: [RuntimeLogFrame] = [],
        eventsError: RuntimeError? = nil,
        logsError: RuntimeError? = nil,
        statisticsError: RuntimeError? = nil,
        stubbedStatistics: RuntimeStatistics? = nil,
        stubbedStatisticsSequence: [RuntimeStatistics] = []
    ) {
        self.stubbedContainers = stubbedContainers
        self.stubbedNetworks = stubbedNetworks
        self.stubbedVolumes = stubbedVolumes
        self.stubbedSecrets = stubbedSecrets
        self.stubbedEvents = stubbedEvents
        self.stubbedLogFrames = stubbedLogFrames
        self.eventsError = eventsError
        self.logsError = logsError
        self.statisticsError = statisticsError
        self.stubbedStatistics = stubbedStatistics
        self.stubbedStatisticsSequence = stubbedStatisticsSequence
    }

    // MARK: - Runtime

    public func version() async throws -> RuntimeVersion {
        entries.append(.version)
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "arm64"
        #endif
        return RuntimeVersion(
            apiVersion: "v1",
            daemonVersion: Main.version,
            serverName: "container-compose",
            backendDescription: "recording-runtime",
            arch: arch
        )
    }

    public func list(filters: RuntimeListFilters) async throws -> [RuntimeContainer] {
        entries.append(.list)
        return stubbedContainers.filter { filters.matches($0) }
    }

    public func listNetworks() async throws -> [RuntimeNetwork] {
        entries.append(.listNetworks)
        return stubbedNetworks
    }

    public func get(id: String) async throws -> RuntimeContainer {
        entries.append(.get(id: id))
        if let match = stubbedContainers.first(where: { $0.id == id }) {
            return match
        }
        throw RuntimeError.notFound(id: id)
    }

    public func create(
        id: String,
        configuration: RuntimeCreateConfiguration
    ) async throws -> RuntimeContainer {
        entries.append(.create(id: id))
        return RuntimeContainer(
            id: id,
            imageReference: configuration.imageReference,
            status: .created,
            publishedPorts: configuration.publishedPorts,
            createdAt: Date()
        )
    }

    public func start(id: String) async throws {
        entries.append(.start(id: id))
    }

    public func stop(id: String, options: RuntimeStopOptions) async throws {
        entries.append(.stop(id: id))
    }

    public func kill(id: String, signal: Int32) async throws {
        entries.append(.kill(id: id, signal: signal))
    }

    public func wait(id: String, timeoutSeconds: Int) async throws -> RuntimeExitStatus {
        entries.append(.wait(id: id))
        return RuntimeExitStatus(exitCode: 0, exitedAt: Date())
    }

    public func remove(id: String, force: Bool) async throws {
        entries.append(.remove(id: id, force: force))
    }

    public func logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame> {
        entries.append(.logs(id: id, options: options))
        if let logsError {
            throw logsError
        }
        let frames = stubbedLogFrames
        return AsyncStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    public func events() async throws -> AsyncStream<RuntimeContainerEvent> {
        entries.append(.events)
        if let eventsError {
            throw eventsError
        }
        let events = stubbedEvents
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    public func statistics(for id: String) async throws -> RuntimeStatistics {
        entries.append(.statistics(id: id))
        if let statisticsError {
            throw statisticsError
        }
        if let stubbedStatistics {
            return stubbedStatistics
        }
        // Drain the sequence: return successive snapshots, throw notFound when exhausted
        // (signals the streaming loop that the "container is gone").
        if !stubbedStatisticsSequence.isEmpty {
            if statisticsCallIndex < stubbedStatisticsSequence.count {
                let snapshot = stubbedStatisticsSequence[statisticsCallIndex]
                statisticsCallIndex += 1
                return snapshot
            } else {
                throw RuntimeError.notFound(id: id)
            }
        }
        return RuntimeStatistics(id: id, sampledAt: Date())
    }

    // MARK: - CHAOS-1353 resource CRUD

    public func createNetwork(spec: RuntimeCreateNetworkSpec) async throws -> RuntimeNetwork {
        entries.append(.createNetwork(name: spec.name))
        return RuntimeNetwork(
            id: UUID().uuidString,
            name: spec.name,
            driver: spec.driver,
            labels: spec.labels,
            attachedContainerIds: []
        )
    }

    public func removeNetwork(id: String) async throws {
        entries.append(.removeNetwork(id: id))
        guard stubbedNetworks.contains(where: { $0.id == id }) else {
            throw RuntimeError.notFound(id: id)
        }
    }

    public func listVolumes() async throws -> [RuntimeVolume] {
        entries.append(.listVolumes)
        return stubbedVolumes
    }

    public func createVolume(spec: RuntimeCreateVolumeSpec) async throws -> RuntimeVolume {
        entries.append(.createVolume(name: spec.name))
        return RuntimeVolume(
            name: spec.name,
            driver: spec.driver,
            labels: spec.labels,
            createdAt: Date()
        )
    }

    public func removeVolume(name: String) async throws {
        entries.append(.removeVolume(name: name))
        guard stubbedVolumes.contains(where: { $0.name == name }) else {
            throw RuntimeError.notFound(id: name)
        }
    }

    public func listSecrets() async throws -> [RuntimeSecret] {
        entries.append(.listSecrets)
        return stubbedSecrets
    }

    public func createSecret(spec: RuntimeCreateSecretSpec) async throws -> RuntimeSecret {
        entries.append(.createSecret(name: spec.name))
        return RuntimeSecret(
            name: spec.name,
            labels: spec.labels,
            createdAt: Date()
        )
    }

    public func removeSecret(name: String) async throws {
        entries.append(.removeSecret(name: name))
        guard stubbedSecrets.contains(where: { $0.name == name }) else {
            throw RuntimeError.notFound(id: name)
        }
    }

    // MARK: - Test affordances

    public func entriesSnapshot() async -> [Entry] {
        entries
    }
}
