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

public struct ComposeBuild: AsyncParsableCommand, @unchecked Sendable {
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

    /// Project root for outside-container relative-path resolution
    /// (build context, env-file, volume bind sources). Honors
    /// `--project-directory`, falls back to the compose file's directory.
    private var effectiveProjectDirectory: String {
        resolveProjectDirectory(
            cliOverride: projectFlags.projectDirectory,
            composeFilePath: composePath,
            cwd: cwd
        )
    }

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwdURL)
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
        // Decode (and recursively merge includes) into the DockerCompose struct.
        let dockerCompose = try DockerCompose.loadAndMerge(mainPath: composePath)
        let environmentVariables = loadEnvFile(path: envFilePath)

        let projectName = resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )

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
            try await buildService(service.build!, for: service, serviceName: serviceName, projectName: projectName, environmentVariables: environmentVariables)
        }
        print("Build complete")
    }

    private func buildService(
        _ buildConfig: Build,
        for service: Service,
        serviceName: String,
        projectName: String,
        environmentVariables: [String: String]
    ) async throws {
        // Temp file for dockerfile_inline (cleaned up via defer).
        var inlineTempURL: URL? = nil
        defer { inlineTempURL.flatMap { try? FileManager.default.removeItem(at: $0) } }

        let imageTag = service.image ?? "\(serviceName):latest"

        var commands = [URL(fileURLWithPath: buildConfig.context, relativeTo: URL(fileURLWithPath: effectiveProjectDirectory)).path]

        for (key, value) in buildConfig.args ?? [:] {
            commands.append(contentsOf: ["--build-arg", "\(key)=\(resolveVariable(value, with: environmentVariables))"])
        }

        // Add Dockerfile path — dockerfile_inline wins over dockerfile when both are set.
        if let inlineContent = buildConfig.dockerfile_inline {
            if buildConfig.dockerfile != nil {
                print("Warning: Both 'dockerfile' and 'dockerfile_inline' are set for service '\(serviceName)'. 'dockerfile_inline' takes priority.")
            }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".Dockerfile")
            try inlineContent.write(to: tempURL, atomically: true, encoding: .utf8)
            inlineTempURL = tempURL
            commands.append(contentsOf: ["--file", tempURL.path])
        } else {
            commands.append(contentsOf: [
                "--file", URL(fileURLWithPath: buildConfig.dockerfile ?? "Dockerfile", relativeTo: URL(fileURLWithPath: effectiveProjectDirectory)).path,
            ])
        }

        commands.append(contentsOf: ["--tag", imageTag])

        if noCache {
            commands.append("--no-cache")
        }

        // Add build target stage
        if let target = buildConfig.target {
            commands.append(contentsOf: ["--target", target])
        }

        // Add cache-from references
        for ref in buildConfig.cache_from ?? [] {
            commands.append(contentsOf: ["--cache-from", ref])
        }

        // Add cache-to references
        for ref in buildConfig.cache_to ?? [] {
            commands.append(contentsOf: ["--cache-to", ref])
        }

        // Add labels
        for (key, value) in buildConfig.labels ?? [:] {
            commands.append(contentsOf: ["--label", "\(key)=\(value)"])
        }

        // Add network mode
        if let network = buildConfig.network {
            commands.append(contentsOf: ["--network", network])
        }

        // Add secrets
        for secretId in buildConfig.secrets ?? [] {
            commands.append(contentsOf: ["--secret", "id=\(secretId)"])
        }

        // Add SSH agent/key mappings
        for sshKey in buildConfig.ssh ?? [] {
            commands.append(contentsOf: ["--ssh", sshKey])
        }

        // Add platform — build.platforms overrides service.platform; only first is used.
        if let buildPlatforms = buildConfig.platforms, !buildPlatforms.isEmpty {
            if buildPlatforms.count > 1 {
                print("Warning: Service '\(serviceName)' declares \(buildPlatforms.count) build platforms. Only the first ('\(buildPlatforms[0])') will be used.")
            }
            let firstPlatform = buildPlatforms[0]
            let split = firstPlatform.split(separator: "/")
            let os = String(split.first ?? "linux")
            let arch = String(split.count >= 2 ? split.last! : "arm64")
            commands.append(contentsOf: ["--os", os, "--arch", arch])
        } else {
            let split = service.platform?.split(separator: "/")
            let os = String(split?.first ?? "linux")
            let arch = String(((split ?? []).count >= 1 ? split?.last : nil) ?? "arm64")
            commands.append(contentsOf: ["--os", os, "--arch", arch])
        }

        // Add shm-size
        if let shmSize = buildConfig.shm_size {
            commands.append(contentsOf: ["--shm-size", shmSize])
        }

        let cpuCount = Int64(service.deploy?.resources?.limits?.cpus ?? "2") ?? 2
        let memoryLimit = service.deploy?.resources?.limits?.memory ?? "2048MB"
        commands.append(contentsOf: ["--cpus", "\(cpuCount)", "--memory", memoryLimit])

        print("\n----------------------------------------")
        print("Building \(serviceName) -> \(imageTag)")
        let buildArgv = commands + logging.passThroughCommands()
        _ = try await RunnerEnvironment.current.run(
            RunRequest(kind: .swiftAPI(name: "BuildCommand"), argv: buildArgv, cwd: nil),
            onStdout: nil,
            onStderr: nil
        )
        print("Built \(serviceName) successfully.")
        print("----------------------------------------")
    }
}
