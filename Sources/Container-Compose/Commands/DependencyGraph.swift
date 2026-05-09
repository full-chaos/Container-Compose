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

// MARK: - Dependency graph helpers (CHAOS-1446 Phase 3)

/// Builds a forward dependency map for a selected set of services.
///
/// For each service `S`, returns the list of services `S` depends on
/// (the value of `S.dependsOn?.serviceNames`), filtered to services that
/// are actually present in the selected set. Edges to services NOT in the
/// selected set (filtered out by `--profile`, missing from the compose
/// file, etc.) are dropped — a missing dependency cannot block work that
/// won't run.
///
/// Used by `compose start`, `compose up`, and `compose create`'s DAG phase
/// to determine which services a given service must wait for before it
/// itself can proceed.
public func buildForwardDependencyGraph(
    services: [(serviceName: String, service: Service)]
) -> [String: [String]] {
    let selected = Set(services.map(\.serviceName))
    var graph: [String: [String]] = Dictionary(uniqueKeysWithValues: services.map { ($0.serviceName, []) })
    for (name, service) in services {
        let deps = (service.dependsOn?.serviceNames ?? []).filter { selected.contains($0) }
        graph[name] = deps
    }
    return graph
}

/// Builds the REVERSE dependency map: for each service `S`, the list of
/// services that depend on `S` (i.e., `S`'s dependents).
///
/// **Critical**: this is built by INVERTING the forward edges declared on
/// each service via `dependsOn.serviceNames` — NOT by reading
/// `Service.dependedBy`. Per UltraBrain MEDIUM #2, `Service.dependedBy`
/// is mutated by `topoSortConfiguredServices` but its earlier mutations
/// can be lost when a service is already-visited in the DFS, making it an
/// unreliable reverse-graph source. The forward-edge inversion always
/// reflects the user's compose-file declarations exactly.
///
/// Used by `compose stop`'s reverse-DAG schedule: each service waits for
/// every service in `reverseGraph[serviceName]` to publish `.stopped`
/// before issuing its own stop. Leaf services (no dependents) stop
/// first; root services (no one depends on them) stop last.
public func buildReverseDependencyGraph(
    services: [(serviceName: String, service: Service)]
) -> [String: [String]] {
    let selected = Set(services.map(\.serviceName))
    var reverse: [String: [String]] = Dictionary(uniqueKeysWithValues: services.map { ($0.serviceName, []) })
    for (name, service) in services {
        for dep in service.dependsOn?.serviceNames ?? [] {
            guard selected.contains(dep) else { continue }
            reverse[dep, default: []].append(name)
        }
    }
    return reverse
}
