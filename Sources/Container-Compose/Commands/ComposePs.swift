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

public struct ComposePs: AsyncParsableCommand {
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

    @Flag(name: .long, help: "Include stopped containers")
    var all: Bool = false

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var logging: Flags.Logging

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

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
        // Decode (and recursively merge includes) into the DockerCompose struct.
        let dockerCompose = try DockerCompose.loadAndMerge(mainPath: composePath).resolvingExtends()

        // Determine project name
        let projectName: String
        if let name = dockerCompose.name {
            projectName = name
        } else {
            projectName = deriveProjectName(cwd: cwd)
        }

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
            service.container_name ?? "\(projectName)-\(serviceName)"
        })

        // Fetch containers from the runtime.
        // list() with no arguments returns all containers (running + stopped).
        // When --all is not set, filter to running containers only in Swift.
        let client = ContainerClient()
        let allContainers = try await client.list()

        // Keep only containers that belong to this project.
        // When --all is false, exclude stopped containers.
        let projectContainers = allContainers.filter { container in
            let id = container.configuration.id
            let belongsToProject = targetNames.contains(id) || id.hasPrefix("\(projectName)-")
            let statusOk = all || container.status == .running
            return belongsToProject && statusOk
        }

        if quiet {
            for container in projectContainers {
                print(container.configuration.id)
            }
            return
        }

        // Print formatted table.
        let nameWidth = max(4, projectContainers.map { $0.configuration.id.count }.max() ?? 4)
        let imageWidth = max(5, projectContainers.map { $0.configuration.image.reference.count }.max() ?? 5)
        let statusWidth = max(6, projectContainers.map { $0.status.rawValue.count }.max() ?? 6)

        let header = padded("NAME", nameWidth) + "  " + padded("IMAGE", imageWidth) + "  " + padded("STATUS", statusWidth) + "  " + "PORTS"
        print(header)

        for container in projectContainers {
            let name = padded(container.configuration.id, nameWidth)
            let image = padded(container.configuration.image.reference, imageWidth)
            let status = padded(container.status.rawValue, statusWidth)
            let publishedPorts = container.configuration.publishedPorts
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
