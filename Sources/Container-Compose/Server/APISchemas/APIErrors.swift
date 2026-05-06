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

// MARK: - Error envelope (CHAOS-1357)

/// Unified error envelope for all 4xx/5xx responses.
/// Wire shape: `{"error":"<code>","message":"<human>","code":"<E_NNN>","requestId":"<id>"}`.
/// All route handlers should migrate from `APIErrorResponse` to this shape.
public struct APIErrorEnvelope: Codable, Sendable, Hashable, ResponseEncodable {
    /// Machine-readable error key (e.g. `"not_found"`, `"conflict"`).
    public let error: String
    /// Human-readable description safe to show in client UIs. Never leaks
    /// Swift error internals.
    public let message: String
    /// Short error code suitable for log indexing (e.g. `"E_404"`).
    public let code: String
    /// Correlates with `X-Request-Id` response header for log tracing.
    public let requestId: String

    public init(error: String, message: String, code: String, requestId: String) {
        self.error = error
        self.message = message
        self.code = code
        self.requestId = requestId
    }
}

public extension APIErrorEnvelope {
    /// Migration convenience — matches the status-oriented call sites across
    /// all route files. `code` defaults to `"E_<statusCode>"` when nil.
    static func legacy(
        _ status: HTTPResponse.Status,
        message: String,
        code: String? = nil,
        requestId: String
    ) -> APIErrorEnvelope {
        let resolvedCode = code ?? "E_\(status.code)"
        let errorKey: String
        switch status.code {
        case 400: errorKey = "bad_request"
        case 401: errorKey = "unauthorized"
        case 403: errorKey = "forbidden"
        case 404: errorKey = "not_found"
        case 408: errorKey = "request_timeout"
        case 409: errorKey = "conflict"
        case 501: errorKey = "not_supported"
        case 500: errorKey = "internal_error"
        default:  errorKey = "error"
        }
        return APIErrorEnvelope(error: errorKey, message: message, code: resolvedCode, requestId: requestId)
    }
}

// MARK: - Error envelope (legacy — deprecated)

/// Retained for source compatibility. Migrate call sites to `APIErrorEnvelope`.
@available(*, deprecated, message: "Use APIErrorEnvelope")
public struct APIErrorResponse: Codable, Sendable, Hashable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}
