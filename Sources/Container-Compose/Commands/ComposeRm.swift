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
//  ComposeRm.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import Yams

public struct ComposeRm: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "rm",
        abstract: "Remove stopped project containers"
    )

    @Argument(help: "Specify the services whose containers should be removed")
    var services: [String] = []

    @Flag(
        name: [.customShort("f"), .customLong("force")],
        help: "Remove containers even if they are running"
    )
    var force: Bool = false

    @Flag(
        name: [.customShort("s"), .customLong("stop")],
        help: "Stop the containers before removing them"
    )
    var stop: Bool = false

    @Flag(
        name: [.customShort("v"), .customLong("volumes")],
        help: "Remove anonymous volumes associated with the containers"
    )
    var removeVolumes: Bool = false

    // NOTE: -f is already taken by --force, so --file uses long-only spelling.
    @Option(name: [.long], help: "The path to your Docker Compose file")
    var file: String?

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    // Expose a composeFilename alias so tests can address this field by the
    // conventional name used by other commands.
    var composeFilename: String? { file }

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
        if let file {
            return resolvedPath(for: file, relativeTo: cwdURL)
        }
        for filename in Self.supportedComposeFilenames {
            let candidate = cwdURL.appending(path: filename).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return cwdURL.appending(path: Self.supportedComposeFilenames[0]).path
    }

    public mutating func run() async throws {
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        // Precedence: --project-name CLI flag > compose file `name:` > directory basename.
        let projectName = resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )
        if let cliName = projectFlags.projectName, !cliName.isEmpty {
            print("Info: Using project name from --project-name flag: \(cliName)")
        } else if dockerCompose.name != nil {
            print("Info: Docker Compose project name: \(projectName)")
        } else {
            print("Info: Using directory name as project name: \(projectName)")
        }

        var resolvedServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        resolvedServices = Service.filterByProfiles(resolvedServices, activeProfiles: activeProfiles)

        resolvedServices = try Service.topoSortConfiguredServices(resolvedServices)

        if !self.services.isEmpty {
            resolvedServices = resolvedServices.filter { serviceName, service in
                self.services.contains(serviceName) || self.services.contains(where: { service.dependedBy.contains($0) })
            }
        }

        // Remove in reverse topo-sort order (dependents before dependencies).
        try await removeServices(resolvedServices.reversed(), projectName: projectName)
    }

    func removeServices(_ services: some Sequence<(serviceName: String, service: Service)>, projectName: String) async throws {
        let provider = ContainerClientEnvironment.current

        for (serviceName, service) in services {
            let containerName: String
            if let explicitName = service.container_name {
                containerName = explicitName
            } else {
                containerName = "\(projectName)-\(serviceName)"
            }

            guard let container = try? await provider.get(id: containerName) else {
                print("Warning: Container '\(containerName)' not found, skipping.")
                continue
            }

            let isRunning = container.status == .running

            if isRunning && !force {
                print("Warning: Container '\(containerName)' is running. Use --force to remove running containers. Skipping.")
                continue
            }

            if isRunning && force && stop {
                print("Stopping container before removal: \(containerName)")
                do {
                    try await provider.stop(id: container.id, opts: .default)
                    print("Successfully stopped container: \(containerName)")
                } catch {
                    print("Error stopping container '\(containerName)': \(error)")
                }
            }

            if removeVolumes {
                print("Note: Anonymous volume removal for '\(containerName)' is not fully supported by the ContainerClient API. Skipping volume removal.")
            }

            print("Removing container: \(containerName)")
            do {
                try await provider.delete(id: container.id, force: false)
                print("Successfully removed container: \(containerName)")
            } catch {
                print("Error removing container '\(containerName)': \(error)")
            }
        }
    }
}
