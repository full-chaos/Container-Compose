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

/// CHAOS-1360 Phase 7 — Compose-aware project lifecycle endpoints.
///
/// Routes:
/// - `POST /projects/{name}/up`                        → 200 `APIProjectUpResponse`
/// - `POST /projects/{name}/down`                      → 200 `APIProjectDownResponse`
/// - `POST /projects/{name}/restart`                   → 200 `APIProjectRestartResponse`
/// - `POST /projects/{name}/build`                     → 200 NDJSON `APIProjectBuildFrame` stream
/// - `POST /projects/{name}/pull`                      → 200 NDJSON `APIProjectPullFrame` stream
/// - `POST /projects/{name}/services/{service}/scale`  → 200 `APIProjectScaleResponse`
///
/// Architecture decisions (per `docs/plans/native-api-server.md`):
/// - **Decision #11 — Sync vs Async:** All operations are synchronous 200 OK.
///   `build` and `pull` use NDJSON streaming (the long-running part is the
///   progress stream itself, not an async task). `up`, `down`, `restart`,
///   `scale` return once the runtime operations complete. This avoids task-ID
///   tracking complexity while still preventing indefinite response blocking.
/// - **Decision #12 — Compose-file source:** Registry model. The API operates
///   on containers already in the daemon's registry (identified by project-name
///   prefix). No Compose YAML parsing in the route layer.
/// - **Decision #13 — Orchestration layer:** Option B (`ProjectOrchestrator`).
///   Route handlers delegate to `ProjectOrchestrator` which calls `Runtime`
///   protocol methods. This keeps routes thin and `Runtime` protocol focused
///   on single-container primitives.
///
/// Error mapping:
/// - `OrchestratorError.projectNotFound`   → 404 with `APIErrorResponse`
/// - `OrchestratorError.serviceNotFound`   → 404 with `APIErrorResponse`
/// - `OrchestratorError.invalidReplicaCount` → 400 with `APIErrorResponse`
/// - `RuntimeError.notFound`               → 404
/// - Other errors                          → rethrown (Hummingbird → 500)
public enum ProjectLifecycleRoutes {

    public static func register(router: Router<BasicRequestContext>) {
        registerUp(router: router)
        registerDown(router: router)
        registerRestart(router: router)
        registerBuild(router: router)
        registerPull(router: router)
        registerScale(router: router)
    }

    // MARK: - POST /projects/{name}/up

