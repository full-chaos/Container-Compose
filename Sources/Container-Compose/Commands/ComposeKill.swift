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
//  ComposeKill.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import Yams

public struct ComposeKill: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "kill",
        abstract: "Force-stop project containers"
    )

    @Argument(help: "Specify the services to kill")
    var services: [String] = []

    @Option(
        name: [.customShort("s"), .customLong("signal")],
        help: "Signal to send to the container (default SIGKILL)"
    )
    var signal: String = "SIGKILL"

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

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

        // Kill in REVERSE topo-sort order: dependents before dependencies.
        try await killServices(resolvedServices.reversed(), projectName: projectName)
    }

    func killServices(_ services: some Sequence<(serviceName: String, service: Service)>, projectName: String) async throws {
        for (serviceName, service) in services {
            let containerName: String
            if let explicitName = service.container_name {
                containerName = explicitName
            } else {
                containerName = "\(projectName)-\(serviceName)"
            }

            guard let container = try? await ContainerClient().get(id: containerName) else {
                print("Warning: Container '\(containerName)' not found, skipping.")
                continue
            }

            print("Killing container: \(containerName) (signal: \(signal))")
            do {
                // ContainerClient does not expose a kill(id:signal:) method;
                // shell out to `container kill --signal <sig> <name>` instead.
                try await shellKill(containerName: container.id)
                print("Successfully killed container: \(containerName)")
            } catch {
                print("Error killing container '\(containerName)': \(error)")
            }
        }
    }

    private func shellKill(containerName: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["container", "kill", "--signal", signal, containerName]
            proc.currentDirectoryURL = cwdURL
            proc.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]) { _, new in new }

            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "ComposeKill",
                        code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "container kill exited with status \(p.terminationStatus)"]
                    ))
                }
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
