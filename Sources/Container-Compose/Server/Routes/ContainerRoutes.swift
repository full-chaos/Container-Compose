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

/// CHAOS-1347 container routes for `GET /containers` and
/// `GET /containers/{id}`. Response payloads are defined in
/// `Server/APISchemas.swift`.
public enum ContainerRoutes {
    public static func register(router: Router<BasicRequestContext>) {
        router.get("/containers") { request, _ in
            let runtime = RuntimeEnvironment.current
            let filters = parseListFilters(from: request)
            let containers = try await runtime.list(filters: filters)
            return containers.map(toSummary)
        }

        router.get("/containers/:id") { request, context -> Response in
            let id = try context.parameters.require("id")
            let runtime = RuntimeEnvironment.current
            do {
                let container = try await runtime.get(id: id)
                return try EditedResponse(response: toInspect(container))
                    .response(from: request, context: context)
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorResponse(message: "No such container: \(id)")
                ).response(from: request, context: context)
            }
        }
    }

    /// Hummingbird 2.x exposes parsed query parameters directly on
    /// `request.uri.queryParameters`, keyed by query item name.
    static func parseListFilters(from request: Request) -> RuntimeListFilters {
        let statusFilter = request.uri.queryParameters["status"].map { rawStatus in
            rawStatus
                .split(separator: ",")
                .compactMap { RuntimeContainerStatus(rawValue: String($0)) }
        }.flatMap { statuses in
            statuses.isEmpty ? nil : statuses
        }

        let namePrefix = request.uri.queryParameters["name"].map(String.init).flatMap { name in
            name.isEmpty ? nil : name
        }

        return RuntimeListFilters(status: statusFilter, namePrefix: namePrefix)
    }

    static func toSummary(_ container: RuntimeContainer) -> APIContainerSummary {
        APIContainerSummary(
            id: container.id,
            // RuntimeContainer has no separate container name yet; for v1 the
            // Container REST name list exposes the runtime id as the name.
            names: ["/\(container.id)"],
            image: container.imageReference,
            state: container.status.rawValue,
            status: humanStatus(container),
            createdAt: container.createdAt ?? Date.distantPast,
            startedAt: container.startedAt,
            ports: mapPorts(container.publishedPorts),
            // Phase 3 TODO: wire labels once RuntimeContainer carries them.
            labels: [:]
        )
    }

    static func toInspect(_ container: RuntimeContainer) -> APIContainerInspect {
        let ports = mapPorts(container.publishedPorts)
        return APIContainerInspect(
            id: container.id,
            created: container.createdAt ?? Date.distantPast,
            name: container.id,
            image: container.imageReference,
            state: APIContainerState(
                status: container.status.rawValue,
                running: container.status == .running,
                exitCode: container.lastExitCode,
                startedAt: container.startedAt,
                // Phase 3 TODO: RuntimeContainer needs finishedAt and health.
                finishedAt: nil,
                health: nil
            ),
            // Phase 3 TODO: RuntimeContainer needs env/cmd/workingDir/labels.
            config: APIContainerConfig(
                hostname: "",
                env: [],
                cmd: [],
                workingDir: "",
                labels: [:]
            ),
            networkSettings: APINetworkSettings(ipAddress: nil, ports: ports)
        )
    }

    static func humanStatus(_ container: RuntimeContainer) -> String {
        switch container.status {
        case .running:
            return "Up \(durationSince(container.startedAt ?? container.createdAt ?? Date()))"
        case .exited:
            let code = container.lastExitCode ?? 0
            return "Exited (\(code)) \(durationSince(container.startedAt ?? container.createdAt ?? Date())) ago"
        case .created:
            return "Created"
        default:
            return container.status.rawValue
        }
    }

    private static func mapPorts(_ ports: [RuntimePublishedPort]) -> [APIPortMapping] {
        ports.map { port in
            APIPortMapping(
                privatePort: Int(port.containerPort),
                publicPort: Int(port.hostPort),
                proto: port.proto.rawValue,
                ip: port.hostAddress
            )
        }
    }

    private static func durationSince(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 90 {
            return pluralized(minutes, unit: "minute")
        }

        let hours = max(1, Int((seconds / 3_600).rounded()))
        if hours < 36 {
            return pluralized(hours, unit: "hour")
        }

        let days = max(1, Int((seconds / 86_400).rounded()))
        return pluralized(days, unit: "day")
    }

    private static func pluralized(_ value: Int, unit: String) -> String {
        value == 1 ? "1 \(unit)" : "\(value) \(unit)s"
    }
}

extension APIContainerSummary: ResponseEncodable {}

extension APIContainerInspect: ResponseEncodable {}

// Hummingbird already provides `Array: ResponseEncodable where Element: Encodable`,
// so `[APIContainerSummary]` from `GET /containers` is encodable without a
// duplicate conditional conformance here.
// `APIErrorResponse` already conforms in a sibling route file in this branch;
// duplicating that conformance here would make the module fail to compile.
