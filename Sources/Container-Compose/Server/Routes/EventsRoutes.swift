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

/// CHAOS-1350 event streaming route for `GET /events`.
/// Emits newline-delimited JSON (`application/x-ndjson`) frames translated from
/// backend-neutral `RuntimeContainerEvent` values.
public enum EventsRoutes {
    public static func register(router: Router<BasicRequestContext>) {
        router.get("/events") { request, context -> Response in
            let runtime = RuntimeEnvironment.current
            do {
                let events = try await runtime.events()
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/x-ndjson"],
                    body: ResponseBody(asyncSequence: ndjsonStream(events.map(toFrame)))
                )
            } catch RuntimeError.notSupported {
                return try EditedResponse(
                    status: .notImplemented,
                    response: APIErrorEnvelope.legacy(.notImplemented, message: "Events backend is not supported by the active runtime", requestId: context.id.description)
                ).response(from: request, context: context)
            }
        }
    }

    static func toFrame(_ event: RuntimeContainerEvent) -> APIEventFrame {
        switch event {
        case .created(let id, let at):
            return APIEventFrame(type: "created", id: id, timestamp: at, exitCode: nil, signal: nil)
        case .started(let id, let at):
            return APIEventFrame(type: "started", id: id, timestamp: at, exitCode: nil, signal: nil)
        case .stopped(let id, let exitCode, let at):
            return APIEventFrame(type: "stopped", id: id, timestamp: at, exitCode: exitCode, signal: nil)
        case .killed(let id, let signal, let at):
            return APIEventFrame(type: "killed", id: id, timestamp: at, exitCode: nil, signal: signal)
        case .oomKilled(let id, let at):
            return APIEventFrame(type: "oomKilled", id: id, timestamp: at, exitCode: nil, signal: nil)
        case .removed(let id, let at):
            return APIEventFrame(type: "removed", id: id, timestamp: at, exitCode: nil, signal: nil)
        }
    }

    private static func ndjsonStream(_ frames: AsyncMapSequence<AsyncStream<RuntimeContainerEvent>, APIEventFrame>) -> AsyncStream<ByteBuffer> {
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

    private static func encode(_ frame: APIEventFrame, encoder: JSONEncoder) -> ByteBuffer? {
        guard let data = try? encoder.encode(frame) else { return nil }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        buffer.writeString("\n")
        return buffer
    }
}

extension APIEventFrame: ResponseEncodable {}
extension APIStatsErrorResponse: ResponseEncodable {}
