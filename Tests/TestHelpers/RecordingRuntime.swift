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
        case list
        case get(id: String)
        case create(id: String)
        case start(id: String)
        case stop(id: String)
        case kill(id: String, signal: Int32)
        case wait(id: String)
        case remove(id: String, force: Bool)
        case logs(id: String)
        case events
        case statistics(id: String)
    }

    public private(set) var entries: [Entry] = []
    private let stubbedContainers: [RuntimeContainer]

    public init(stubbedContainers: [RuntimeContainer] = []) {
        self.stubbedContainers = stubbedContainers
    }

    // MARK: - Runtime

    public func list(filters: RuntimeListFilters) async throws -> [RuntimeContainer] {
        entries.append(.list)
        return stubbedContainers
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
        entries.append(.logs(id: id))
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func events() async throws -> AsyncStream<RuntimeContainerEvent> {
        entries.append(.events)
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func statistics(for id: String) async throws -> RuntimeStatistics {
        entries.append(.statistics(id: id))
        return RuntimeStatistics(id: id, sampledAt: Date())
    }

    // MARK: - Test affordances

    public func entriesSnapshot() async -> [Entry] {
        entries
    }
}
