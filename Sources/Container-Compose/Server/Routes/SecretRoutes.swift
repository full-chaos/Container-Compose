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

/// CHAOS-1353 secret routes:
///   GET    /secrets            — list secret metadata (values NEVER included)
///   POST   /secrets            — create a secret (value supplied inline, not echoed back)
///   DELETE /secrets/{name}     — remove a secret by name
///
/// Secret body shape decision (CHAOS-1353):
/// `POST /secrets` accepts `{name, value, labels?}`. The secret value is
/// provided inline as a UTF-8 string in the request body. File-path sourcing
/// is the *caller's* responsibility — clients that read a `secret.file:` path
/// must read the file themselves and pass the content as `value`. The daemon
/// does NOT accept a `filePath` parameter to avoid requiring file-system access
/// on the server side. Secret values are NEVER echoed in any response.
///
/// Cross-host secret distribution is out of scope for Phase 8 per CHAOS-1353.
public enum SecretRoutes {
    public static func register(router: Router<BasicRequestContext>) {

        // GET /secrets — list all secret metadata (no values)
        router.get("/secrets") { request, context -> Response in
            let runtime = RuntimeEnvironment.current
            do {
                let secrets = try await runtime.listSecrets()
                return try EditedResponse(response: secrets.map(toSummary))
                    .response(from: request, context: context)
            } catch RuntimeError.notSupported(let op, let conformer) {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorResponse(message: "operation '\(op)' not supported by '\(conformer)'")
                ).response(from: request, context: context)
            }
        }

        // POST /secrets — create a secret
        router.post("/secrets") { request, context -> Response in
            let body = try await request.decode(as: APICreateSecretRequest.self, context: context)
            let runtime = RuntimeEnvironment.current
            do {
                let secret = try await runtime.createSecret(
                    spec: RuntimeCreateSecretSpec(
                        name: body.name,
                        value: body.value,
                        labels: body.labels ?? [:]
                    )
                )
                let resp = APICreateSecretResponse(name: secret.name)
                return try EditedResponse(status: .created, response: resp)
                    .response(from: request, context: context)
            } catch RuntimeError.alreadyExists {
                return try EditedResponse(
                    status: .conflict,
                    response: APIErrorResponse(message: "secret '\(body.name)' already exists")
                ).response(from: request, context: context)
            } catch RuntimeError.notSupported(let op, let conformer) {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorResponse(message: "operation '\(op)' not supported by '\(conformer)'")
                ).response(from: request, context: context)
            }
        }

        // DELETE /secrets/{name} — remove a secret by name
        router.delete("/secrets/:name") { request, context -> Response in
            let name = try context.parameters.require("name")
            let runtime = RuntimeEnvironment.current
            do {
                try await runtime.removeSecret(name: name)
                return Response(status: .noContent)
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorResponse(message: "secret '\(name)' not found")
                ).response(from: request, context: context)
            } catch RuntimeError.notSupported(let op, let conformer) {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorResponse(message: "operation '\(op)' not supported by '\(conformer)'")
                ).response(from: request, context: context)
            }
        }
    }

    private static func toSummary(_ s: RuntimeSecret) -> APISecretSummary {
        APISecretSummary(
            name: s.name,
            labels: s.labels,
            createdAt: s.createdAt
        )
    }
}

extension APISecretSummary: ResponseEncodable {}
extension APICreateSecretResponse: ResponseEncodable {}
