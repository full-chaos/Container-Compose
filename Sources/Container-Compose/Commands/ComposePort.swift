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
//  ComposePort.swift
//  Container-Compose
//

import ArgumentParser
import ContainerCommands
import ContainerAPIClient
import Foundation

public struct ComposePort: AsyncParsableCommand, ComposeCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "port",
        abstract: "Print published ports for the running containers of this project"
    )

    @Argument(help: "Service name (optional — when omitted with --all or no extra arg, list every running service)")
    var service: String?

    @Argument(help: "Private container port (optional — when omitted, list mode is used)")
    var privatePort: Int?

    @Option(name: .long, help: "Port protocol (tcp or udp). Only meaningful when resolving a private port.")
    var `protocol`: ComposePortProtocol = .tcp

    @Flag(name: [.customShort("a"), .customLong("all")], help: "List published ports for every running service in this project.")
    var all: Bool = false

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    public mutating func run() async throws {
        // Mutual exclusion: `--all` plus a positional `<private-port>` doesn't
        // mean anything — `--all` is listing-only. Match the matrix in
        // CHAOS-1440 and fail before we touch the runtime.
        if all && privatePort != nil {
            fputs("Error: --all and <private-port> are mutually exclusive\n", stderr)
            throw ExitCode.failure
        }

        let dockerCompose = try loadAndResolve()

        // Resolver mode: <service> + <private-port> stays exactly as before.
        // This is the legacy `docker compose port` behavior — the YAML file is
        // the source of truth and the runtime is not consulted.
        if let privatePort {
            guard let serviceName = service else {
                // ArgumentParser already enforces this for the legacy form
                // because `service` is the first positional, but defend in
                // depth in case argv parsing rules ever change.
                fputs("Error: <service> is required when resolving <private-port>\n", stderr)
                throw ExitCode.failure
            }

            do {
                let publishedPort = try Self.resolvePublishedPort(
                    in: dockerCompose,
                    serviceName: serviceName,
                    privatePort: privatePort,
                    protocol: `protocol`
                )
                print(publishedPort)
            } catch {
                fputs("\(error)\n", stderr)
                throw ExitCode.failure
            }
            return
        }

        // Listing mode (CHAOS-1440): runtime is the source of truth. We still
        // load the compose file because the project name lives there, and so
        // the empty-project error message can name the project the user asked
        // about.
        let projectName = resolveProjectName(for: dockerCompose)
        let runtime = RuntimeEnvironment.current

        let serviceFilter: [String]?
        if let service {
            serviceFilter = [service]
        } else {
            serviceFilter = nil
        }

        let entries = try await ProjectListing.list(
            runtime: runtime,
            projectName: projectName,
            serviceFilter: serviceFilter,
            includeStopped: false
        )

        if entries.isEmpty {
            if let service {
                fputs("Error: \(service) is not running\n", stderr)
            } else {
                fputs("Error: no containers running for project \(projectName)\n", stderr)
            }
            throw ExitCode.failure
        }

        // Format: NAME column padded to max width, two-space gap, then PORTS.
        // PORTS is the same `host:hostPort->containerPort/proto, ...` format
        // that `ps` emits via `formatPublishedPorts`.
        let nameWidth = max(4, entries.map { $0.container.id.count }.max() ?? 4)
        let header = padded("NAME", nameWidth) + "  " + "PORTS"
        print(header)
        for entry in entries {
            let name = padded(entry.container.id, nameWidth)
            let ports = formatPublishedPorts(entry.container.publishedPorts)
            print("\(name)  \(ports)")
        }
    }

    static func resolvePublishedPort(
        in dockerCompose: DockerCompose,
        serviceName: String,
        privatePort: Int,
        protocol requestedProtocol: ComposePortProtocol = .tcp
    ) throws -> String {
        guard let configuredService = dockerCompose.services[serviceName], let service = configuredService else {
            throw ComposePortResolutionError.serviceNotFound(serviceName)
        }

        for portSpec in service.ports ?? [] {
            let runArg = composePortToRunArg(portSpec)
            guard !isBareContainerPort(portSpec), let binding = PortBinding(runArg: runArg) else { continue }
            guard binding.containerPort == privatePort, binding.protocol == requestedProtocol else { continue }
            return "\(binding.hostIP):\(binding.hostPort)"
        }

        throw ComposePortResolutionError.portNotFound(
            serviceName: serviceName,
            privatePort: privatePort,
            portProtocol: requestedProtocol.rawValue
        )
    }

    private static func isBareContainerPort(_ portSpec: String) -> Bool {
        let portBody = portSpec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return !portBody.contains(":")
    }

    // MARK: - Formatting helpers

    private func padded(_ value: String, _ width: Int) -> String {
        value.padding(toLength: max(value.count, width), withPad: " ", startingAt: 0)
    }
}

enum ComposePortProtocol: String, ExpressibleByArgument, Equatable {
    case tcp
    case udp
}

private struct PortBinding {
    let hostIP: String
    let hostPort: String
    let containerPort: Int
    let `protocol`: ComposePortProtocol

    init?(runArg: String) {
        let parts = runArg.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }

        let containerAndProtocol = parts[2].split(separator: "/", maxSplits: 1).map(String.init)
        guard let containerPort = Int(containerAndProtocol[0]) else { return nil }

        let portProtocol: ComposePortProtocol
        if containerAndProtocol.count == 2 {
            guard let parsedProtocol = ComposePortProtocol(rawValue: containerAndProtocol[1]) else { return nil }
            portProtocol = parsedProtocol
        } else {
            portProtocol = .tcp
        }

        self.hostIP = parts[0]
        self.hostPort = parts[1]
        self.containerPort = containerPort
        self.protocol = portProtocol
    }
}

private enum ComposePortResolutionError: Error, CustomStringConvertible {
    case serviceNotFound(String)
    case portNotFound(serviceName: String, privatePort: Int, portProtocol: String)

    var description: String {
        switch self {
        case .serviceNotFound(let serviceName):
            return "Error: No such service: \(serviceName)"
        case .portNotFound(let serviceName, let privatePort, let portProtocol):
            return "Error: No public port found for \(serviceName) private port \(privatePort)/\(portProtocol)"
        }
    }
}
