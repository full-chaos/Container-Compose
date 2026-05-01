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

import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import Logging

/// Authenticates incoming requests via `Authorization: Bearer <token>` header.
///
/// Composition with mTLS:
/// - When `mtlsTrustEstablished` returns `true`, missing/invalid bearer is acceptable
///   because the TLS handshake already authenticated the client via `--client-ca`.
/// - When `nil` or returns `false`, bearer is required; 401/403 on failure.
public struct AuthMiddleware<Store: AuthStore, Context: RequestContext>: RouterMiddleware {
    private let store: Store
    private let logger: Logger
    private let mtlsTrustEstablished: (@Sendable () -> Bool)?

    public init(
        store: Store,
        logger: Logger,
        mtlsTrustEstablished: (@Sendable () -> Bool)? = nil
    ) {
        self.store = store
        self.logger = logger
        self.mtlsTrustEstablished = mtlsTrustEstablished
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let mtlsTrusted = mtlsTrustEstablished?() ?? false
        let authHeader = request.headers[.authorization]

        switch (authHeader, mtlsTrusted) {
        case (nil, true), ("", true):
            return try await next(request, context)

        case (nil, false), ("", false):
            logger.warning("auth_failure", metadata: [
                "reason": "missing_credentials",
                "request_id": "\(context.id)",
                "remote": "<unknown>",
            ])
            return try makeEnvelopeResponse(
                status: .unauthorized,
                code: "E_401",
                message: "missing credentials",
                request: request,
                context: context
            )

        case (let header?, _):
            guard let raw = parseBearer(header) else {
                if mtlsTrusted {
                    return try await next(request, context)
                }
                logger.warning("auth_failure", metadata: [
                    "reason": "malformed_authorization",
                    "request_id": "\(context.id)",
                    "remote": "<unknown>",
                ])
                return try makeEnvelopeResponse(
                    status: .unauthorized,
                    code: "E_401",
                    message: "malformed authorization header",
                    request: request,
                    context: context
                )
            }

            let hashHex = APIKeyGenerator.hash(rawToken: raw)
            if let key = await store.find(hashHex: hashHex) {
                logger.debug("auth_success", metadata: [
                    "key_name": "\(key.name)",
                    "request_id": "\(context.id)",
                ])
                return try await next(request, context)
            }

            if mtlsTrusted {
                logger.debug("auth_mtls_only_fallback", metadata: [
                    "request_id": "\(context.id)",
                ])
                return try await next(request, context)
            }

            logger.warning("auth_failure", metadata: [
                "reason": "invalid_credentials",
                "request_id": "\(context.id)",
                "remote": "<unknown>",
            ])
            return try makeEnvelopeResponse(
                status: .forbidden,
                code: "E_403",
                message: "invalid credentials",
                request: request,
                context: context
            )
        }
    }

    private func parseBearer(_ header: String) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].lowercased() == "bearer",
              !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    private func makeEnvelopeResponse(
        status: HTTPResponse.Status,
        code: String,
        message: String,
        request: Request,
        context: Context
    ) throws -> Response {
        let envelope = APIErrorEnvelope.legacy(
            status,
            message: message,
            code: code,
            requestId: context.id.description
        )
        return try EditedResponse(status: status, response: envelope)
            .response(from: request, context: context)
    }
}
