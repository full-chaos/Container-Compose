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
import Hummingbird
import Metrics
import NIOCore
import Prometheus

/// CHAOS-1357 — `GET /metrics` (Prometheus exposition format).
///
/// On each scrape:
/// 1. Refreshes three custom gauges: uptime, resident memory, registry container count.
/// 2. Emits the full `PrometheusCollectorRegistry.shared` in text/plain 0.0.4 format.
///
/// The `hb_requests`, `http_server_request_duration_seconds`, and
/// `http_server_active_requests` counters/timers are automatically populated by
/// Hummingbird's built-in `MetricsMiddleware` — we don't write counting logic here.
public enum MetricsRoutes {

    /// Gauge names for custom container-compose process metrics.
    static let uptimeGaugeName = "container_compose_uptime_seconds"
    static let rssGaugeName = "container_compose_memory_rss_bytes"
    static let registryContainersGaugeName = "container_compose_registry_containers"

    public static func register(router: Router<BasicRequestContext>, bootTime: Date) {
        router.get("/metrics") { request, context -> Response in
            // Refresh custom gauges on each scrape so values are current.
            let uptimeSeconds = -bootTime.timeIntervalSinceNow   // positive, since boot is in the past
            Gauge(label: uptimeGaugeName).record(uptimeSeconds)

            let rssBytes = ProcessRSS.bytes
            Gauge(label: rssGaugeName).record(Double(rssBytes))

            let containerCount = (try? await RuntimeEnvironment.current.list(filters: .all))?.count ?? 0
            Gauge(label: registryContainersGaugeName).record(containerCount)

            // Emit Prometheus registry into a buffer.
            var buffer = [UInt8]()
            PrometheusMetricsFactory.defaultRegistry.emit(into: &buffer)

            let byteBuffer = ByteBuffer(bytes: buffer)
            return Response(
                status: .ok,
                headers: [.contentType: "text/plain; version=0.0.4; charset=utf-8"],
                body: ResponseBody(byteBuffer: byteBuffer)
            )
        }
    }
}
