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
@testable import ContainerComposeCore

/// Recording fake for `ContainerClientProvider` (the second seam, per
/// `docs/plans/PLAN-recorder-seam.md` §10 Q2).
///
/// Every method appends an `Entry` to the actor's log in time order, then
/// returns a "harmless" stub. The two read methods (`get(id:)`,
/// `networkGet(id:)`) intentionally THROW (rather than return some bogus
/// value) so the existing `try?` wrappers at call sites coerce to `nil` —
/// matching the behavior of the real client when the requested container or
/// network does not exist. This is the contract that makes
/// `RuntimeArgvTests`'s `cmd.run()` calls reach the `RunCommandRunner` seam
/// without first crashing on a missing container snapshot.
public actor RecordingContainerClientProvider: ContainerClientProvider {

    /// One entry per method call. Filters are serialized via `String(describing:)`
    /// because `ContainerListFilters` doesn't conform to `Equatable`.
    public enum Entry: Sendable, Equatable {
        case list(filters: String)
        case get(id: String)
        case stop(id: String)
        case delete(id: String, force: Bool)
        case logs(id: String)
        case networkGet(id: String)
        case imageList
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    // MARK: - ContainerClientProvider

    public func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] {
        entries.append(.list(filters: String(describing: filters)))
        // Empty list — call sites iterate, find nothing, and move on. This is
        // the same shape the real client returns on a host with no containers.
        return []
    }

    public func get(id: String) async throws -> ContainerSnapshot {
        entries.append(.get(id: id))
        // Throw to mimic "container not found". Call sites use `try?` to
        // coerce this to `nil`, which is the same code path as a real
        // not-found response from `ContainerClient.get(id:)`.
        throw NSError(
            domain: "RecordingContainerClientProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no container '\(id)' (recorded fake)"]
        )
    }

    public func stop(id: String, opts: ContainerStopOptions) async throws {
        entries.append(.stop(id: id))
    }

    public func delete(id: String, force: Bool) async throws {
        entries.append(.delete(id: id, force: force))
    }

    public func logs(id: String) async throws -> [FileHandle] {
        entries.append(.logs(id: id))
        // Throw to mimic "container not found" — `ComposeLogs.streamLogs`
        // catches and prints a warning, then returns cleanly.
        throw NSError(
            domain: "RecordingContainerClientProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no logs for container '\(id)' (recorded fake)"]
        )
    }

    public func networkGet(id: String) async throws -> NetworkState {
        entries.append(.networkGet(id: id))
        // Throw to mimic "network not found"; call sites use `try? ... == nil`
        // as the "should I create the network?" gate. Throwing keeps the
        // existing flow honest: under the recorder, the recorded request
        // proceeds to `setupNetwork`'s subsequent `RunRequest.swiftAPI` call.
        throw NSError(
            domain: "RecordingContainerClientProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no network '\(id)' (recorded fake)"]
        )
    }

    public func imageList() async throws -> [ClientImage] {
        entries.append(.imageList)
        // Empty list — `pullImage` and `buildService` short-circuit on
        // "image already exists?" and otherwise proceed to the seam-routed
        // pull/build invocation. Returning [] forces the seam call to
        // fire so the `RunCommandRunner` recorder captures it.
        return []
    }

    // MARK: - Test affordances

    /// Snapshot of recorded entries in time order.
    public func entriesSnapshot() async -> [Entry] {
        entries
    }
}
