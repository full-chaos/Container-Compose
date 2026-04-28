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
//  ComposeTop.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation
@preconcurrency import Rainbow
import Yams

public struct ComposeTop: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "top",
        abstract: "Display running processes in project containers"
    )

    @Argument(help: "Services to show processes for (shows all if omitted)")
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

    // MARK: - Computed helpers

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

    // MARK: - Color palette (mirrors ComposeLogs)

    private static let availableContainerConsoleColors: [NamedColor] = [
        .blue, .cyan, .magenta, .lightBlack, .lightBlue, .lightCyan,
        .lightYellow, .yellow, .lightGreen, .green,
    ]

    private func color(for index: Int) -> NamedColor {
        Self.availableContainerConsoleColors[index % Self.availableContainerConsoleColors.count]
    }

    // MARK: - run()

    public mutating func run() async throws {
        // 1. Load and merge compose file
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        // 2. Determine project name (CLI flag > compose `name:` > directory basename).
        let projectName = resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )

        // 3. Resolve all services and active profiles
        var serviceList: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        serviceList = Service.filterByProfiles(serviceList, activeProfiles: activeProfiles)

        // 4. Filter to requested services (or use all)
        if !services.isEmpty {
            serviceList = serviceList.filter { services.contains($0.serviceName) }
        }

        if serviceList.isEmpty {
            print("No services found.")
            return
        }

        // 5. List running project containers matching the selected services
        let provider = ContainerClientEnvironment.current
        let allContainers = try await provider.list(filters: .all)
        let targets = targetDescriptors(projectName: projectName, services: serviceList)

        let projectContainers = allContainers.compactMap { container -> (containerName: String, serviceName: String, color: NamedColor)? in
            guard container.status == .running else { return nil }
            let containerName = container.configuration.id
            guard let target = matchingTarget(for: containerName, targets: targets) else { return nil }
            return (containerName, target.serviceName, target.color)
        }

        if projectContainers.isEmpty {
            print("No running containers found.")
            return
        }

        // 6. Shell out to `container exec <id> ps -ef` for each running container
        for container in projectContainers {
            try await streamProcessList(
                containerName: container.containerName,
                serviceColor: container.color
            )
        }
    }

    // MARK: - Matching helpers

    private func targetDescriptors(
        projectName: String,
        services: [(serviceName: String, service: Service)]
    ) -> [(serviceName: String, baseName: String, explicitName: String?, color: NamedColor)] {
        services.enumerated().map { index, entry in
            (
                serviceName: entry.serviceName,
                baseName: "\(projectName)-\(entry.serviceName)",
                explicitName: entry.service.container_name,
                color: color(for: index)
            )
        }
    }

    private func matchingTarget(
        for containerName: String,
        targets: [(serviceName: String, baseName: String, explicitName: String?, color: NamedColor)]
    ) -> (serviceName: String, color: NamedColor)? {
        for target in targets {
            if containerName == target.baseName || containerName.hasPrefix("\(target.baseName)-") || containerName == target.explicitName {
                return (target.serviceName, target.color)
            }
        }
        return nil
    }

    // MARK: - Process-list streaming

    private func streamProcessList(
        containerName: String,
        serviceColor: NamedColor
    ) async throws {
        @Sendable
        func prefixed(_ line: String) -> String {
            "\(containerName) | \(line)".applyingColor(serviceColor)
        }

        let request = RunRequest(
            kind: .streaming,
            argv: ["container", "exec", containerName, "ps", "-ef"],
            cwd: cwd
        )

        let _ = try await RunnerEnvironment.current.run(
            request,
            onStdout: { line in print(prefixed(line)) },
            onStderr: { line in fputs("\(prefixed(line))\n", stderr) }
        )
    }
}
