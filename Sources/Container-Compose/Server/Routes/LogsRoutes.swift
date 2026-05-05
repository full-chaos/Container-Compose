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

/// CHAOS-1350 log streaming route for `GET /containers/{id}/logs`.
/// Emits newline-delimited JSON (`application/x-ndjson`) frames translated from
/// backend-neutral `RuntimeLogFrame` values.
public enum LogsRoutes {
    public static func register(router: Router<BasicRequestContext>) {
        router.get("/containers/:id/logs") { request, context -> Response in
            let id = try context.parameters.require("id")
            let runtime = RuntimeEnvironment.current
            do {
                let frames = try await runtime.logs(id: id, options: parseOptions(from: request))
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/x-ndjson"],
                    body: ResponseBody(asyncSequence: ndjsonStream(frames.map(toFrame)))
                )
            } catch RuntimeError.notFound {
                return try EditedResponse(
                    status: .notFound,
                    response: APIErrorEnvelope.legacy(.notFound, message: "No such container: \(id)", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    static func parseOptions(from request: Request) -> RuntimeLogOptions {
        RuntimeLogOptions(
            follow: parseBool(request.uri.queryParameters["follow"], default: false),
            tail: parseTail(request.uri.queryParameters["tail"]),
            since: parseDate(request.uri.queryParameters["since"]),
            timestamps: parseBool(request.uri.queryParameters["timestamps"], default: true)
        )
    }

    static func toFrame(_ frame: RuntimeLogFrame) -> APILogFrame {
        APILogFrame(
            stream: frame.source == .stdout ? "stdout" : "stderr",
            timestamp: frame.timestamp,
            line: String(decoding: frame.data, as: UTF8.self)
        )
    }

    private static func ndjsonStream(_ frames: AsyncMapSequence<AsyncStream<RuntimeLogFrame>, APILogFrame>) -> AsyncStream<ByteBuffer> {
        AsyncStream { continuation in
            let task = Task {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                for await frame in frames {
                    guard let buffer = encode(frame, encoder: encoder) else { continue }
                    continuation.yield(buffer)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func encode(_ frame: APILogFrame, encoder: JSONEncoder) -> ByteBuffer? {
        guard let data = try? encoder.encode(frame) else { return nil }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        buffer.writeString("\n")
        return buffer
    }

    private static func parseBool(_ raw: Substring?, default defaultValue: Bool) -> Bool {
        guard let raw else { return defaultValue }
        switch raw.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return defaultValue
        }
    }

    private static func parseTail(_ raw: Substring?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.lowercased() == "all" { return nil }
        return Int(raw)
    }

    // ISO8601DateFormatter is expensive to construct; Apple documents that it
    // is thread-safe for parsing once configured, so we share one instance per
    // format across requests. Annotated nonisolated(unsafe) because the type is
    // not Sendable: this is sound here (immutable `let`, no mutation post-init,
    // vendor-guaranteed parse safety) — distinct from the prior
    // `nonisolated(unsafe) static var emittedKeys` race in
    // Compose+UnsupportedWarnings.swift, which mutated a Set under contention.
    nonisolated(unsafe) private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let internetISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ raw: Substring?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let value = String(raw)
        if let date = fractionalISOFormatter.date(from: value) { return date }
        return internetISOFormatter.date(from: value)
    }
}

extension APILogFrame: ResponseEncodable {}
