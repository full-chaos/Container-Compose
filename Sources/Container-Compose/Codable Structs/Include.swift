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
//  Include.swift
//  Container-Compose
//

import Foundation

/// Represents one entry in the top-level `include:` list of a compose file.
/// Supports both shorthand (a bare string path) and object form.
public struct IncludeEntry: Codable, Hashable {
    /// One or more paths to include. Shorthand decodes to a single-element array.
    public let path: [String]
    /// Optional env_file(s) to load for variable substitution in the included file.
    public let env_file: [String]?
    /// Optional project_directory override.
    public let project_directory: String?

    public init(path: [String], env_file: [String]? = nil, project_directory: String? = nil) {
        self.path = path
        self.env_file = env_file
        self.project_directory = project_directory
    }

    public init(from decoder: Decoder) throws {
        // Shorthand: a bare string
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self.path = [single]
            self.env_file = nil
            self.project_directory = nil
            return
        }
        // Object form
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // path can be a String or [String]
        if let arr = try? c.decode([String].self, forKey: .path) {
            self.path = arr
        } else {
            self.path = [try c.decode(String.self, forKey: .path)]
        }
        // env_file can be a String or [String]
        if let envArr = try? c.decode([String].self, forKey: .env_file) {
            self.env_file = envArr
        } else if let envSingle = try? c.decode(String.self, forKey: .env_file) {
            self.env_file = [envSingle]
        } else {
            self.env_file = nil
        }
        self.project_directory = try c.decodeIfPresent(String.self, forKey: .project_directory)
    }

    enum CodingKeys: String, CodingKey {
        case path
        case env_file
        case project_directory
    }
}

/// Errors thrown by the include / merge machinery.
public enum IncludeError: Error, LocalizedError {
    case cyclicInclude(String)
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .cyclicInclude(let path):
            return "Cyclic include detected: '\(path)' is already being loaded."
        case .fileNotFound(let path):
            return "Included compose file not found: '\(path)'"
        }
    }
}
