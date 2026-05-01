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

/// CHAOS-1352 — Phase 6: POST /containers/create
///
/// Accepts an `APICreateContainerRequest` body, calls `Runtime.create(id:configuration:)`,
/// and returns 201 with `APICreateContainerResponse` on success.
///
/// Container name resolution:
/// - Body `name` field takes precedence over `?name=` query parameter.
/// - If neither is present a UUID is generated as the container id.
///
/// Error mapping:
/// - `RuntimeError.alreadyExists`  → 409 Conflict
/// - decode failure (missing/malformed body) → 400 Bad Request
/// - Any other runtime error       → rethrown (Hummingbird → 500)
///
/// Adherence to Leak #12 guidance: this route does NOT replicate the
/// `BridgeContainerClientRuntime.start()` bug pattern. The Bridge's `create()`
/// inspects the upstream error and maps `alreadyExists` cases to 409;
/// other errors become `backendFailure` (500). See
/// `docs/plans/runtime-abstraction-leaks.md` for full context.
public enum ContainerCreateRoute {
    public static func register(router: Router<BasicRequestContext>) {
        router.post("/containers/create") { request, context -> Response in
            // Collect body — required for this endpoint (not optional like lifecycle bodies).
            // `collect(upTo:)` throws if the body exceeds the limit; we let that propagate
            // as-is (Hummingbird converts body-too-large to 413). We only intercept the
            // "no body / zero-length body" case here, which is a client error (400).
            let bodyBuffer = try await request.body.collect(upTo: 1024 * 1024)
            guard bodyBuffer.readableBytes > 0 else {
                return try EditedResponse(
                    status: .badRequest,
                    response: APIErrorEnvelope.legacy(.badRequest, message: "Request body is required: provide JSON with at least {\"image\": \"<ref>\"}", requestId: context.id.description)
                ).response(from: request, context: context)
            }

            // Decode the request body.
            guard let requestBody = decodeCreateRequest(from: bodyBuffer) else {
                return try EditedResponse(
                    status: .badRequest,
                    response: APIErrorEnvelope.legacy(.badRequest, message: "Invalid request body: expected JSON with required field 'image'", requestId: context.id.description)
                ).response(from: request, context: context)
            }

            // Resolve container id/name:
            // 1. Body `name` wins.
            // 2. `?name=` query alias.
            // 3. Auto-generated UUID as fallback.
            let resolvedName: String
            if let bodyName = requestBody.name, !bodyName.isEmpty {
                resolvedName = bodyName
            } else if let queryName = request.uri.queryParameters["name"].map(String.init), !queryName.isEmpty {
                resolvedName = queryName
            } else {
                resolvedName = UUID().uuidString
            }

            // Map API port mappings → RuntimePublishedPort.
            let publishedPorts = mapPublishedPorts(requestBody.publishedPorts ?? [])

            // Build the RuntimeCreateConfiguration.
            let configuration = RuntimeCreateConfiguration(
                imageReference: requestBody.image,
                cpus: requestBody.cpus ?? 1,
                memoryInBytes: requestBody.memoryBytes ?? (256 * 1024 * 1024),
                hostname: requestBody.hostname,
                environment: requestBody.env ?? [],
                command: requestBody.cmd ?? [],
                workingDirectory: requestBody.workingDir,
                publishedPorts: publishedPorts
            )

            let runtime = RuntimeEnvironment.current
            do {
                let container = try await runtime.create(id: resolvedName, configuration: configuration)
                let responseBody = APICreateContainerResponse(id: container.id, warnings: [])
                return try EditedResponse(status: .created, response: responseBody)
                    .response(from: request, context: context)
            } catch RuntimeError.alreadyExists(let id) {
                return try EditedResponse(
                    status: .conflict,
                    response: APIErrorEnvelope.legacy(.conflict, message: "Container '\(id)' already exists", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.notSupported(let operation, let conformer) {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorEnvelope.legacy(.notImplemented, message: "Container create is not supported by the active runtime backend '\(conformer)' (operation: \(operation)). Use 'compose up' with the bridge backend.", requestId: context.id.description)
                ).response(from: request, context: context)
            }
            // All other errors propagate: Hummingbird converts to 500.
        }
    }

    // MARK: - Private helpers

    /// Decode `APICreateContainerRequest` from a pre-collected `ByteBuffer`.
    /// Returns `nil` if the buffer is unreadable or the JSON is missing the
    /// required `image` field (which Codable enforces as a non-optional).
    static func decodeCreateRequest(from buffer: ByteBuffer) -> APICreateContainerRequest? {
        var buf = buffer
        guard let bytes = buf.readBytes(length: buf.readableBytes) else { return nil }
        let data = Data(bytes)
        let decoder = JSONDecoder()
        return try? decoder.decode(APICreateContainerRequest.self, from: data)
    }

    /// Map `[APICreatePortMapping]` from the request body to `[RuntimePublishedPort]`.
    /// `proto` defaults to `.tcp`; `hostAddress` defaults to `"0.0.0.0"`.
    static func mapPublishedPorts(_ mappings: [APICreatePortMapping]) -> [RuntimePublishedPort] {
        mappings.map { m in
            let proto: RuntimePortProtocol = m.proto?.lowercased() == "udp" ? .udp : .tcp
            return RuntimePublishedPort(
                hostAddress: m.hostAddress ?? "0.0.0.0",
                hostPort: m.hostPort,
                containerPort: m.containerPort,
                proto: proto
            )
        }
    }
}

// MARK: - ResponseEncodable conformances

extension APICreateContainerResponse: ResponseEncodable {}
