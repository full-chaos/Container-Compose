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
import Testing

@testable import ContainerComposeCore

/// Pins the forward-edge inversion behavior of
/// `buildReverseDependencyGraph` against the bug class that motivated it
/// (UltraBrain MEDIUM #2 + Phase 2 follow-up: `Service.dependedBy`
/// mutations from `Service.topoSortConfiguredServices` are racily lost
/// when a service is visited a second time, so any reader of
/// `Service.dependedBy` is non-deterministic. The fix is to invert
/// forward `dependsOn.serviceNames` edges directly).
@Suite("DependencyGraph forward-edge inversion (CHAOS-1446)")
struct DependencyGraphTests {

    // MARK: - buildReverseDependencyGraph: input-order independence

    @Test("buildReverseDependencyGraph yields correct dependents regardless of input order")
    func buildReverseDependencyGraph_inputOrderIndependent() throws {
        // Bypass YAML / Dictionary loading so input order is fully under
        // test control. The bad order here \u2014 `db` BEFORE `api` \u2014 is the
        // exact case where `Service.topoSortConfiguredServices` discards
        // its `dependedBy.append` mutation: visiting `api` recurses into
        // `visit("db", from: "api")`, which mutates a local copy at L787,
        // then early-returns at L795 (db already visited as a root) before
        // reaching the `sorted.append` at L803. With `dependedBy` on `db`
        // empty, the pre-fix `filterServices` reader would drop `db` from
        // a `--include-deps api` invocation. `buildReverseDependencyGraph`
        // computes the reverse graph from forward edges and is immune to
        // this bug \u2014 this test pins that immunity.
        let dbService = Service(image: "postgres:16", dependsOn: nil)
        let apiService = Service(image: "example/api:latest", dependsOn: .list(["db"]))
        let webService = Service(image: "nginx:latest", dependsOn: nil)

        let services: [(serviceName: String, service: Service)] = [
            ("db", dbService),
            ("api", apiService),
            ("web", webService),
        ]

        let reverseGraph = buildReverseDependencyGraph(services: services)

        #expect(Set(reverseGraph["db"] ?? []) == ["api"], "api depends on db, so db's dependents must include api")
        #expect((reverseGraph["api"] ?? []).isEmpty, "no service depends on api in this fixture")
        #expect((reverseGraph["web"] ?? []).isEmpty, "no service depends on web in this fixture")
    }

    @Test("buildReverseDependencyGraph yields correct dependents in the inverted input order too")
    func buildReverseDependencyGraph_inverseInputOrder() throws {
        // Same fixture, opposite enumeration order. Result MUST be
        // identical \u2014 the helper takes its truth from each service's
        // `dependsOn.serviceNames`, never from the iteration order.
        let dbService = Service(image: "postgres:16", dependsOn: nil)
        let apiService = Service(image: "example/api:latest", dependsOn: .list(["db"]))
        let webService = Service(image: "nginx:latest", dependsOn: nil)

        let services: [(serviceName: String, service: Service)] = [
            ("api", apiService),
            ("db", dbService),
            ("web", webService),
        ]

        let reverseGraph = buildReverseDependencyGraph(services: services)

        #expect(Set(reverseGraph["db"] ?? []) == ["api"])
        #expect((reverseGraph["api"] ?? []).isEmpty)
        #expect((reverseGraph["web"] ?? []).isEmpty)
    }

    @Test("buildReverseDependencyGraph drops edges to services not in the selected set")
    func buildReverseDependencyGraph_dropsUnselectedEdges() throws {
        // `api.depends_on: [db, missing]` \u2014 `missing` is not in the
        // selected services list. The reverse edge from `missing` should
        // be silently dropped (a non-selected service cannot block
        // anything we run), and `db`'s reverse edge to `api` must still
        // be present.
        let dbService = Service(image: "postgres:16", dependsOn: nil)
        let apiService = Service(image: "example/api:latest", dependsOn: .list(["db", "missing"]))

        let services: [(serviceName: String, service: Service)] = [
            ("db", dbService),
            ("api", apiService),
        ]

        let reverseGraph = buildReverseDependencyGraph(services: services)

        #expect(Set(reverseGraph["db"] ?? []) == ["api"])
        #expect(reverseGraph["missing"] == nil, "edges to non-selected services must not appear in the reverse graph")
        #expect((reverseGraph["api"] ?? []).isEmpty)
    }

    @Test("buildForwardDependencyGraph mirrors buildReverseDependencyGraph's input-order independence")
    func buildForwardDependencyGraph_inputOrderIndependent() throws {
        // Same fixture, forward direction. Confirms the forward helper
        // also reads from `dependsOn.serviceNames` (not from any
        // mutated `dependedBy` field) and is therefore deterministic.
        let dbService = Service(image: "postgres:16", dependsOn: nil)
        let apiService = Service(image: "example/api:latest", dependsOn: .list(["db"]))

        let badOrder: [(serviceName: String, service: Service)] = [
            ("db", dbService),
            ("api", apiService),
        ]
        let inverseOrder: [(serviceName: String, service: Service)] = [
            ("api", apiService),
            ("db", dbService),
        ]

        let g1 = buildForwardDependencyGraph(services: badOrder)
        let g2 = buildForwardDependencyGraph(services: inverseOrder)

        #expect(Set(g1["api"] ?? []) == ["db"])
        #expect((g1["db"] ?? []).isEmpty)
        #expect(Set(g2["api"] ?? []) == ["db"])
        #expect((g2["db"] ?? []).isEmpty)
    }
}
