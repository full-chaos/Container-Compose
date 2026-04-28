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

    /// Mirrors `NetworkClient.get(id:)`. Returns `NetworkState` — note this is
    /// `NetworkState`, not `NetworkConfiguration`, per the upstream API. Throws
    /// `ContainerizationError(.notFound)` when no network with the given id
    /// exists (existing call sites use `try?` + `== nil` to mean "create it").
    func networkGet(id: String) async throws -> NetworkState
}

// MARK: - ProductionContainerClientProvider

/// The default binding used in production. Each method instantiates a fresh
/// upstream client — matches the previous direct-instantiation pattern at
/// every call site (`let client = ContainerClient()` followed by a single
/// call), so behavior is unchanged.
public struct ProductionContainerClientProvider: ContainerClientProvider {
    public init() {}

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

    public func networkGet(id: String) async throws -> NetworkState {
        try await NetworkClient().get(id: id)
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
