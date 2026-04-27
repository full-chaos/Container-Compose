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
//  Build.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents the `build` configuration for a service.
public struct Build: Codable, Hashable {
    /// Path to the build context
    public let context: String
    /// Optional path to the Dockerfile within the context
    public let dockerfile: String?
    /// Build arguments
    public let args: [String: String]?
    /// Build stage target
    public let target: String?
    /// Inline Dockerfile content (takes priority over `dockerfile` when both are set)
    public let dockerfile_inline: String?
    /// Image references to use as cache sources
    public let cache_from: [String]?
    /// Image references to export build cache to
    public let cache_to: [String]?
    /// Labels to apply to the built image
    public let labels: [String: String]?
    /// Network mode to use during build
    public let network: String?
    /// Secret IDs to expose during build
    public let secrets: [String]?
    /// SSH agent socket or key mappings to expose during build
    public let ssh: [String]?
    /// Target platforms for the build (only the first platform is used)
    public let platforms: [String]?
    /// Size of /dev/shm during build
    public let shm_size: String?

    /// Custom initializer to handle `build: .` (string) or `build: { context: . }` (object)
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let contextString = try? container.decode(String.self) {
            self.context = contextString
            self.dockerfile = nil
            self.args = nil
            self.target = nil
            self.dockerfile_inline = nil
            self.cache_from = nil
            self.cache_to = nil
            self.labels = nil
            self.network = nil
            self.secrets = nil
            self.ssh = nil
            self.platforms = nil
            self.shm_size = nil
        } else {
            let keyedContainer = try decoder.container(keyedBy: CodingKeys.self)
            self.context = try keyedContainer.decode(String.self, forKey: .context)
            self.dockerfile = try keyedContainer.decodeIfPresent(String.self, forKey: .dockerfile)
            self.args = try keyedContainer.decodeIfPresent([String: String].self, forKey: .args)
            self.target = try keyedContainer.decodeIfPresent(String.self, forKey: .target)
            self.dockerfile_inline = try keyedContainer.decodeIfPresent(String.self, forKey: .dockerfile_inline)
            self.cache_from = try keyedContainer.decodeIfPresent([String].self, forKey: .cache_from)
            self.cache_to = try keyedContainer.decodeIfPresent([String].self, forKey: .cache_to)
            self.labels = try keyedContainer.decodeIfPresent([String: String].self, forKey: .labels)
            self.network = try keyedContainer.decodeIfPresent(String.self, forKey: .network)
            self.secrets = try keyedContainer.decodeIfPresent([String].self, forKey: .secrets)
            self.ssh = try keyedContainer.decodeIfPresent([String].self, forKey: .ssh)
            self.platforms = try keyedContainer.decodeIfPresent([String].self, forKey: .platforms)
            self.shm_size = try keyedContainer.decodeIfPresent(String.self, forKey: .shm_size)
        }
    }

    enum CodingKeys: String, CodingKey {
        case context, dockerfile, args, target, dockerfile_inline, cache_from, cache_to, labels, network, secrets, ssh, platforms, shm_size
    }
}
