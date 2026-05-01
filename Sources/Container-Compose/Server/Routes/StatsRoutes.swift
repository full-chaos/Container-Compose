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
import HTTPTypes

/// CHAOS-1358 stats route for `GET /containers/{id}/stats`.
///
/// Implements Decision #7 (NDJSON over chunked HTTP) from
/// `docs/plans/native-api-server.md`. The route has two modes:
///
/// - **Streaming** (default, `?stream=true` or omitted): polls
///   `Runtime.statistics(for:)` at the requested interval and emits one
///   `APIStatsFrame` NDJSON line per poll. The stream terminates when the
///   client disconnects or the runtime throws `notFound` (container removed).
///
/// - **One-shot** (`?stream=false`): polls once, returns a single JSON object
///   with `Content-Type: application/json`.
///
/// **Interval clamping:** `?interval=Ns` accepts a duration in seconds
/// (e.g. `1s`, `2.5s`, `0.5s`). Values below 500 ms are clamped to 500 ms;
/// values above 60 s are clamped to 60 s. Out-of-range values are NOT
/// rejected with 400 — they are silently clamped. This avoids breaking
/// clients that hard-code large intervals (e.g. `120s`) while bounding
/// server load from excessively rapid polling.
public enum StatsRoutes {

    /// Minimum polling interval: 500 ms. Clamped, not rejected.
    static let minimumInterval: TimeInterval = 0.5
    /// Maximum polling interval: 60 s. Clamped, not rejected.
    static let maximumInterval: TimeInterval = 60.0
    /// Default polling interval: 1 s.
    static let defaultInterval: TimeInterval = 1.0

    public static func register(router: Router<BasicRequestContext>) {
        router.get("/containers/:id/stats") { request, context -> Response in
            let id = try context.parameters.require("id")
            let runtime = RuntimeEnvironment.current
            let streaming = parseStream(from: request)
            let interval = parseInterval(from: request)

            if streaming {
                return try await handleStream(id: id, runtime: runtime, interval: interval, request: request, context: context)
            } else {
                return try await handleOneShot(id: id, runtime: runtime, request: request, context: context)
            }
        }
    }

    // MARK: - One-shot handler

