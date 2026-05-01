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

/// CHAOS-1354 — Phase 5 container lifecycle write endpoints.
///
/// Routes:
/// - `POST /containers/{id}/start`   → `Runtime.start(id:)`
/// - `POST /containers/{id}/stop`    → `Runtime.stop(id:options:)` (body: `APIStopRequest?`)
/// - `POST /containers/{id}/restart` → composite stop + start (atomic from caller's view)
/// - `POST /containers/{id}/kill`    → `Runtime.kill(id:signal:)` (body: `APIKillRequest?`)
/// - `DELETE /containers/{id}`       → `Runtime.remove(id:force:)` (query: `?force=true|false`)
/// - `POST /containers/{id}/wait`    → `Runtime.wait(id:timeoutSeconds:)` (nice-to-have)
///
/// Error mapping:
/// - `RuntimeError.notFound`      → 404 with `APIErrorResponse`
/// - `RuntimeError.invalidState`  → 409 with `APIErrorResponse` (wrong lifecycle state for action)
/// - Any other error              → rethrown (Hummingbird converts to 500)
///
/// Conformance to `ResponseEncodable` for the response types is declared at the
/// bottom of this file. `APIErrorResponse` is already declared in
/// `ContainerRoutes.swift`'s extension — callers rely on it being visible
/// module-wide.
public enum LifecycleRoutes {
    public static func register(router: Router<BasicRequestContext>) {
        registerStart(router: router)
        registerStop(router: router)
        registerRestart(router: router)
        registerKill(router: router)
        registerRemove(router: router)
        registerWait(router: router)
    }

    // MARK: - POST /containers/{id}/start

