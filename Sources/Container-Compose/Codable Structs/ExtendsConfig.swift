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
//  ExtendsConfig.swift
//  Container-Compose
//
//  Created for Phase 3F — extends resolution
//

import Foundation

/// Represents the `extends:` field on a service definition.
/// Supports both shorthand (`extends: service-name`) and map form
/// (`extends: { service: service-name, file: ./other.yml }`).
public struct ExtendsConfig: Codable, Hashable {
    /// Name of the service to inherit from.
    public let service: String
    /// Optional path to another Compose file that contains the base service.
    public let file: String?

    public init(service: String, file: String? = nil) {
        self.service = service
        self.file = file
    }

    public init(from decoder: Decoder) throws {
        // Shorthand: a single string is the service name (in the same file)
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.service = s
            self.file = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.service = try c.decode(String.self, forKey: .service)
        self.file = try c.decodeIfPresent(String.self, forKey: .file)
    }

    enum CodingKeys: String, CodingKey { case service, file }
}
