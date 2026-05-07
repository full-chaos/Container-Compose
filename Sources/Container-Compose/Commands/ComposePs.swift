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
//  ComposePs.swift
//  Container-Compose
//

import ArgumentParser
import ContainerCommands
import ContainerAPIClient
import Foundation
import Yams

public struct ComposePs: AsyncParsableCommand, ComposeCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "ps",
        abstract: "List containers for this Compose project"
    )

    @Argument(help: "Filter output to specific services")
    var services: [String] = []

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Only display container IDs")
    var quiet: Bool = false

    @Flag(name: [.customShort("a"), .customLong("all")], help: "Include stopped containers")
    var all: Bool = false

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    public mutating func run() async throws {
        // Decode (and recursively merge includes) into the DockerCompose struct.
        let dockerCompose = try loadAndResolve()

        // Determine project name (CLI flag > compose `name:` > directory basename).
        let projectName = resolveProjectName(for: dockerCompose)

        // Build list of services from the compose file.
        var serviceList: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        // Filter by active profiles.
        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        serviceList = Service.filterByProfiles(serviceList, activeProfiles: activeProfiles)

        // Filter by CLI service arguments if provided.
        if !services.isEmpty {
            serviceList = serviceList.filter { services.contains($0.serviceName) }
        }

        // Determine the set of container names we care about.
        let targetNames: Set<String> = Set(serviceList.map { serviceName, service in
            effectiveContainerName(projectName: projectName, serviceName: serviceName, explicit: service.container_name)
        })

        // CHAOS-1346 Phase 1: read through the new `Runtime` abstraction
        // (`docs/plans/native-api-server.md`). Default conformer is
        // `BridgeContainerClientRuntime`, which delegates to
        // `ContainerClientProvider.list(filters: .all)` — so behavior is
        // byte-identical to the pre-Phase-1 path. This is the proof-of-life
        // wiring point that proves the abstraction.
        let runtime = RuntimeEnvironment.current
        let allContainers = try await runtime.list(filters: .all)

        // Keep only containers that belong to this project.
        // When --all is false, exclude stopped containers.
        let projectContainers = allContainers.filter { container in
            let belongsToProject = targetNames.contains(container.id)
                || container.id.hasPrefix("\(projectName)-")
            let statusOk = all || container.status == .running
            return belongsToProject && statusOk
        }

        if quiet {
            for container in projectContainers {
                print(container.id)
            }
            return
        }

        // Print formatted table.
        let nameWidth = max(4, projectContainers.map { $0.id.count }.max() ?? 4)
        let imageWidth = max(5, projectContainers.map { $0.imageReference.count }.max() ?? 5)
        let statusWidth = max(6, projectContainers.map { $0.status.rawValue.count }.max() ?? 6)

        let header = padded("NAME", nameWidth) + "  " + padded("IMAGE", imageWidth) + "  " + padded("STATUS", statusWidth) + "  " + "PORTS"
        print(header)

        for container in projectContainers {
            let name = padded(container.id, nameWidth)
            let image = padded(container.imageReference, imageWidth)
            let status = padded(container.status.rawValue, statusWidth)
            let publishedPorts = container.publishedPorts
            let ports: String
            if publishedPorts.isEmpty {
                ports = ""
            } else {
                ports = publishedPorts.map { port in
                    "\(port.hostAddress):\(port.hostPort)->\(port.containerPort)/\(port.proto.rawValue)"
                }.joined(separator: ", ")
            }
            print("\(name)  \(image)  \(status)  \(ports)")
        }
    }

    // MARK: - Formatting helpers

    private func padded(_ value: String, _ width: Int) -> String {
        value.padding(toLength: max(value.count, width), withPad: " ", startingAt: 0)
    }
}
