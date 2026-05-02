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

/// CHAOS-1353 volume routes:
///   GET    /volumes            — list all volumes
///   POST   /volumes            — create a volume
///   DELETE /volumes/{name}     — remove a volume by name
///
/// Volume driver support is limited to `local` in Phase 8 per the CHAOS-1353
/// ticket boundary. Additional drivers are out of scope.
public enum VolumeRoutes {
    public static func register(router: Router<BasicRequestContext>) {

        // GET /volumes — list all volumes
        router.get("/volumes") { request, context -> Response in
            let runtime = RuntimeEnvironment.current
            do {
                let volumes = try await runtime.listVolumes()
                let resp = APIVolumeListResponse(volumes: volumes.map(toSummary))
                return try EditedResponse(response: resp)
                    .response(from: request, context: context)
            } catch RuntimeError.notSupported(let op, let conformer) {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorEnvelope.legacy(.notImplemented, message: "operation '\(op)' not supported by '\(conformer)'", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }

        // POST /volumes — create a volume
        router.post("/volumes") { request, context -> Response in
            let body = try await request.decode(as: APICreateVolumeRequest.self, context: context)
            let runtime = RuntimeEnvironment.current
            do {
                let volume = try await runtime.createVolume(
                    spec: RuntimeCreateVolumeSpec(
                        name: body.name,
                        driver: body.driver ?? "local",
                        labels: body.labels ?? [:],
                        driverOptions: [:]
                    )
                )
                let resp = toSummary(volume)
                return try EditedResponse(status: .created, response: resp)
                    .response(from: request, context: context)
            } catch RuntimeError.alreadyExists {
                return try EditedResponse(
                    status: .conflict,
                    response: APIErrorEnvelope.legacy(.conflict, message: "volume '\(body.name)' already exists", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.notSupported(let op, let conformer) {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorEnvelope.legacy(.notImplemented, message: "operation '\(op)' not supported by '\(conformer)'", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }

        // DELETE /volumes/{name} — remove a volume by name
        router.delete("/volumes/:name") { request, context -> Response in
            let name = try context.parameters.require("name")
            let runtime = RuntimeEnvironment.current
            do {
                try await runtime.removeVolume(name: name)
                return Response(status: .noContent)
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "volume '\(name)' not found", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.notSupported(let op, let conformer) {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorEnvelope.legacy(.notImplemented, message: "operation '\(op)' not supported by '\(conformer)'", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    private static func toSummary(_ v: RuntimeVolume) -> APIVolumeSummary {
        APIVolumeSummary(
            name: v.name,
            driver: v.driver,
            labels: v.labels,
            createdAt: v.createdAt
        )
    }
}

extension APIVolumeSummary: ResponseEncodable {}
extension APIVolumeListResponse: ResponseEncodable {}
