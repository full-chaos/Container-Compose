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

/// Represents a ulimit value, accepting either a scalar Int (sets both soft and hard)
/// or an object with `soft` and `hard` keys.
///
/// YAML examples:
///   nofile: 1024
///   nofile:
///     soft: 1024
///     hard: 65536
public struct Ulimit: Codable, Hashable {
    public let soft: Int
    public let hard: Int

    public init(soft: Int, hard: Int) {
        self.soft = soft
        self.hard = hard
    }

    /// Convenience initializer that sets both soft and hard to the same value.
    public init(value: Int) {
        self.soft = value
        self.hard = value
    }

    enum CodingKeys: String, CodingKey {
        case soft, hard
    }

    public init(from decoder: Decoder) throws {
        // Try scalar Int first (sets both soft and hard)
        if let singleValue = try? decoder.singleValueContainer(),
           let scalar = try? singleValue.decode(Int.self) {
            self.soft = scalar
            self.hard = scalar
            return
        }

        // Try object form { soft: ..., hard: ... }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.soft = try container.decode(Int.self, forKey: .soft)
        self.hard = try container.decode(Int.self, forKey: .hard)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(soft, forKey: .soft)
        try container.encode(hard, forKey: .hard)
    }
}
