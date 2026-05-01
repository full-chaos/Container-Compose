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

/// CHAOS-1347 network routes for `GET /networks`.
/// CHAOS-1353 extends with `POST /networks` and `DELETE /networks/{id}`.
/// Phase 3 will wire endpoint/MAC/IPv4 attachment details into the runtime
/// model; for now those fields are stubbed as empty strings.
public enum NetworkRoutes {
    public static func register(router: Router<BasicRequestContext>) {
        // GET /networks — list all networks
        router.get("/networks") { _, _ in
            let runtime = RuntimeEnvironment.current
            let networks = try await runtime.listNetworks()
            return networks.map(toSummary)
        }

        // POST /networks — create a network (CHAOS-1353)
        router.post("/networks") { request, context -> Response in
            let body = try await request.decode(as: APICreateNetworkRequest.self, context: context)
            let runtime = RuntimeEnvironment.current
            do {
                let network = try await runtime.createNetwork(
                    spec: RuntimeCreateNetworkSpec(
                        name: body.name,
                        driver: body.driver ?? "bridge",
                        subnet: body.subnet,
                        gateway: body.gateway,
                        labels: body.labels ?? [:]
                    )
                )
                let resp = APICreateNetworkResponse(id: network.id, name: network.name)
                return try EditedResponse(status: .created, response: resp)
                    .response(from: request, context: context)
            } catch RuntimeError.alreadyExists {
                return try EditedResponse(
                    status: .conflict,
                    response: APIErrorEnvelope.legacy(.conflict, message: "network '\(body.name)' already exists", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.notSupported(let op, let conformer) {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorEnvelope.legacy(.notImplemented, message: "operation '\(op)' not supported by '\(conformer)'", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }

        // DELETE /networks/{id} — remove a network (CHAOS-1353)
        router.delete("/networks/:id") { request, context -> Response in
            let id = try context.parameters.require("id")
            let runtime = RuntimeEnvironment.current
            do {
                try await runtime.removeNetwork(id: id)
                return Response(status: .noContent)
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "network '\(id)' not found", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.notSupported(let op, let conformer) {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorEnvelope.legacy(.notImplemented, message: "operation '\(op)' not supported by '\(conformer)'", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    private static func toSummary(_ n: RuntimeNetwork) -> APINetworkSummary {
        let attached = Dictionary(uniqueKeysWithValues: n.attachedContainerIds.map { id in
            (id, APIAttachedContainer(endpointID: "", macAddress: "", ipv4Address: ""))
        })

        return APINetworkSummary(
            id: n.id,
            name: n.name,
            driver: n.driver,
            labels: n.labels,
            containers: attached
        )
    }
}

extension APINetworkSummary: ResponseEncodable {}
extension APICreateNetworkResponse: ResponseEncodable {}
