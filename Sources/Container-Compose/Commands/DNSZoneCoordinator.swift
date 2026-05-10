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

// MARK: - DNSZoneCoordinator

/// Actor that owns the cumulative `[CoreDNSConfig.ServiceRecord]` set the
/// embedded DNS sidecar serves. CHAOS-1446 Phase 4 / Lead Decision D5 +
/// architect FLAG 3 mandate that this state move OUT of `ComposeUp`
/// entirely so the parallel service-start TaskGroup cannot race on it.
///
/// Invariants this actor enforces:
///
/// 1. **Single source of truth**: only this actor calls
///    `EmbeddedDNSSidecar.refreshZone`. `ComposeUp` no longer carries
///    `dnsZoneServices` and no parallel child task touches the sidecar
///    handle directly.
///
/// 2. **Deduplication by service name**: `publish(record:)` replaces any
///    existing record with the same `name` so re-publish from a recreated
///    or adopted service produces a single entry per service in the zone.
///
/// 3. **Deterministic write ordering**: records are sorted by name before
///    every `refreshZone` call. Two parallel `publish` calls that race
///    into the actor produce the same final zone-file contents regardless
///    of which one wins the actor's internal scheduling.
///
/// 4. **Late-publish rejection (CR-6)**: `close()` flips a terminal flag.
///    Subsequent `publish(record:)` calls throw
///    `DNSZoneCoordinatorError.closed` instead of silently writing a stale
///    zone after the sidecar teardown has begun. The outer compose-up
///    catch path MUST call `close()` after draining the TaskGroup but
///    BEFORE issuing the sidecar teardown.
///
/// 5. **Lifetime**: the coordinator is constructed once per `compose up`
///    invocation. It is OPTIONAL because compose projects without any
///    selected networks (no project networks declared, no implicit
///    default) do not start a sidecar at all and therefore have no zone
///    to maintain. `ComposeUp` constructs the coordinator only when a
///    sidecar handle exists.
public actor DNSZoneCoordinator {

    /// The sidecar handle this coordinator publishes to. Captured at
    /// construction time so child tasks never reach into `ComposeUp`'s
    /// `dnsSidecar` field directly.
    private let handle: SidecarHandle

    /// Cumulative records keyed by service name for O(1) replace-on-update
    /// semantics. The dictionary is a value type local to the actor;
    /// readers (the `refreshZone` call) project to a sorted array.
    private var recordsByService: [String: CoreDNSConfig.ServiceRecord] = [:]

    /// Once flipped to `true` by `close()`, every subsequent
    /// `publish(record:)` throws `DNSZoneCoordinatorError.closed`. Set
    /// during the failure path BEFORE sidecar teardown so a slow Phase B
    /// task whose `publish` is still in-flight observes closure as a
    /// thrown error rather than silently overwriting the zone after the
    /// sidecar is gone.
    private var isClosed = false

    public init(handle: SidecarHandle) {
        self.handle = handle
    }

    // MARK: - Publish

    /// Add or replace `record` in the cumulative set, then issue exactly
    /// ONE `EmbeddedDNSSidecar.refreshZone` call with the sorted set.
    /// Throws `DNSZoneCoordinatorError.closed` if `close()` was previously
    /// called \u2014 the caller's per-service work is expected to surface this
    /// upstream so the originating `compose up` failure path is preserved.
    public func publish(record: CoreDNSConfig.ServiceRecord) throws {
        if isClosed {
            throw DNSZoneCoordinatorError.closed(serviceName: record.name)
        }
        recordsByService[record.name] = record
        try writeZone()
    }

    /// Mark the coordinator closed. Idempotent. Subsequent
    /// `publish(record:)` calls throw `.closed`. Must be called by the
    /// outer compose-up catch path AFTER the TaskGroup has drained but
    /// BEFORE `EmbeddedDNSSidecar.stop(handle:)` is issued, so any child
    /// task whose `publish` was racing the teardown observes closure
    /// (CR-6 step 4 in the architect's drain-order spec).
    public func close() {
        isClosed = true
    }

    // MARK: - Test affordances

    internal func currentRecords() -> [CoreDNSConfig.ServiceRecord] {
        sortedRecords()
    }

    internal var closed: Bool { isClosed }

    // MARK: - Internal helpers

    /// Project the cumulative set into a deterministic order before each
    /// `refreshZone` write. CoreDNS reload diffs the previous zone file
    /// against the new one; a stable order means re-publishing the same
    /// set produces an identical file (no spurious reload churn).
    private func sortedRecords() -> [CoreDNSConfig.ServiceRecord] {
        recordsByService.values.sorted { $0.name < $1.name }
    }

    private func writeZone() throws {
        try EmbeddedDNSSidecar.refreshZone(
            handle: handle,
            services: sortedRecords()
        )
    }
}

// MARK: - DNSZoneCoordinatorError

/// Errors a `DNSZoneCoordinator` can surface to its callers.
public enum DNSZoneCoordinatorError: Error, Sendable, LocalizedError, CustomStringConvertible {
    /// `publish(record:)` was called after `close()`. The caller's
    /// per-service work should propagate this so the originating failure
    /// is not masked by a successful late-publish silent-write.
    case closed(serviceName: String)

    public var description: String {
        switch self {
        case let .closed(serviceName):
            return "Refusing to publish DNS record for service '\(serviceName)': zone coordinator is closed."
        }
    }

    public var errorDescription: String? { description }
}
