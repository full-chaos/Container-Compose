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

/// The condition under which a dependency is considered satisfied.
public enum DependsOnCondition: String, Codable, Hashable, CaseIterable {
    case serviceStarted = "service_started"
    case serviceHealthy = "service_healthy"
    case serviceCompletedSuccessfully = "service_completed_successfully"
}

/// A single service dependency entry with condition, required, and restart fields.
public struct DependsOnEntry: Codable, Hashable {
    public let condition: DependsOnCondition
    public let required: Bool
    public let restart: Bool

    public init(condition: DependsOnCondition, required: Bool = true, restart: Bool = false) {
        self.condition = condition
        self.required = required
        self.restart = restart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // condition is REQUIRED — throw if missing
        condition = try container.decode(DependsOnCondition.self, forKey: .condition)

        // required defaults to true if absent
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true

        // restart accepts Bool, or String "true"/"false" (case-insensitive) — default false otherwise
        if let boolValue = try? container.decodeIfPresent(Bool.self, forKey: .restart) {
            restart = boolValue ?? false
        } else if let stringValue = try? container.decodeIfPresent(String.self, forKey: .restart) {
            restart = stringValue.lowercased() == "true"
        } else {
            restart = false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case condition
        case required
        case restart
    }
}

/// Represents the `depends_on` field of a compose service.
///
/// Supports three YAML forms:
/// - List of strings: `depends_on: [db, redis]`
/// - Single string: `depends_on: db`
/// - Object map: `depends_on: { db: { condition: service_healthy } }`
public struct DependsOn: Codable, Hashable {
    public let entries: [String: DependsOnEntry]

    /// The names of all services this entry depends on. Order is unspecified.
    public var serviceNames: [String] {
        Array(entries.keys)
    }

    public init(entries: [String: DependsOnEntry]) {
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let defaultEntry = DependsOnEntry(condition: .serviceStarted, required: true, restart: false)

        // Try [String] first
        if let names = try? decoder.singleValueContainer().decode([String].self) {
            entries = Dictionary(uniqueKeysWithValues: names.map { ($0, defaultEntry) })
            return
        }

        // Try single String
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            entries = [name: defaultEntry]
            return
        }

        // Try [String: DependsOnEntry]
        if let map = try? decoder.singleValueContainer().decode([String: DependsOnEntry].self) {
            entries = map
            return
        }

        // None matched — throw a meaningful error
        let context = DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Expected a string, array of strings, or a map of service dependencies"
        )
        throw DecodingError.typeMismatch(DependsOn.self, context)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    /// Convenience factory that mirrors the list-form decoder.
    public static func list(_ names: [String]) -> DependsOn {
        let defaultEntry = DependsOnEntry(condition: .serviceStarted, required: true, restart: false)
        let entries = Dictionary(uniqueKeysWithValues: names.map { ($0, defaultEntry) })
        return DependsOn(entries: entries)
    }
}
