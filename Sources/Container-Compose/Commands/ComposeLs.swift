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
//  ComposeLs.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation

public struct ComposeLs: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "ls",
        abstract: "List Compose projects on the host"
    )

    @Flag(name: [.customShort("a"), .customLong("all")], help: "Include stopped projects")
    var all: Bool = false

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Only display project names")
    var quiet: Bool = false

    @OptionGroup
    var logging: Flags.Logging

    // MARK: - Project name parsing

    /// Extracts the compose project name from a container ID using the convention
    /// `<project>-<service>`. The last dash is treated as the separator, so
    /// `my-cool-proj-web` → `my-cool-proj`. Returns `nil` when there is no dash.
    public static func extractProject(from containerID: String) -> String? {
        guard let lastDashIndex = containerID.lastIndex(of: "-") else {
            return nil
        }
        let project = String(containerID[containerID.startIndex..<lastDashIndex])
        guard !project.isEmpty else { return nil }
        return project
    }

    // MARK: - run

    public mutating func run() async throws {
        let client = ContainerClient()

        // List all containers; filter stopped ones below when --all is not set.
        let containers = try await client.list(filters: .all)

        // Build a project summary: project name → (running count, exited count).
        // Use String rawValues to avoid referencing ContainerSnapshot/RuntimeStatus by name.
        var runningCount: [String: Int] = [:]
        var exitedCount: [String: Int] = [:]

        for container in containers {
            guard let project = ComposeLs.extractProject(from: container.id) else {
                continue
            }
            let statusValue = container.status.rawValue
            if statusValue == "running" {
                runningCount[project, default: 0] += 1
            } else {
                exitedCount[project, default: 0] += 1
            }
        }

        // Collect all project names seen.
        var allProjects = Set(runningCount.keys).union(exitedCount.keys)

        // If --all is not set, show only projects that have at least one running container.
        if !all {
            allProjects = allProjects.filter { runningCount[$0, default: 0] > 0 }
        }

        let sortedProjects = allProjects.sorted()

        if quiet {
            for project in sortedProjects {
                print(project)
            }
            return
        }

        // Full table output.
        if sortedProjects.isEmpty {
            print("No compose projects found.")
            return
        }

        let nameWidth = max(
            sortedProjects.map { $0.count }.max() ?? 0,
            "NAME".count
        )

        print(String(format: "%-\(nameWidth)s  %s", "NAME", "STATUS"))

        for project in sortedProjects {
            let running = runningCount[project, default: 0]
            let exited = exitedCount[project, default: 0]
            let total = running + exited

            let statusString: String
            if running == total {
                statusString = "running(\(running))"
            } else if exited == total {
                statusString = "exited(\(exited))"
            } else {
                statusString = "running(\(running)), exited(\(exited))"
            }

            print(String(format: "%-\(nameWidth)s  %s", project, statusString))
        }
    }
}
