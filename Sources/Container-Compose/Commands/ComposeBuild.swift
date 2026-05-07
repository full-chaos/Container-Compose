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
//  ComposeBuild.swift
//  Container-Compose
//
//  Created by Luke Parkin on 04/20/26.
//

import ArgumentParser
import ContainerCommands
import ContainerAPIClient
import ContainerizationExtras
import Foundation
import Yams

public struct ComposeBuild: AsyncParsableCommand, ComposeCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "build",
        abstract: "Build images from a compose file without starting containers"
    )

    @Argument(help: "Services to build (builds all if omitted)")
    var services: [String] = []

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Flag(name: .long, help: "Do not use cache when building")
    var noCache: Bool = false

    @Flag(name: .long, help: "Show extra detail on the empty-output message when no services need building")
    var verbose: Bool = false

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwd)
    }

    /// Lines printed when the build invocation has no services to build.
    /// Default is the terse single-line message; `--verbose` appends a
    /// second line clarifying that all candidate services already use
    /// pre-built images.
    static func emptyBuildOutputLines(verbose: Bool, totalServiceCount: Int) -> [String] {
        var lines = ["No services with a 'build' configuration found."]
        if verbose {
            lines.append("All \(totalServiceCount) service(s) use pre-built images. Nothing to build.")
        }
        return lines
    }

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()

        if RuntimeExecutionMode.isRemote {
            let projectName = resolveProjectName(for: dockerCompose)
            try await remoteBuild(projectName: projectName)
            return
        }

        let environmentVariables = loadEnvFile(path: envFilePath)

        let projectName = resolveProjectName(for: dockerCompose)

        // Build the candidate list first (every service visible to this invocation),
        // then narrow down to those with a `build:` block. The candidate count is
        // the denominator we report in the verbose empty-output message.
        var candidateServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        // Filter by active profiles before applying CLI service filter.
        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        candidateServices = Service.filterByProfiles(candidateServices, activeProfiles: activeProfiles)

        if !services.isEmpty {
            candidateServices = candidateServices.filter { services.contains($0.serviceName) }
        }

        let servicesToBuild = candidateServices.filter { $0.service.build != nil }

        if servicesToBuild.isEmpty {
            for line in Self.emptyBuildOutputLines(verbose: verbose, totalServiceCount: candidateServices.count) {
                print(line)
            }
            return
        }

        print("Building services")
        for (serviceName, service) in servicesToBuild {
            _ = try await buildService(
                service.build!,
                for: service,
                serviceName: serviceName,
                environmentVariables: environmentVariables,
                rebuild: true,
                noCache: noCache,
                passThroughCommands: logging.passThroughCommands()
            )
        }
        print("Build complete")
    }

    private func remoteBuild(projectName: String) async throws {
        guard let remoteRuntime = RuntimeEnvironment.current as? RemoteRuntime else {
            throw RuntimeError.notSupported(operation: "compose build", conformer: "RemoteRuntime")
        }

        let stream = try await remoteRuntime.buildProject(
            name: projectName,
            services: services,
            noCache: noCache,
            pull: false
        )

        var unsupportedMessages: [String] = []
        var errorMessages: [String] = []
        for await frame in stream {
            print("[\(frame.service)] \(frame.line)")
            if frame.type == "notSupported" {
                unsupportedMessages.append(frame.line)
            } else if frame.type == "error" {
                errorMessages.append(frame.line)
            }
        }

        if let first = unsupportedMessages.first {
            throw RuntimeError.notSupported(operation: "compose build: \(first)", conformer: "RemoteRuntime")
        }
        if let first = errorMessages.first {
            throw RuntimeError.backendFailure(message: first)
        }
    }

}
