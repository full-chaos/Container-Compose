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

// MARK: - RuntimeSecret (CHAOS-1353)

/// Runtime-side secret representation for `Runtime.listSecrets()` /
/// `createSecret()` / `removeSecret(name:)`. The secret value is stored
/// only during creation (`RuntimeCreateSecretSpec.value`); subsequent
/// `listSecrets()` / `get` calls never reveal the value in the runtime model
/// (mirrors real secret stores). Phase 8 ships only the in-memory MockRuntime
/// implementation; a durable backend (keychain, file-based) is a follow-up.
public struct RuntimeSecret: Sendable, Hashable, Codable {
    public let name: String
    public let labels: [String: String]
    public let createdAt: Date?

    public init(
        name: String,
        labels: [String: String] = [:],
        createdAt: Date? = nil
    ) {
        self.name = name
        self.labels = labels
        self.createdAt = createdAt
    }
}

/// Spec used to create a new secret via `Runtime.createSecret(spec:)`.
/// The value is provided inline as a UTF-8 string. File-path sourcing
/// (Compose `secret.file:`) is the caller's responsibility — the route
/// handler reads the file and passes the content here.
public struct RuntimeCreateSecretSpec: Sendable, Equatable {
    public let name: String
    public let value: String
    public let labels: [String: String]

    public init(
        name: String,
        value: String,
        labels: [String: String] = [:]
    ) {
        self.name = name
        self.value = value
        self.labels = labels
    }
}
