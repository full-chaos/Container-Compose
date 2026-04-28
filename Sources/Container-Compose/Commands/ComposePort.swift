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

public struct ComposePort: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "port",
        abstract: "Print the public port for a service's private port"
    )

    @Argument(help: "Service name")
    var service: String

    @Argument(help: "Private container port")
    var privatePort: Int

    @Option(name: .long, help: "Port protocol (tcp or udp)")
    var `protocol`: ComposePortProtocol = .tcp

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

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
        let dockerCompose = try DockerCompose.loadAndMerge(mainPath: composePath).resolvingExtends()

        do {
            let publishedPort = try Self.resolvePublishedPort(
                in: dockerCompose,
                serviceName: service,
                privatePort: privatePort,
                protocol: `protocol`
            )
            print(publishedPort)
        } catch {
            fputs("\(error)\n", stderr)
            throw ExitCode.failure
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
