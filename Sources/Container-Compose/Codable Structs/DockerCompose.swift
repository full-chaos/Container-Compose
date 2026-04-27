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
//  DockerCompose.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation
import Yams


/// Represents the top-level structure of a docker-compose.yml file.
public struct DockerCompose: Codable {
    /// The Compose file format version (e.g., '3.8')
    public let version: String?
    /// Optional project name
    public let name: String?
    /// Dictionary of service definitions, keyed by service name
    public let services: [String: Service?]
    /// Optional top-level volume definitions
    public let volumes: [String: Volume?]?
    /// Optional top-level network definitions
    public let networks: [String: Network?]?
    /// Optional top-level config definitions (primarily for Swarm)
    public let configs: [String: Config?]?
    /// Optional top-level secret definitions (primarily for Swarm)
    public let secrets: [String: Secret?]?
    /// Optional list of other compose files to include and merge.
    public let include: [IncludeEntry]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        services = try container.decode([String: Service?].self, forKey: .services)

        if let volumes = try container.decodeIfPresent([String: Optional<Volume>].self, forKey: .volumes) {
            let safeVolumes: [String: Volume] = volumes.mapValues { value in
                value ?? Volume()
            }
            self.volumes = safeVolumes
        } else {
            self.volumes = nil
        }
        networks = try container.decodeIfPresent([String: Network?].self, forKey: .networks)
        configs = try container.decodeIfPresent([String: Config?].self, forKey: .configs)
        secrets = try container.decodeIfPresent([String: Secret?].self, forKey: .secrets)
        include = try container.decodeIfPresent([IncludeEntry].self, forKey: .include)
    }

    enum CodingKeys: String, CodingKey {
        case version
        case name
        case services
        case volumes
        case networks
        case configs
        case secrets
        case include
    }
}

// MARK: - Memberwise init (used internally for merging)
extension DockerCompose {
    init(
        version: String?,
        name: String?,
        services: [String: Service?],
        volumes: [String: Volume?]?,
        networks: [String: Network?]?,
        configs: [String: Config?]?,
        secrets: [String: Secret?]?,
        include: [IncludeEntry]?
    ) {
        self.version = version
        self.name = name
        self.services = services
        self.volumes = volumes
        self.networks = networks
        self.configs = configs
        self.secrets = secrets
        self.include = include
    }
}

// MARK: - Multi-file merge
extension DockerCompose {
    /// Loads a compose file at `mainPath`, resolves its `include:` entries
    /// recursively, and returns a single merged `DockerCompose`.
    ///
    /// Merge order (compose-spec §include): included files are processed first
    /// (depth-first); the **main** file wins on any key collision, and a
    /// `Warning:` is printed for every overridden service/network/volume key.
    ///
    /// - Parameters:
    ///   - mainPath: Absolute or working-directory-relative path to the compose file.
    ///   - visited: Canonical paths already on the current call stack — used for
    ///     cycle detection. Pass the default empty set when calling from outside.
    /// - Throws: `IncludeError.cyclicInclude` if a cycle is detected,
    ///           `IncludeError.fileNotFound` if an included file is missing,
    ///           any `DecodingError` from the YAML decoder.
    public static func loadAndMerge(
        mainPath: String,
        visited: Set<String> = []
    ) throws -> DockerCompose {
        let fileManager = FileManager.default

        // Resolve to a canonical path to reliably detect cycles across relative
        // symlinks and ".." segments.
        let canonicalPath: String = (mainPath as NSString).standardizingPath

        // Cycle detection
        guard !visited.contains(canonicalPath) else {
            throw IncludeError.cyclicInclude(canonicalPath)
        }

        // Read the file
        guard let yamlData = fileManager.contents(atPath: canonicalPath),
              let yamlString = String(data: yamlData, encoding: .utf8) else {
            throw IncludeError.fileNotFound(mainPath)
        }

        // Decode the main file (without recursing into includes yet)
        let main = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)

        guard let includeEntries = main.include, !includeEntries.isEmpty else {
            // Nothing to merge
            return main
        }

        // Directory of the current file — used to resolve relative include paths.
        let baseDir = (canonicalPath as NSString).deletingLastPathComponent

        var newVisited = visited
        newVisited.insert(canonicalPath)

        // Start with an empty accumulator and fold in each included file.
        var merged = DockerCompose(
            version: nil,
            name: nil,
            services: [:],
            volumes: nil,
            networks: nil,
            configs: nil,
            secrets: nil,
            include: nil
        )

        for entry in includeEntries {
            for relativePath in entry.path {
                let includedPath: String
                if (relativePath as NSString).isAbsolutePath {
                    includedPath = relativePath
                } else {
                    includedPath = (baseDir as NSString).appendingPathComponent(relativePath)
                }
                let resolvedIncluded = (includedPath as NSString).standardizingPath

                let included = try loadAndMerge(mainPath: resolvedIncluded, visited: newVisited)
                merged = mergeTwo(base: merged, override: included)
            }
        }

        // Finally, the main file itself wins over everything included.
        return mergeTwo(base: merged, override: main)
    }

    /// Merges `override` on top of `base`.  For every key that exists in both,
    /// `override` wins and a warning is printed.  The `include` list is NOT
    /// propagated to the result (it has already been resolved).
    private static func mergeTwo(base: DockerCompose, override: DockerCompose) -> DockerCompose {
        // Services
        var mergedServices = base.services
        for (key, value) in override.services {
            if mergedServices[key] != nil {
                print("Warning: Service '\(key)' defined in multiple compose files; the later definition wins.")
            }
            mergedServices[key] = value
        }

        // Volumes
        var mergedVolumes: [String: Volume?]? = base.volumes
        if let overrideVolumes = override.volumes {
            var vols = mergedVolumes ?? [:]
            for (key, value) in overrideVolumes {
                if vols[key] != nil {
                    print("Warning: Volume '\(key)' defined in multiple compose files; the later definition wins.")
                }
                vols[key] = value
            }
            mergedVolumes = vols
        }

        // Networks
        var mergedNetworks: [String: Network?]? = base.networks
        if let overrideNetworks = override.networks {
            var nets = mergedNetworks ?? [:]
            for (key, value) in overrideNetworks {
                if nets[key] != nil {
                    print("Warning: Network '\(key)' defined in multiple compose files; the later definition wins.")
                }
                nets[key] = value
            }
            mergedNetworks = nets
        }

        // Configs — simple last-wins merge
        var mergedConfigs: [String: Config?]? = base.configs
        if let overrideConfigs = override.configs {
            var cfgs = mergedConfigs ?? [:]
            cfgs.merge(overrideConfigs) { _, new in new }
            mergedConfigs = cfgs
        }

        // Secrets — simple last-wins merge
        var mergedSecrets: [String: Secret?]? = base.secrets
        if let overrideSecrets = override.secrets {
            var secs = mergedSecrets ?? [:]
            secs.merge(overrideSecrets) { _, new in new }
            mergedSecrets = secs
        }

        return DockerCompose(
            version: override.version ?? base.version,
            name: override.name ?? base.name,
            services: mergedServices,
            volumes: mergedVolumes,
            networks: mergedNetworks,
            configs: mergedConfigs,
            secrets: mergedSecrets,
            include: nil  // resolved; not propagated
        )
    }
}
