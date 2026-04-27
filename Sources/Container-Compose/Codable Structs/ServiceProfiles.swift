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

//
//  ServiceProfiles.swift
//  Container-Compose
//

import Foundation

extension Service {
    /// Filters a list of services by the active profile set.
    ///
    /// Rules:
    /// - When `activeProfiles` is empty (no profile filter), all services are returned unchanged.
    /// - A service with no `profiles` field (nil) or an empty `profiles` array is always included.
    /// - A service with one or more profiles is included only if its profiles array intersects `activeProfiles`.
    ///
    /// - Parameters:
    ///   - services: The full list of (serviceName, service) pairs to filter.
    ///   - activeProfiles: The set of profile names that are currently active. Pass an empty set to
    ///     skip profile filtering entirely.
    /// - Returns: The subset of `services` that matches the filter criteria.
    public static func filterByProfiles(
        _ services: [(serviceName: String, service: Service)],
        activeProfiles: Set<String>
    ) -> [(serviceName: String, service: Service)] {
        // No profile filter active — return everything.
        guard !activeProfiles.isEmpty else { return services }

        return services.filter { _, service in
            // Services with no profiles (or empty list) are always included.
            guard let serviceProfiles = service.profiles, !serviceProfiles.isEmpty else {
                return true
            }
            // Include service if ANY of its profiles appear in the active set.
            return !Set(serviceProfiles).isDisjoint(with: activeProfiles)
        }
    }

    /// Resolves the active profile set from CLI flags and the environment.
    ///
    /// - Parameter cliProfiles: The profiles passed via `--profile` flags (may be empty).
    /// - Returns: A `Set<String>` of active profiles. Empty means "no filter".
    public static func resolveActiveProfiles(cliProfiles: [String]) -> Set<String> {
        if !cliProfiles.isEmpty {
            return Set(cliProfiles)
        }
        // Fall back to COMPOSE_PROFILES environment variable (comma-separated).
        let envValue = ProcessInfo.processInfo.environment["COMPOSE_PROFILES"] ?? ""
        let envProfiles = envValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(envProfiles)
    }
}
