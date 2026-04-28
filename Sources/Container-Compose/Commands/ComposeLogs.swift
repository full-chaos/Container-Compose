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
//  ComposeLogs.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation
@preconcurrency import Rainbow
import Yams

public struct ComposeLogs: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "logs",
        abstract: "View output from containers"
    )

    @Argument(help: "Services to show logs for (shows all if omitted)")
    var services: [String] = []

    @Flag(
        name: [.customShort("f"), .customLong("follow")],
        help: "Follow log output"
    )
    var follow: Bool = false

    @Option(name: [.long], help: "Number of lines to show from the end of the logs (e.g. '100' or 'all')")
    var tail: String?

    @Option(name: [.long], help: "Show logs since timestamp or relative duration (warning: not supported by 'container logs')")
    var since: String?

    @Flag(name: [.long], help: "Show timestamps (warning: not supported by 'container logs')")
    var timestamps: Bool = false

    @Flag(name: [.long], help: "Disable colour prefixes in log output")
    var noColor: Bool = false

    @Option(name: [.long], help: "The path to your Docker Compose file")
    var file: String?

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

    // MARK: - Color palette (mirrors ComposeUp)

    private static let availableContainerConsoleColors: [NamedColor] = [
        .blue, .cyan, .magenta, .lightBlack, .lightBlue, .lightCyan,
        .lightYellow, .yellow, .lightGreen, .green,
    ]

    private func color(for index: Int) -> NamedColor {
        Self.availableContainerConsoleColors[index % Self.availableContainerConsoleColors.count]
    }

    // MARK: - run()

    public mutating func run() async throws {
        // Warn about unsupported flags that would be passed to `container logs`
        if since != nil {
            print("Warning: --since is not supported by 'container logs' and will be ignored.")
        }
        if timestamps {
            print("Warning: --timestamps is not supported by 'container logs' and will be ignored.")
        }

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

        // 3. Resolve all services
        var allServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        // 4. Filter to requested services (or use all)
        if !services.isEmpty {
            allServices = allServices.filter { services.contains($0.serviceName) }
        }

        if allServices.isEmpty {
            print("No services found.")
            return
        }

        // 5. Build list of (serviceName, containerName) pairs, respecting container_name overrides
        let targets: [(serviceName: String, containerName: String)] = allServices.map { serviceName, service in
            let containerName = service.container_name ?? "\(projectName)-\(serviceName)"
            return (serviceName, containerName)
        }

        // 6. Determine tail line count (nil means all)
        let numLines: Int?
        if let tailStr = tail {
            if tailStr.lowercased() == "all" {
                numLines = nil
            } else if let n = Int(tailStr) {
                numLines = n
            } else {
                print("Warning: --tail value '\(tailStr)' is not a valid integer or 'all'. Showing all logs.")
                numLines = nil
            }
        } else {
            numLines = nil
        }

        // 7. Stream logs
        let noColorFlag = noColor
        if follow {
            // Concurrent follow mode — each service runs in its own Task
            await withTaskGroup(of: Void.self) { group in
                for (index, (serviceName, containerName)) in targets.enumerated() {
                    let serviceColor = color(for: index)
                    let lines = numLines
                    group.addTask {
                        await ComposeLogs.streamLogs(
                            containerName: containerName,
                            serviceName: serviceName,
                            serviceColor: serviceColor,
                            noColor: noColorFlag,
                            numLines: lines,
                            follow: true
                        )
                    }
                }
            }
        } else {
            // Sequential mode — read each container's logs in order
            for (index, (serviceName, containerName)) in targets.enumerated() {
                let serviceColor = color(for: index)
                await ComposeLogs.streamLogs(
                    containerName: containerName,
                    serviceName: serviceName,
                    serviceColor: serviceColor,
                    noColor: noColorFlag,
                    numLines: numLines,
                    follow: false
                )
            }
        }
    }

    // MARK: - Log streaming helper

    private static func streamLogs(
        containerName: String,
        serviceName: String,
        serviceColor: NamedColor,
        noColor: Bool,
        numLines: Int?,
        follow: Bool
    ) async {
        let provider = ContainerClientEnvironment.current

        let fhs: [FileHandle]
        do {
            fhs = try await provider.logs(id: containerName)
        } catch {
            let msg = "Warning: Could not retrieve logs for container '\(containerName)': \(error.localizedDescription)"
            print(noColor ? msg : msg.applyingColor(.red))
            return
        }

        guard let fh = fhs.first else {
            print("Warning: No log file handle returned for container '\(containerName)'.")
            return
        }

        // Format a line with the service prefix
        func prefixed(_ line: String) -> String {
            let prefix = "\(serviceName) |"
            let full = "\(prefix) \(line)"
            return noColor ? full : full.applyingColor(serviceColor)
        }

        // Tail mode: seek backwards and collect N lines
        if let n = numLines {
            var buffer = Data()
            guard let totalSize = try? fh.seekToEnd() else { return }
            var offset = totalSize
            var lines: [String] = []

            while offset > 0, lines.count < n {
                let readSize = UInt64(min(1024, offset))
                offset -= readSize
                guard (try? fh.seek(toOffset: offset)) != nil else { break }
                let data = fh.readData(ofLength: Int(readSize))
                buffer.insert(contentsOf: data, at: 0)
                if let chunk = String(data: buffer, encoding: .utf8) {
                    lines = chunk.components(separatedBy: .newlines).filter { !$0.isEmpty }
                }
            }

            lines = Array(lines.suffix(n))
            for line in lines {
                print(prefixed(line))
            }
        } else {
            // Full log read
            guard let data = try? fh.readToEnd(), let str = String(data: data, encoding: .utf8) else {
                return
            }
            let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for line in lines {
                print(prefixed(line))
            }
        }

        fflush(stdout)

        // Follow mode: attach readability handler and stream new lines
        if follow {
            _ = try? fh.seekToEnd()
            let stream = AsyncStream<String> { cont in
                fh.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        do {
                            _ = try fh.seekToEnd()
                        } catch {
                            fh.readabilityHandler = nil
                            cont.finish()
                            return
                        }
                    }
                    if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                        let newLines = s.components(separatedBy: .newlines).filter { !$0.isEmpty }
                        for l in newLines {
                            cont.yield(l)
                        }
                    }
                }
            }
            for await line in stream {
                print(prefixed(line))
            }
        }
    }
}
