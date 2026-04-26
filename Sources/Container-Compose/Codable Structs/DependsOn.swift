//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
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

//
//  DependsOn.swift
//  Container-Compose
//

import Foundation

/// Condition that must be satisfied before a dependent service starts.
public enum ServiceCondition: String, Codable, Hashable {
    case serviceStarted = "service_started"
    case serviceHealthy = "service_healthy"
    case serviceCompletedSuccessfully = "service_completed_successfully"
}

/// A single entry in the object-form `depends_on` map.
public struct DependsOnEntry: Codable, Hashable {
    /// The condition that must be met (default: service_started)
    public let condition: ServiceCondition?
    /// Whether this dependency is required (default: true)
    public let required: Bool?
    /// Whether to restart this service when the dependency restarts
    public let restart: Bool?

    public init(condition: ServiceCondition? = nil, required: Bool? = nil, restart: Bool? = nil) {
        self.condition = condition
        self.required = required
        self.restart = restart
    }
}

/// Represents the `depends_on` field, which may be:
///   - a single service name string
///   - a list of service name strings
///   - a mapping of service name → condition entry
public enum DependsOn: Codable, Hashable {
    case list([String])
    case object([String: DependsOnEntry])

    /// Returns all referenced service names regardless of form.
    public var serviceNames: [String] {
        switch self {
        case .list(let names):
            return names
        case .object(let map):
            return Array(map.keys)
        }
    }

    /// Returns the entries dictionary. For the list form, each name gets a default entry.
    public var entries: [String: DependsOnEntry] {
        switch self {
        case .list(let names):
            return Dictionary(uniqueKeysWithValues: names.map { ($0, DependsOnEntry()) })
        case .object(let map):
            return map
        }
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try array of strings first
        if let names = try? container.decode([String].self) {
            self = .list(names)
            return
        }

        // Try single string
        if let name = try? container.decode(String.self) {
            self = .list([name])
            return
        }

        // Try object form
        let map = try container.decode([String: DependsOnEntry].self)
        self = .object(map)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .list(let names):
            try container.encode(names)
        case .object(let map):
            try container.encode(map)
        }
    }
}