    private static func registerStart(router: Router<BasicRequestContext>) {
        router.post("/containers/:id/start") { request, context -> Response in
            let id = try context.parameters.require("id")
            let runtime = RuntimeEnvironment.current
            do {
                try await runtime.start(id: id)
                return Response(status: .noContent)
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "No such container: \(id)", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.invalidState(_, let expected, let actual) {
                return try EditedResponse(
                    status: .conflict,
                    response: APIErrorEnvelope.legacy(.conflict, message: "Container \(id) is in state '\(actual.rawValue)', expected '\(expected.rawValue)' to start", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    // MARK: - POST /containers/{id}/stop

    private static func registerStop(router: Router<BasicRequestContext>) {
        router.post("/containers/:id/stop") { request, context -> Response in
            let id = try context.parameters.require("id")
            let runtime = RuntimeEnvironment.current
            let bodyBuffer = try? await request.body.collect(upTo: 64 * 1024)
            let opts = parseStopOptions(from: bodyBuffer)
            do {
                try await runtime.stop(id: id, options: opts)
                return Response(status: .noContent)
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "No such container: \(id)", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.invalidState(_, let expected, let actual) {
                return try EditedResponse(
                    status: .conflict,
                    response: APIErrorEnvelope.legacy(.conflict, message: "Container \(id) is in state '\(actual.rawValue)', expected '\(expected.rawValue)' to stop", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    // MARK: - POST /containers/{id}/restart

    private static func registerRestart(router: Router<BasicRequestContext>) {
        router.post("/containers/:id/restart") { request, context -> Response in
            let id = try context.parameters.require("id")
            let runtime = RuntimeEnvironment.current
            let bodyBuffer = try? await request.body.collect(upTo: 64 * 1024)
            let stopOpts = parseStopOptions(from: bodyBuffer)
            do {
                // Composite stop + start. We catch invalidState on stop so
                // a container already stopped (e.g. in .stopped/.exited) does
                // not fail the whole restart — we still attempt start.
                do {
                    try await runtime.stop(id: id, options: stopOpts)
                } catch RuntimeError.invalidState {
                    // Container is not running — acceptable, we can still start.
                }
                try await runtime.start(id: id)
                return Response(status: .noContent)
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "No such container: \(id)", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.invalidState(_, let expected, let actual) {
                return try EditedResponse(
                    status: .conflict,
                    response: APIErrorEnvelope.legacy(.conflict, message: "Container \(id) cannot be restarted: state '\(actual.rawValue)', expected '\(expected.rawValue)'", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    // MARK: - POST /containers/{id}/kill

    private static func registerKill(router: Router<BasicRequestContext>) {
        router.post("/containers/:id/kill") { request, context -> Response in
            let id = try context.parameters.require("id")
            let runtime = RuntimeEnvironment.current
            let bodyBuffer = try? await request.body.collect(upTo: 64 * 1024)
            let signal = parseKillSignal(from: bodyBuffer)
            do {
                try await runtime.kill(id: id, signal: signal)
                return Response(status: .noContent)
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "No such container: \(id)", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.invalidState(_, let expected, let actual) {
                return try EditedResponse(
                    status: .conflict,
                    response: APIErrorEnvelope.legacy(.conflict, message: "Container \(id) is in state '\(actual.rawValue)', expected '\(expected.rawValue)' to receive signal", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    // MARK: - DELETE /containers/{id}

    private static func registerRemove(router: Router<BasicRequestContext>) {
        router.delete("/containers/:id") { request, context -> Response in
            let id = try context.parameters.require("id")
            let runtime = RuntimeEnvironment.current
            let force = parseBool(request.uri.queryParameters["force"], default: false)
            do {
                try await runtime.remove(id: id, force: force)
                return Response(status: .noContent)
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "No such container: \(id)", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.invalidState(_, let expected, let actual) {
                return try EditedResponse(
                    status: .conflict,
                    response: APIErrorEnvelope.legacy(.conflict, message: "Container \(id) is in state '\(actual.rawValue)', expected '\(expected.rawValue)' to delete; use ?force=true to force-remove a running container", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    // MARK: - POST /containers/{id}/wait (nice-to-have)

    private static func registerWait(router: Router<BasicRequestContext>) {
        router.post("/containers/:id/wait") { request, context -> Response in
            let id = try context.parameters.require("id")
            let runtime = RuntimeEnvironment.current
            let timeout = parseTimeoutSeconds(from: request)
            do {
                let exitStatus = try await runtime.wait(id: id, timeoutSeconds: timeout)
                let body = APIWaitResponse(exitCode: exitStatus.exitCode, exitedAt: exitStatus.exitedAt)
                return try EditedResponse(response: body).response(from: request, context: context)
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "No such container: \(id)", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.timeout(_, let seconds) {
                return try EditedResponse(
                    status: .requestTimeout,
                    response: APIErrorEnvelope.legacy(.requestTimeout, message: "Container \(id) did not exit within \(seconds)s", requestId: context.id.description)
                ).response(from: request, context: context)
            } catch RuntimeError.notSupported {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorEnvelope.legacy(.notImplemented, message: "wait is not supported by the active runtime backend", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    // MARK: - Query / body parsing

    /// Parse `RuntimeStopOptions` from a pre-collected body buffer (`APIStopRequest`) or
    /// fall back to the protocol default (SIGTERM / 10 s timeout). The body is
    /// optional: `POST /stop` with no body is valid.
    static func parseStopOptions(from bodyBuffer: ByteBuffer?) -> RuntimeStopOptions {
        let body = decodeBody(APIStopRequest.self, from: bodyBuffer)
        return RuntimeStopOptions(
            signal: body?.signal ?? RuntimeStopOptions.default.signal,
            timeoutSeconds: body?.timeoutSeconds ?? RuntimeStopOptions.default.timeoutSeconds
        )
    }

    /// Parse the kill signal from a pre-collected body buffer (`APIKillRequest`).
    /// Defaults to 9 (SIGKILL) when the body is absent or the field is nil.
    static func parseKillSignal(from bodyBuffer: ByteBuffer?) -> Int32 {
        decodeBody(APIKillRequest.self, from: bodyBuffer)?.signal ?? 9
    }

    /// Parse `?timeout=<seconds>` from the query string. Defaults to 30 s.
    static func parseTimeoutSeconds(from request: Request) -> Int {
        request.uri.queryParameters["timeout"].flatMap { Int($0) } ?? 30
    }

    private static func parseBool(_ raw: Substring?, default defaultValue: Bool) -> Bool {
        guard let raw else { return defaultValue }
        switch raw.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return defaultValue
        }
    }

    /// Attempt to decode a pre-collected `ByteBuffer` as `T`. Returns `nil` if the
    /// buffer is absent, empty, or unparseable — all of which are valid: lifecycle
    /// endpoints accept optional JSON bodies.
    static func decodeBody<T: Decodable>(_ type: T.Type, from buffer: ByteBuffer?) -> T? {
        guard var buf = buffer, buf.readableBytes > 0 else { return nil }
        guard let data = buf.readBytes(length: buf.readableBytes).map({ Data($0) }) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension APIWaitResponse: ResponseEncodable {}
