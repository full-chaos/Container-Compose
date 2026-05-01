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

/// Compose-aware project routes for `GET /projects` and
/// `GET /projects/{name}/services`.
///
/// Per `docs/plans/native-api-server.md`, there is no dedicated Project entity
/// in the runtime. Project summaries are synthesized from container ids using
/// Container-Compose's naming convention: the project is the substring before
/// the first `-`, and the service is the substring after that prefix with an
/// optional numeric replica suffix (`-N`) collapsed. Containers without `-` are
/// treated as unknown-project runtime containers and excluded from project
/// enumeration.
public enum ProjectRoutes {
    public static func register(router: Router<BasicRequestContext>) {
        router.get("/projects") { _, _ in
            let runtime = RuntimeEnvironment.current
            let containers = try await runtime.list(filters: .all)
            return summarizeProjects(containers)
        }

        router.get("/projects/:name/services") { request, context -> Response in
            let name = try context.parameters.require("name")
            let runtime = RuntimeEnvironment.current
            let containers = try await runtime.list(filters: RuntimeListFilters(status: nil, namePrefix: "\(name)-"))
            let services = containers.map { c in
                APIServiceSummary(
                    project: name,
                    name: extractServiceName(from: c.id, project: name),
                    container: toContainerSummary(c)
                )
            }

            if services.isEmpty {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorResponse(message: "No such project: \(name)")
                ).response(from: request, context: context)
            }

            return try EditedResponse(response: services).response(from: request, context: context)
        }
    }

    static func summarizeProjects(_ list: [RuntimeContainer]) -> [APIProjectSummary] {
        let grouped = Dictionary(grouping: list.compactMap { container -> (project: String, container: RuntimeContainer)? in
            guard let separator = container.id.firstIndex(of: "-") else { return nil }
            let project = String(container.id[..<separator])
            guard !project.isEmpty else { return nil }
            return (project, container)
        }, by: \.project)

        return grouped.map { project, entries in
            let serviceNames = Set(entries.map { extractServiceName(from: $0.container.id, project: project) })
            let runningCount = entries.filter { $0.container.status == .running }.count
            let createdAt = entries.compactMap { $0.container.createdAt }.min()

            return APIProjectSummary(
                name: project,
                serviceCount: serviceNames.count,
                runningCount: runningCount,
                createdAt: createdAt
            )
        }
        .sorted { $0.name < $1.name }
    }

    static func extractServiceName(from containerId: String, project: String) -> String {
        let prefix = "\(project)-"
        guard containerId.hasPrefix(prefix) else { return containerId }

        let service = String(containerId.dropFirst(prefix.count))
        let parts = service.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count > 1, let last = parts.last, Int(last) != nil else {
            return service
        }
        return parts.dropLast().joined(separator: "-")
    }

    static func toContainerSummary(_ c: RuntimeContainer) -> APIContainerSummary {
        APIContainerSummary(
            id: c.id,
            names: [c.id],
            image: c.imageReference,
            state: c.status.rawValue,
            status: c.status.rawValue,
            createdAt: c.createdAt ?? Date(timeIntervalSince1970: 0),
            startedAt: c.startedAt,
            ports: c.publishedPorts.map { port in
                APIPortMapping(
                    privatePort: Int(port.containerPort),
                    publicPort: Int(port.hostPort),
                    proto: port.proto.rawValue,
                    ip: port.hostAddress.isEmpty ? nil : port.hostAddress
                )
            },
            labels: [:]
        )
    }
}

extension APIProjectSummary: ResponseEncodable {}
extension APIServiceSummary: ResponseEncodable {}
extension APIErrorResponse: ResponseEncodable {}

// Hummingbird 2.22 already provides `Array: ResponseEncodable where Element: Encodable`.
// Re-declaring specialized array conformances for project/service summaries is
// a real conflicting conformance, so these routes rely on Hummingbird's generic
// array encoding to preserve the documented raw-array response shape.
