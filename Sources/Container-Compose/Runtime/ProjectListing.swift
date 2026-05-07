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

/// Cross-command helper for listing the live containers that belong to a
/// specific Docker Compose project.
///
/// Both `ps` and `port` need to ask the runtime "what's running for this
/// project?" and decode container ids back into compose service names. The
/// logic was duplicated in `ComposePs` (CHAOS-1346 Phase 1) and forked again
/// when `port` migrated to runtime-driven listing (CHAOS-1440); this enum
/// centralizes it so both subcommands stay observably consistent.
public enum ProjectListing {

    /// One row in the listing — a container plus the compose service name it
    /// was scheduled under. Service names come from
    /// `parseServiceName(containerId:projectName:)`.
    public struct Entry: Sendable, Hashable {
        public let serviceName: String
        public let container: RuntimeContainer

        public init(serviceName: String, container: RuntimeContainer) {
            self.serviceName = serviceName
            self.container = container
        }
    }

    /// List containers belonging to `projectName`.
    ///
    /// The runtime is asked to filter by `namePrefix: "<projectName>-"` so the
    /// `<project>-<service>` convention enforced by `ComposeUp` becomes the
    /// source of truth. Containers that do not carry the expected prefix
    /// (e.g. created via an explicit `service.container_name:` override) are
    /// passed in via `additionalIds` if the caller still wants to surface
    /// them.
    ///
    /// Stable sort: `(serviceName, container.id)`. This keeps output
    /// deterministic across both commands and across runs.
    ///
    /// - Parameters:
    ///   - runtime: The active runtime conformer.
    ///   - projectName: The Compose project name (resolved by the caller).
    ///   - serviceFilter: When non-nil and non-empty, only entries whose
    ///     service name appears in the array are returned. `nil` or empty
    ///     means "no filter".
    ///   - includeStopped: When false (default), entries whose container
    ///     status is not `.running` are dropped.
    ///   - additionalIds: Container ids that should be surfaced even when
    ///     they do not match the `<projectName>-` prefix. Useful when
    ///     `service.container_name:` overrides bypass the convention.
    public static func list(
        runtime: any Runtime,
        projectName: String,
        serviceFilter: [String]? = nil,
        includeStopped: Bool = false,
        additionalIds: Set<String> = []
    ) async throws -> [Entry] {
        // Ask the runtime for the prefix-filtered set first.
        let prefix = "\(projectName)-"
        let prefixed = try await runtime.list(
            filters: RuntimeListFilters(namePrefix: prefix)
        )

        // If the caller has explicit ids that may live outside the prefix
        // namespace (`container_name:` overrides), pull those in too. Use a
        // second `list(.all)` call so we don't depend on the runtime to
        // honor a name set as a filter.
        var sidecars: [RuntimeContainer] = []
        if !additionalIds.isEmpty {
            let allMatchesAlreadyKnown = Set(prefixed.map(\.id))
            let outOfPrefix = additionalIds.subtracting(allMatchesAlreadyKnown)
            if !outOfPrefix.isEmpty {
                let everything = try await runtime.list(filters: .all)
                sidecars = everything.filter { outOfPrefix.contains($0.id) }
            }
        }

        var entries: [Entry] = []
        entries.reserveCapacity(prefixed.count + sidecars.count)

        for container in prefixed {
            guard let service = parseServiceName(
                containerId: container.id,
                projectName: projectName
            ) else { continue }
            entries.append(Entry(serviceName: service, container: container))
        }

        // For sidecars discovered via `additionalIds`, the container id is
        // the explicit override; we don't try to reverse it into a service
        // name. Caller code that needs a service-name → entry mapping should
        // pass `additionalIds` only when it can synthesize a label some other
        // way. Here we conservatively label them with the container id.
        for container in sidecars {
            entries.append(Entry(serviceName: container.id, container: container))
        }

        // `--all` semantics: drop non-running rows unless explicitly requested.
        if !includeStopped {
            entries.removeAll { $0.container.status != .running }
        }

        // Service filter (nil or empty == no filter).
        if let serviceFilter, !serviceFilter.isEmpty {
            let allowed = Set(serviceFilter)
            entries.removeAll { !allowed.contains($0.serviceName) }
        }

        // Stable sort by (serviceName, id).
        entries.sort { lhs, rhs in
            if lhs.serviceName != rhs.serviceName {
                return lhs.serviceName < rhs.serviceName
            }
            return lhs.container.id < rhs.container.id
        }

        return entries
    }

    /// Parse a container id of the form `"<project>-<service>"` or
    /// `"<project>-<service>-<N>"` (where `<N>` is a positive integer
    /// representing a scaled replica) into its bare service name.
    ///
    /// Examples:
    /// - `("myproj-redis", "myproj")` → `"redis"`
    /// - `("myproj-redis-2", "myproj")` → `"redis"` (replica suffix stripped)
    /// - `("myproj-redis-cluster", "myproj")` → `"redis-cluster"` (non-numeric
    ///   trailing token is part of the service name)
    /// - `("otherproj-redis", "myproj")` → `nil`
    static func parseServiceName(containerId: String, projectName: String) -> String? {
        let prefix = "\(projectName)-"
        guard containerId.hasPrefix(prefix) else { return nil }
        let remainder = String(containerId.dropFirst(prefix.count))
        guard !remainder.isEmpty else { return nil }

        // Strip a trailing `-<N>` (positive integer) if present — this is the
        // scaled-replica suffix that `ComposeUp` emits for `service.scale > 1`.
        // A non-numeric trailing token is part of the service name (e.g.
        // `redis-cluster`).
        if let lastDash = remainder.lastIndex(of: "-") {
            let tail = remainder[remainder.index(after: lastDash)...]
            if !tail.isEmpty, tail.allSatisfy({ $0.isNumber }) {
                return String(remainder[..<lastDash])
            }
        }

        return remainder
    }
}
