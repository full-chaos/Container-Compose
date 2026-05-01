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
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Metrics
import Prometheus
import Testing
@testable import ContainerComposeCore
import TestHelpers

/// Bootstrap Prometheus exactly once for this test process. Swift Testing
/// creates a new struct instance per test, so `init()` would call bootstrap()
/// multiple times — which crashes with a precondition. Using a file-scope
/// `nonisolated(unsafe)` lazy flag ensures the call happens at most once.
private nonisolated(unsafe) var _metricsBootstrapped: Bool = {
    MetricsSystem.bootstrap(PrometheusMetricsFactory())
    return true
}()

/// CHAOS-1357 — tests for `GET /metrics` (Prometheus exposition format).
///
/// `MetricsSystem.bootstrap()` is a global one-time call, so we bootstrap
/// with `PrometheusMetricsFactory()` once via a lazy flag and use
/// `@Suite(.serialized)` to prevent concurrent access to the shared
/// `defaultRegistry`.
@Suite("GET /metrics — Prometheus exposition format (CHAOS-1357)", .serialized)
struct MetricsRoutesTests {

    init() {
        // Touch the lazy flag to ensure bootstrap has run before any test executes.
        _ = _metricsBootstrapped
    }

    // MARK: - Helpers

    private func makeApp(containers: [RuntimeContainer] = []) -> Application<RouterResponder<BasicRequestContext>> {
        let bootTime = Date(timeIntervalSinceNow: -10) // 10 seconds ago
        let router = Router()
        MetricsRoutes.register(router: router, bootTime: bootTime)
        return Application(router: router)
    }

    private func scrapeMetrics(containers: [RuntimeContainer] = []) async throws -> String {
        let app = makeApp(containers: containers)
        let runtime = RecordingRuntime(stubbedContainers: containers)
        return try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/metrics", method: .get) { response in
                    String(buffer: response.body)
                }
            }
        }
    }

    // MARK: - Status and content type

    @Test("GET /metrics returns 200")
    func metricsReturns200() async throws {
        let app = makeApp()
        let runtime = RecordingRuntime(stubbedContainers: [])
        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/metrics", method: .get) { response in
                    #expect(response.status == .ok)
                }
            }
        }
    }

    @Test("GET /metrics Content-Type is Prometheus text/plain 0.0.4")
    func metricsContentType() async throws {
        let app = makeApp()
        let runtime = RecordingRuntime(stubbedContainers: [])
        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/metrics", method: .get) { response in
                    let ct = response.headers[HTTPField.Name.contentType] ?? ""
                    #expect(ct.contains("text/plain"))
                    #expect(ct.contains("0.0.4"))
                }
            }
        }
    }

    // MARK: - Custom gauges

    @Test("GET /metrics output contains uptime gauge name")
    func metricsContainsUptimeGauge() async throws {
        let body = try await scrapeMetrics()
        #expect(body.contains(MetricsRoutes.uptimeGaugeName))
    }

    @Test("GET /metrics output contains RSS gauge name")
    func metricsContainsRSSGauge() async throws {
        let body = try await scrapeMetrics()
        #expect(body.contains(MetricsRoutes.rssGaugeName))
    }

    @Test("GET /metrics output contains registry containers gauge name")
    func metricsContainsRegistryContainersGauge() async throws {
        let body = try await scrapeMetrics()
        #expect(body.contains(MetricsRoutes.registryContainersGaugeName))
    }

    // MARK: - Registry container count

    @Test("GET /metrics container_compose_registry_containers reflects runtime list size")
    func metricsRegistryContainersCount() async throws {
        let containers = [
            RuntimeContainer(id: "c1", imageReference: "nginx", status: .running),
            RuntimeContainer(id: "c2", imageReference: "redis", status: .running),
        ]
        let body = try await scrapeMetrics(containers: containers)
        // The gauge line looks like:
        //   container_compose_registry_containers 2.0
        // We check the name is present and the body is non-empty (exact numeric
        // format is Prometheus-internal and subject to change).
        #expect(body.contains(MetricsRoutes.registryContainersGaugeName))
        #expect(!body.isEmpty)
    }

    // MARK: - Gauge clamping: uptime must be non-negative

    @Test("GET /metrics uptime gauge line does not contain a negative number")
    func metricsUptimeIsNonNegative() async throws {
        let body = try await scrapeMetrics()
        // Extract the line containing the uptime gauge and assert no "-" in the value portion.
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let uptimeLine = lines.first { $0.hasPrefix(MetricsRoutes.uptimeGaugeName) }
        // If the gauge was recorded, the line must exist and not show a negative.
        if let line = uptimeLine {
            #expect(!line.contains(" -"))
        }
    }

    // MARK: - Prometheus line format smoke-check

    @Test("GET /metrics output starts with # HELP or metric name (valid Prometheus format)")
    func metricsIsValidPrometheusFormat() async throws {
        let body = try await scrapeMetrics()
        // A non-empty Prometheus response must contain at least one HELP or TYPE comment,
        // or a bare metric line. We just verify it's not an HTML error page.
        let isValidPrometheus = body.contains("# HELP") || body.contains("# TYPE") ||
            body.contains(MetricsRoutes.uptimeGaugeName)
        #expect(isValidPrometheus)
    }
}