    private static func registerUp(router: Router<BasicRequestContext>) {
        router.post("/projects/:name/up") { request, context -> Response in
            let name = try context.parameters.require("name")
            let runtime = RuntimeEnvironment.current

            let bodyBuffer = try? await request.body.collect(upTo: 64 * 1024)
            // Body is decoded for future extension (profiles, build, pull fields).
            // In the current registry model, serviceSpecs come from the runtime's
            // known containers; there is no Compose YAML parsed here.
            let _body = LifecycleRoutes.decodeBody(APIProjectUpRequest.self, from: bodyBuffer)
            _ = _body

            // Base registry model: no inline serviceSpecs; orchestrator discovers
            // containers from the runtime by project-name prefix.
            let serviceSpecs: [String: String] = [:]

            do {
                let states = try await ProjectOrchestrator.up(
                    project: name,
                    serviceSpecs: serviceSpecs,
                    runtime: runtime
                )
                let response = APIProjectUpResponse(project: name, services: states)
                return try EditedResponse(response: response).response(from: request, context: context)
            } catch ProjectOrchestrator.OrchestratorError.projectNotFound(let p) {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "No such project: \(p)", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.notFound(let id) {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "Container not found: \(id)", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    // MARK: - POST /projects/{name}/down

    private static func registerDown(router: Router<BasicRequestContext>) {
        router.post("/projects/:name/down") { request, context -> Response in
            let name = try context.parameters.require("name")
            let runtime = RuntimeEnvironment.current

            let bodyBuffer = try? await request.body.collect(upTo: 64 * 1024)
            let body = LifecycleRoutes.decodeBody(APIProjectDownRequest.self, from: bodyBuffer)
            let timeout = body?.timeout ?? 10

            do {
                let (stopped, removed) = try await ProjectOrchestrator.down(
                    project: name,
                    timeout: timeout,
                    runtime: runtime
                )
                let response = APIProjectDownResponse(
                    project: name,
                    stopped: stopped,
                    removed: removed
                )
                return try EditedResponse(response: response).response(from: request, context: context)
            } catch ProjectOrchestrator.OrchestratorError.projectNotFound(let p) {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "No such project: \(p)", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    // MARK: - POST /projects/{name}/restart

    private static func registerRestart(router: Router<BasicRequestContext>) {
        router.post("/projects/:name/restart") { request, context -> Response in
            let name = try context.parameters.require("name")
            let runtime = RuntimeEnvironment.current

            let bodyBuffer = try? await request.body.collect(upTo: 64 * 1024)
            let body = LifecycleRoutes.decodeBody(APIProjectRestartRequest.self, from: bodyBuffer)
            let timeout = body?.timeout ?? 10
            let services = body?.services

            do {
                let restarted = try await ProjectOrchestrator.restart(
                    project: name,
                    services: services,
                    timeout: timeout,
                    runtime: runtime
                )
                let response = APIProjectRestartResponse(project: name, restarted: restarted)
                return try EditedResponse(response: response).response(from: request, context: context)
            } catch ProjectOrchestrator.OrchestratorError.projectNotFound(let p) {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "No such project: \(p)", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    // MARK: - POST /projects/{name}/build  (NDJSON streaming)

    private static func registerBuild(router: Router<BasicRequestContext>) {
        router.post("/projects/:name/build") { request, context -> Response in
            let name = try context.parameters.require("name")
            let runtime = RuntimeEnvironment.current

            let bodyBuffer = try? await request.body.collect(upTo: 64 * 1024)
            let body = LifecycleRoutes.decodeBody(APIProjectBuildRequest.self, from: bodyBuffer)

            let stream = ProjectOrchestrator.buildStream(
                project: name,
                services: body?.services,
                noCache: body?.noCache ?? false,
                pull: body?.pull ?? false,
                runtime: runtime
            )

            return Response(
                status: .ok,
                headers: [.contentType: "application/x-ndjson"],
                body: ResponseBody(asyncSequence: ndjsonBuildStream(stream))
            )
        }
    }

    // MARK: - POST /projects/{name}/pull  (NDJSON streaming)

    private static func registerPull(router: Router<BasicRequestContext>) {
        router.post("/projects/:name/pull") { request, context -> Response in
            let name = try context.parameters.require("name")
            let runtime = RuntimeEnvironment.current

            let bodyBuffer = try? await request.body.collect(upTo: 64 * 1024)
            let body = LifecycleRoutes.decodeBody(APIProjectPullRequest.self, from: bodyBuffer)

            let stream = ProjectOrchestrator.pullStream(
                project: name,
                services: body?.services,
                ignoreFailures: body?.ignoreFailures ?? false,
                runtime: runtime
            )

            return Response(
                status: .ok,
                headers: [.contentType: "application/x-ndjson"],
                body: ResponseBody(asyncSequence: ndjsonPullStream(stream))
            )
        }
    }

    // MARK: - POST /projects/{name}/services/{service}/scale

    private static func registerScale(router: Router<BasicRequestContext>) {
        router.post("/projects/:name/services/:service/scale") { request, context -> Response in
            let name = try context.parameters.require("name")
            let service = try context.parameters.require("service")
            let runtime = RuntimeEnvironment.current

            let bodyBuffer = try? await request.body.collect(upTo: 64 * 1024)
            guard let body = LifecycleRoutes.decodeBody(APIProjectScaleRequest.self, from: bodyBuffer) else {
                return try EditedResponse(
                    status: .badRequest,
                    response: APIErrorEnvelope.legacy(.badRequest, message: "Request body required: {\"replicas\": <Int>}", requestId: context.id.description)
                ).response(from: request, context: context)
            }

            do {
                let containers = try await ProjectOrchestrator.scale(
                    project: name,
                    service: service,
                    replicas: body.replicas,
                    runtime: runtime
                )
                let response = APIProjectScaleResponse(
                    project: name,
                    service: service,
                    replicas: body.replicas,
                    containers: containers
                )
                return try EditedResponse(response: response).response(from: request, context: context)
            } catch ProjectOrchestrator.OrchestratorError.invalidReplicaCount(let count) {
                return try EditedResponse(
                    status: .badRequest,
                    response: APIErrorEnvelope.legacy(.badRequest, message: "Invalid replica count: \(count). Must be >= 0.", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch ProjectOrchestrator.OrchestratorError.serviceNotFound(let project, let svc) {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "Service '\(svc)' not found in project '\(project)'", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    // MARK: - NDJSON stream encoding

    /// Encode `APIProjectBuildFrame` values as NDJSON `ByteBuffer`s.
    private static func ndjsonBuildStream(
        _ upstream: AsyncStream<APIProjectBuildFrame>
    ) -> AsyncStream<ByteBuffer> {
        AsyncStream { continuation in
            let task = Task {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                for await frame in upstream {
                    if let buffer = encodeFrame(frame, encoder: encoder) {
                        continuation.yield(buffer)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Encode `APIProjectPullFrame` values as NDJSON `ByteBuffer`s.
    private static func ndjsonPullStream(
        _ upstream: AsyncStream<APIProjectPullFrame>
    ) -> AsyncStream<ByteBuffer> {
        AsyncStream { continuation in
            let task = Task {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                for await frame in upstream {
                    if let buffer = encodeFrame(frame, encoder: encoder) {
                        continuation.yield(buffer)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func encodeFrame<T: Encodable>(_ value: T, encoder: JSONEncoder) -> ByteBuffer? {
        guard let data = try? encoder.encode(value) else { return nil }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        buffer.writeString("\n")
        return buffer
    }
}

// MARK: - ResponseEncodable conformances

extension APIProjectUpResponse: ResponseEncodable {}
extension APIProjectDownResponse: ResponseEncodable {}
extension APIProjectRestartResponse: ResponseEncodable {}
extension APIProjectBuildFrame: ResponseEncodable {}
extension APIProjectPullFrame: ResponseEncodable {}
extension APIProjectScaleResponse: ResponseEncodable {}
