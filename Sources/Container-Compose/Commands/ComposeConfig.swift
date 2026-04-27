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
//  ComposeConfig.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import ContainerCommands
import Foundation
import Yams

public struct ComposeConfig: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "config",
        abstract: "Parse, resolve and render the compose file"
    )

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @Flag(name: [.long], help: "Print service names, one per line")
    var services: Bool = false

    @Flag(name: [.long], help: "Print volume names, one per line")
    var volumes: Bool = false

    @Flag(name: [.long], help: "Print the union of all service profiles, one per line")
    var profiles: Bool = false

    @Flag(name: [.long], help: "Skip environment-variable substitution")
    var noInterpolate: Bool = false

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    // MARK: - Helpers

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    /// Project root for outside-container relative-path resolution. Honors
    /// `--project-directory`, falls back to the compose file's directory.
    private var effectiveProjectDirectory: String {
        resolveProjectDirectory(
            cliOverride: projectFlags.projectDirectory,
            composeFilePath: composePath,
            cwd: cwd
        )
    }

    private var cwdURL: URL { URL(fileURLWithPath: cwd) }

    private static let supportedComposeFilenames = [
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    ]

    private var composePath: String {
        if let composeFilename {
            return resolvedPath(for: composeFilename, relativeTo: cwdURL)
        }
        for filename in Self.supportedComposeFilenames {
            let candidate = cwdURL.appending(path: filename).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return cwdURL.appending(path: Self.supportedComposeFilenames[0]).path
    }

    // MARK: - run()

    public mutating func run() async throws {
        // Step 1: Load + merge include entries + resolve extends.
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        // Step 2: Env-interpolation.
        // TODO: Implement full in-model env-variable substitution so that
        //       ${VAR} references in image, command, environment values, etc.
        //       are resolved before encoding to YAML. Currently the raw
        //       (unsubstituted) model is emitted regardless of --no-interpolate.
        if !noInterpolate {
            fputs(
                "Warning: env-variable interpolation is not yet implemented; " +
                "--no-interpolate is effectively always on.\n",
                stderr
            )
        }

        // Step 3: Filter services by active profiles.
        var serviceList: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, svc in
            guard let svc else { return nil }
            return (name, svc)
        }
        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        serviceList = Service.filterByProfiles(serviceList, activeProfiles: activeProfiles)

        // Step 4: Handle filter flags.
        if services {
            let names = serviceList.map(\.serviceName).sorted()
            for name in names { print(name) }
            return
        }

        if volumes {
            let names = (dockerCompose.volumes ?? [:]).keys.sorted()
            for name in names { print(name) }
            return
        }

        if profiles {
            let allProfiles = Set(serviceList.flatMap { $0.service.profiles ?? [] })
            for profile in allProfiles.sorted() { print(profile) }
            return
        }

        // Step 5: Encode and print the full compose YAML.
        let yaml = try YAMLEncoder().encode(dockerCompose)
        print(yaml)
    }
}
