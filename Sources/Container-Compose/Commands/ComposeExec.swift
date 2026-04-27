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
//  ComposeExec.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import Yams

public struct ComposeExec: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "exec",
        abstract: "Execute a command in a running service container"
    )

    @Argument(help: "The service to execute a command in")
    var serviceName: String

    @Argument(parsing: .captureForPassthrough, help: "Command to execute")
    var command: [String]

    @Flag(name: [.customLong("exec-detach")], help: "Run command in the background")
    var detach: Bool = false

    /// When true (the default), passes -i to `container exec`.
    /// Pass --no-exec-interactive to suppress.
    @Flag(name: [.customLong("no-exec-interactive")], help: "Disable STDIN passthrough (default: interactive is on)")
    var noInteractive: Bool = false

    /// When true (the default), passes -t to `container exec`.
    /// Pass --no-exec-tty to suppress.
    @Flag(name: [.customLong("no-exec-tty")], help: "Disable TTY allocation (default: tty is on)")
    var noTty: Bool = false

    @Option(name: [.customLong("exec-env")], help: "Set an environment variable KEY=VALUE (can be repeated)")
    var environment: [String] = []

    @Option(name: [.customLong("exec-user")], help: "Run as specified username or uid")
    var user: String?

    @Option(name: [.customLong("exec-workdir")], help: "Working directory inside the container")
    var workdir: String?

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    // MARK: - Convenience accessors

    /// Whether to pass -i to container exec (default true, negated by --no-exec-interactive).
    var interactive: Bool { !noInteractive }

    /// Whether to pass -t to container exec (default true, negated by --no-exec-tty).
    var tty: Bool { !noTty }

    // MARK: - Computed helpers

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    private var cwdURL: URL { URL(fileURLWithPath: cwd) }

    /// Project root for outside-container relative-path resolution. Honors
    /// `--project-directory`, falls back to the compose file's directory.
    private var effectiveProjectDirectory: String {
        resolveProjectDirectory(
            cliOverride: projectFlags.projectDirectory,
            composeFilePath: composePath,
            cwd: cwd
        )
    }

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
        // 1. Load compose file for project-name resolution
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        // 2. Determine project name (CLI flag > compose `name:` > directory basename).
        let projectName = resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )

        // 3. Resolve service — find the service definition (needed for container_name override)
        let allServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        let service = allServices.first(where: { $0.serviceName == serviceName })?.service

        // 4. Determine container name: use container_name override if set, else <project>-<service>
        let containerName: String
        if let explicit = service?.container_name {
            containerName = explicit
        } else {
            containerName = "\(projectName)-\(serviceName)"
        }

        // 5. Build exec argv
        var execArgs: [String] = []

        if detach {
            execArgs.append("-d")
        }

        if interactive {
            execArgs.append("-i")
        }

        if tty {
            execArgs.append("-t")
        }

        for envVar in environment {
            execArgs.append(contentsOf: ["-e", envVar])
        }

        if let userOverride = user {
            execArgs.append(contentsOf: ["--user", userOverride])
        }

        if let wd = workdir {
            execArgs.append(contentsOf: ["--workdir", wd])
        }

        // Container name and command
        execArgs.append(containerName)
        execArgs.append(contentsOf: command)

        // 6. Shell out to `container exec`
        print("Executing in container '\(containerName)': \(command.joined(separator: " "))")

        let _ = try await shellExec(args: execArgs)
    }

    // MARK: - Shell exec helper

    @discardableResult
    private func shellExec(args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["container", "exec"] + args
            proc.currentDirectoryURL = cwdURL
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            proc.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]) { _, new in new }

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let str = String(data: data, encoding: .utf8) {
                    print(str, terminator: "")
                }
            }

            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let str = String(data: data, encoding: .utf8) {
                    fputs(str, stderr)
                }
            }

            proc.terminationHandler = { p in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                continuation.resume(returning: p.terminationStatus)
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
