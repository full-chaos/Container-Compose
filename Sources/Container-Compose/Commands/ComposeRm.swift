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

public struct ComposeRm: AsyncParsableCommand, ComposeCommand {
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

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()
        let projectName = resolveProjectName(for: dockerCompose)
        let resolvedServices = try filterServices(
            dockerCompose,
            profilesArg: profile,
            servicesArg: services
        )

        // Remove in reverse topo-sort order (dependents before dependencies).
        try await removeServices(resolvedServices.reversed(), projectName: projectName)
    }

    func removeServices(_ services: some Sequence<(serviceName: String, service: Service)>, projectName: String) async throws {
        if RuntimeExecutionMode.isRemote {
            let runtime = RuntimeEnvironment.current

            for (serviceName, service) in services {
                let containerName = effectiveContainerName(
                    projectName: projectName,
                    serviceName: serviceName,
                    explicit: service.container_name
                )

                guard let container = try? await runtime.get(id: containerName) else {
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
                        try await runtime.stop(id: container.id, options: .default)
                        print("Successfully stopped container: \(containerName)")
                    } catch {
                        print("Error stopping container '\(containerName)': \(error)")
                    }
                }

                if removeVolumes {
                    print("Note: Anonymous volume removal for '\(containerName)' is not fully supported by the remote runtime. Skipping volume removal.")
                }

                print("Removing container: \(containerName)")
                do {
                    try await runtime.remove(id: container.id, force: force && !stop && isRunning)
                    print("Successfully removed container: \(containerName)")
                } catch {
                    print("Error removing container '\(containerName)': \(error)")
                }
            }
            return
        }

        let provider = ContainerClientEnvironment.current

        for (serviceName, service) in services {
            let containerName = effectiveContainerName(
                projectName: projectName,
                serviceName: serviceName,
                explicit: service.container_name
            )

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