    private static func handleOneShot(
        id: String,
        runtime: any Runtime,
        request: Request,
        context: BasicRequestContext
    ) async throws -> Response {
        do {
            let stats = try await runtime.statistics(for: id)
            let frame = toFrame(stats)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(frame)
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: ResponseBody(byteBuffer: buffer)
            )
        } catch RuntimeError.notFound {
            return try EditedResponse(
                status: .notFound,
                response: APIErrorEnvelope.legacy(.notFound, message: "No such container: \(id)", requestId: context.id.description)
            ).response(from: request, context: context)
        } catch RuntimeError.notSupported {
            return try EditedResponse(
                status: .notImplemented,
                response: APIErrorEnvelope.legacy(.notImplemented, message: "Statistics backend is not supported by the active runtime", requestId: context.id.description)
            ).response(from: request, context: context)
        }
    }

    // MARK: - Streaming handler

    private static func handleStream(
        id: String,
        runtime: any Runtime,
        interval: TimeInterval,
        request: Request,
        context: BasicRequestContext
    ) async throws -> Response {
        // Probe with one call first so we can return 404/501 synchronously
        // before opening the chunked response body. This ensures the HTTP
        // status is set correctly even in streaming mode.
        do {
            let firstStats = try await runtime.statistics(for: id)
            let firstFrame = toFrame(firstStats)
            let stream = ndjsonStream(id: id, runtime: runtime, first: firstFrame, interval: interval)
            return Response(
                status: .ok,
                headers: [.contentType: "application/x-ndjson"],
                body: ResponseBody(asyncSequence: stream)
            )
        } catch RuntimeError.notFound {
            return try EditedResponse(
                status: .notFound,
                response: APIErrorEnvelope.legacy(.notFound, message: "No such container: \(id)", requestId: context.id.description)
            ).response(from: request, context: context)
        } catch RuntimeError.notSupported {
            return try EditedResponse(
                status: .notImplemented,
                response: APIErrorEnvelope.legacy(.notImplemented, message: "Statistics backend is not supported by the active runtime", requestId: context.id.description)
            ).response(from: request, context: context)
        }
    }

    // MARK: - NDJSON polling stream

    /// Produces an `AsyncStream<ByteBuffer>` that:
    /// 1. Emits the pre-fetched `first` frame immediately (no extra delay).
    /// 2. Polls `runtime.statistics(for:)` at `interval`, emitting each snapshot.
    /// 3. Terminates when the task is cancelled OR the runtime throws `notFound`
    ///    (container removed), or any other error.
    private static func ndjsonStream(
        id: String,
        runtime: any Runtime,
        first: APIStatsFrame,
        interval: TimeInterval
    ) -> AsyncStream<ByteBuffer> {
        AsyncStream { continuation in
            let task = Task {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601

                // Emit the first frame (already fetched before stream opened)
                if let buffer = encode(first, encoder: encoder) {
                    continuation.yield(buffer)
                }

                // Poll loop
                let intervalNanoseconds = UInt64(interval * 1_000_000_000)
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: intervalNanoseconds)
                        let stats = try await runtime.statistics(for: id)
                        let frame = toFrame(stats)
                        if let buffer = encode(frame, encoder: encoder) {
                            continuation.yield(buffer)
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        // Container gone or runtime error — stop stream cleanly
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Frame conversion (internal for testability)

    /// Convert a `RuntimeStatistics` snapshot into the NDJSON wire frame.
    static func toFrame(_ stats: RuntimeStatistics) -> APIStatsFrame {
        APIStatsFrame(
            id: stats.id,
            sampledAt: stats.sampledAt,
            cpuUsageMicroseconds: stats.cpuUsageUsec,
            memoryUsageBytes: stats.memoryUsageBytes,
            memoryLimitBytes: stats.memoryLimitBytes,
            oomKillCount: stats.oomKillCount,
            networks: stats.networks.map { net in
                APIStatsNetworkFrame(
                    interface: net.interface,
                    receivedBytes: net.receivedBytes,
                    transmittedBytes: net.transmittedBytes
                )
            }
        )
    }

    // MARK: - Query param parsing

    private static func parseStream(from request: Request) -> Bool {
        guard let raw = request.uri.queryParameters["stream"] else { return true }
        switch raw.lowercased() {
        case "false", "0", "no": return false
        default: return true
        }
    }

    /// Parse `?interval=Ns` where N is a decimal number of seconds.
    /// Strips the optional trailing `s` suffix. Clamps to [minimumInterval, maximumInterval].
    static func parseInterval(from request: Request) -> TimeInterval {
        let raw = request.uri.queryParameters["interval"].map(String.init)
        return parseIntervalValue(raw)
    }

    /// Core interval parser extracted for unit testing. Accepts an optional raw
    /// string (the query parameter value) and applies clamping logic.
    static func parseIntervalValue(_ raw: String?) -> TimeInterval {
        guard let raw, !raw.isEmpty else {
            return defaultInterval
        }
        // Strip trailing 's' suffix if present
        let stripped = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        guard let value = Double(stripped) else {
            return defaultInterval
        }
        return min(max(value, minimumInterval), maximumInterval)
    }

    // MARK: - Encoding

    private static func encode(_ frame: APIStatsFrame, encoder: JSONEncoder) -> ByteBuffer? {
        guard let data = try? encoder.encode(frame) else { return nil }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        buffer.writeString("\n")
        return buffer
    }
}

extension HTTPField.Name {
    static let containerComposeDeferral = Self("X-ContainerCompose-Deferral")!
}

extension APIStatsFrame: ResponseEncodable {}
// APIStatsErrorResponse: ResponseEncodable is already declared in EventsRoutes.swift
