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

import Foundation

/// One entry in a service's `env_file` list. Compose-spec accepts three shapes
/// (`env_file: foo.env`, `env_file: [a.env, b.env]`, and a list of mappings
/// `[{path: foo.env, required: false}]`); all three normalize into `[EnvFileEntry]`.
public struct EnvFileEntry: Codable, Hashable, Sendable {
    public let path: String
    /// When `false`, a missing file at `path` is silently skipped. Defaults to `true`.
    public let required: Bool

    public init(path: String, required: Bool = true) {
        self.path = path
        self.required = required
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self.path = single
            self.required = true
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
    }

    enum CodingKeys: String, CodingKey {
        case path, required
    }
}

extension Array where Element == EnvFileEntry {
    /// Decode the `env_file` field on a service, accepting any of the three
    /// compose-spec shapes. Returns nil when the key is absent.
    static func decodeEnvFile<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> [EnvFileEntry]? {
        guard container.contains(key) else { return nil }
        if let single = try? container.decode(String.self, forKey: key) {
            return [EnvFileEntry(path: single)]
        }
        return try container.decode([EnvFileEntry].self, forKey: key)
    }
}
