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

/// Remote command endpoints used by `container-compose --remote`.
public enum RuntimeCommandRoutes {
    public static func register(router: Router<BasicRequestContext>) {
        registerExec(router: router)
        registerTop(router: router)
        registerImagePush(router: router)
    }

    private static func registerExec(router: Router<BasicRequestContext>) {
        router.post("/containers/:id/exec") { request, context -> Response in
            let id = try context.parameters.require("id")
            let bodyBuffer = try? await request.body.collect(upTo: 256 * 1024)
            guard let body = LifecycleRoutes.decodeBody(APIExecRequest.self, from: bodyBuffer), !body.command.isEmpty else {
                return try EditedResponse(
                    status: .badRequest,
                    response: APIErrorEnvelope.legacy(.badRequest, message: "Request body is required: provide JSON with non-empty command array", requestId: context.id.description)
                ).response(from: request, context: context)
            }

            do {
                let result = try await RuntimeEnvironment.current.exec(
                    id: id,
                    command: body.command,
                    options: body.runtimeOptions
                )
                return try EditedResponse(
                    response: APIExecResponse(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
                ).response(from: request, context: context)
            } catch RuntimeError.notFound {
                return try notFound(id: id, request: request, context: context)
            } catch RuntimeError.notSupported {
                return try notImplemented("exec is not supported by the active runtime backend", request: request, context: context)
            }
        }
    }

    private static func registerTop(router: Router<BasicRequestContext>) {
        router.get("/containers/:id/top") { request, context -> Response in
            let id = try context.parameters.require("id")
            do {
                let result = try await RuntimeEnvironment.current.processes(id: id)
                return try EditedResponse(
                    response: APIProcessListResponse(containerId: result.containerId, output: result.output)
                ).response(from: request, context: context)
            } catch RuntimeError.notFound {
                return try notFound(id: id, request: request, context: context)
            } catch RuntimeError.notSupported {
                return try notImplemented("process listing is not supported by the active runtime backend", request: request, context: context)
            }
        }
    }

    private static func registerImagePush(router: Router<BasicRequestContext>) {
        router.post("/images/push") { request, context -> Response in
            let bodyBuffer = try? await request.body.collect(upTo: 64 * 1024)
            guard let body = LifecycleRoutes.decodeBody(APIImagePushRequest.self, from: bodyBuffer), !body.image.isEmpty else {
                return try EditedResponse(
                    status: .badRequest,
                    response: APIErrorEnvelope.legacy(.badRequest, message: "Request body is required: provide JSON with image", requestId: context.id.description)
                ).response(from: request, context: context)
            }

            do {
                let result = try await RuntimeEnvironment.current.pushImage(reference: body.image)
                return try EditedResponse(
                    response: APIImagePushResponse(
                        image: result.imageReference,
                        stdout: result.stdout,
                        stderr: result.stderr,
                        exitCode: result.exitCode
                    )
                ).response(from: request, context: context)
            } catch RuntimeError.notSupported {
                return try notImplemented("image push is not supported by the active runtime backend", request: request, context: context)
            }
        }
    }

    private static func notFound(
        id: String,
        request: Request,
        context: BasicRequestContext
    ) throws -> Response {
        try EditedResponse(
            status: .notFound,
            response: APIErrorEnvelope.legacy(.notFound, message: "No such container: \(id)", requestId: context.id.description)
        ).response(from: request, context: context)
    }

    private static func notImplemented(
        _ message: String,
        request: Request,
        context: BasicRequestContext
    ) throws -> Response {
        try EditedResponse(
            status: .notImplemented,
            response: APIErrorEnvelope.legacy(.notImplemented, message: message, requestId: context.id.description)
        ).response(from: request, context: context)
    }
}

extension APIExecResponse: ResponseEncodable {}
extension APIProcessListResponse: ResponseEncodable {}
extension APIImagePushResponse: ResponseEncodable {}
