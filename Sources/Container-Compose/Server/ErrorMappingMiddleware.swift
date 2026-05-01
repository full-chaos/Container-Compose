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
import Logging

/// Catches `RuntimeError` values thrown by route handlers and converts them
/// into `APIErrorEnvelope` responses with appropriate HTTP status codes.
///
/// This is a safety-net middleware — individual routes already catch most
/// `RuntimeError` cases explicitly. `ErrorMappingMiddleware` handles any that
/// fall through, ensuring clients always receive a structured envelope instead
/// of a raw 500.
///
/// Ordering: must be placed AFTER `RequestIDHeaderMiddleware` so the request id
/// is already available in context when we format the envelope.
///
/// Error mapping:
/// - `.notFound`     → 404  `not_found`
/// - `.invalidState` → 409  `invalid_state`
/// - `.notSupported` → 501  `not_supported`
/// - `.alreadyExists`→ 409  `conflict`
/// - all others      → 500  `internal_error`  (Swift error text NOT leaked)
public struct ErrorMappingMiddleware<Context: RequestContext>: RouterMiddleware {
    public init() {}

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let runtimeError as RuntimeError {
            return try envelope(for: runtimeError, request: request, context: context)
        }
        // Non-RuntimeError throws propagate to Hummingbird's default handler
        // (500 text/plain). Route handlers should catch their own non-runtime errors.
    }

    // MARK: - Private

    private func envelope(
        for error: RuntimeError,
        request: Request,
        context: Context
    ) throws -> Response {
        let requestId = context.id.description
        let (status, errorKey, code, message): (HTTPResponse.Status, String, String, String)

        switch error {
        case .notFound(let id):
            status = .notFound
            errorKey = "not_found"
            code = "E_404"
            message = "No such resource: \(id)"

        case .invalidState(let id, let expected, let actual):
            status = .conflict
            errorKey = "invalid_state"
            code = "E_409"
            message = "Resource '\(id)' is in state '\(actual.rawValue)', expected '\(expected.rawValue)'"

        case .notSupported(let operation, let conformer):
            status = .notImplemented
            errorKey = "not_supported"
            code = "E_501"
            message = "Operation '\(operation)' is not supported by the active backend '\(conformer)'"

        case .alreadyExists(let id):
            status = .conflict
            errorKey = "conflict"
            code = "E_409"
            message = "Resource '\(id)' already exists"

        default:
            // backendFailure, persistenceFailure, timeout — never leak internals
            status = .internalServerError
            errorKey = "internal_error"
            code = "E_500"
            message = "An internal error occurred. Check server logs for details."
        }

        let envelope = APIErrorEnvelope(
            error: errorKey,
            message: message,
            code: code,
            requestId: requestId
        )
        return try EditedResponse(status: status, response: envelope)
            .response(from: request, context: context)
    }
}
