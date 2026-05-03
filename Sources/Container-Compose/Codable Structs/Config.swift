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
//  Config.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a top-level config definition (primarily for Swarm).
public struct Config: Codable {
    /// Path to the file containing the config content
    public let file: String?
    /// Indicates if the config is external (pre-existing)
    public let external: ExternalConfig?
    /// Explicit name for the config
    public let name: String?
    /// Labels for the config
    public let labels: [String: String]?
    /// Inline literal content of the config.
    /// Alternative source — bind-mount support is a follow-up issue.
    public let content: String?
    /// Name of an env var whose value becomes the config content.
    /// Alternative source — bind-mount support is a follow-up issue.
    public let environment: String?
    /// Name of the templating driver used to render the config value.
    /// `golang` is rendered host-side before bind-mounting.
    public let templateDriver: String?

    /// Public memberwise initializer for testing and direct construction.
    public init(
        file: String? = nil,
        external: ExternalConfig? = nil,
        name: String? = nil,
        labels: [String: String]? = nil,
        content: String? = nil,
        environment: String? = nil,
        templateDriver: String? = nil
    ) {
        self.file = file
        self.external = external
        self.name = name
        self.labels = labels
        self.content = content
        self.environment = environment
        self.templateDriver = templateDriver
    }

    enum CodingKeys: String, CodingKey {
        case file, external, name, labels, content, environment
        case templateDriver = "template_driver"
    }

    /// Custom initializer to handle `external: true` (boolean) or `external: { name: "my_cfg" }` (object).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        environment = try container.decodeIfPresent(String.self, forKey: .environment)
        templateDriver = try container.decodeIfPresent(String.self, forKey: .templateDriver)

        if let externalBool = try? container.decodeIfPresent(Bool.self, forKey: .external) {
            external = ExternalConfig(isExternal: externalBool, name: nil)
        } else if let externalDict = try? container.decodeIfPresent([String: String].self, forKey: .external) {
            external = ExternalConfig(isExternal: true, name: externalDict["name"])
        } else {
            external = nil
        }
    }
}
