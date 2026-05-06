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
//  ComposeStop.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import Yams

public struct ComposeStop: AsyncParsableCommand, ComposeCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "stop",
        abstract: "Stop running containers without removing them"
    )

    @Argument(help: "Specify the services to stop")
    var services: [String] = []

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

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    private var fileManager: FileManager { FileManager.default }

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()
        let projectName = resolveProjectName(for: dockerCompose)
        let resolvedServices = try filterServices(
            dockerCompose,
            profilesArg: profile,
            servicesArg: services
        )

        // Stop in REVERSE topo-sort order: dependents before dependencies.
        try await stopServices(resolvedServices.reversed(), projectName: projectName)
    }

    func stopServices(_ services: some Sequence<(serviceName: String, service: Service)>, projectName: String) async throws {
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

                print("Stopping container: \(containerName)")
                do {
                    try await runtime.stop(id: container.id, options: .default)
                    print("Successfully stopped container: \(containerName)")
                } catch {
                    print("Error stopping container '\(containerName)': \(error)")
                }
            }
            return
        }

        for (serviceName, service) in services {
            let containerName = effectiveContainerName(
                projectName: projectName,
                serviceName: serviceName,
                explicit: service.container_name
            )

            let provider = ContainerClientEnvironment.current
            guard let container = try? await provider.get(id: containerName) else {
                print("Warning: Container '\(containerName)' not found, skipping.")
                continue
            }

            print("Stopping container: \(containerName)")
            do {
                try await provider.stop(id: container.id, opts: .default)
                print("Successfully stopped container: \(containerName)")
            } catch {
                print("Error stopping container '\(containerName)': \(error)")
            }
        }
    }
}
