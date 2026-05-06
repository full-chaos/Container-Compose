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

// MARK: GET /secrets  (CHAOS-1353)

public struct APISecretSummary: Codable, Sendable, Hashable {
    public let name: String
    public let labels: [String: String]
    public let createdAt: Date?

    public init(
        name: String,
        labels: [String: String],
        createdAt: Date?
    ) {
        self.name = name
        self.labels = labels
        self.createdAt = createdAt
    }
}

// MARK: POST /secrets

/// Request body for `POST /secrets`.
///
/// Secret body shape decision (CHAOS-1353 PR note):
/// - `value` is an inline UTF-8 string. The caller is responsible for reading
///   the file when `secret.file:` is specified in a Compose document and passing
///   the contents as `value`. The server does NOT accept a `filePath` parameter —
///   file I/O on the server side would require the daemon to have access to the
///   client's local filesystem, which is not guaranteed in production deployments.
///   This matches how Docker handles `POST /secrets` (value-in-body only).
/// - `labels` is optional metadata for secret grouping / filtering.
public struct APICreateSecretRequest: Codable, Sendable, Hashable {
    public let name: String
    public let value: String
    public let labels: [String: String]?

    public init(
        name: String,
        value: String,
        labels: [String: String]? = nil
    ) {
        self.name = name
        self.value = value
        self.labels = labels
    }
}

/// Response body for `POST /secrets` (201 Created).
/// The secret `value` is intentionally omitted — it is never echoed back.
public struct APICreateSecretResponse: Codable, Sendable, Hashable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}
