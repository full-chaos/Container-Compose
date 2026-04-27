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
//  ComposeRun.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import ContainerCommands
import ContainerizationExtras
import Foundation
import Yams

public struct ComposeRun: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "run",
        abstract: "Run a one-off command on a service"
    )

    @Argument(help: "The service to run a command on")
    var serviceName: String

    @Argument(parsing: .captureForPassthrough, help: "Command to run (overrides service command)")
    var command: [String] = []

    @Flag(name: [.customLong("detach")], help: "Run container in the background")
    var detach: Bool = false

    @Flag(name: [.long], help: "Remove container after exit")
    var rm: Bool = false

    @Flag(name: [.customLong("service-ports")], help: "Publish the service's ports to the host")
    var servicePorts: Bool = false

    @Option(name: [.customLong("run-env")], help: "Set an environment variable KEY=VALUE (can be repeated)")
    var environment: [String] = []

    @Option(name: [.customLong("run-volume")], help: "Bind-mount a volume (can be repeated)")
    var volumes: [String] = []

    @Option(name: [.customLong("run-user")], help: "Run as specified username or uid")
    var user: String?

    @Option(name: [.long], help: "Override the container name")
    var name: String?

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

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwdURL)
    }

    // MARK: - run()

    public mutating func run() async throws {
        // 1. Load and merge compose file
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        // 2. Load environment variables from .env file
        let environmentVariables = loadEnvFile(path: envFilePath)

        // 3. Determine project name (CLI flag > compose `name:` > directory basename).
        let projectName = resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )

        // 4. Filter by active profiles
        var allServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }
        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        allServices = Service.filterByProfiles(allServices, activeProfiles: activeProfiles)

        // 5. Find the named service
        guard let (_, service) = allServices.first(where: { $0.serviceName == serviceName }) else {
            throw ValidationError("Service '\(serviceName)' not found in compose file.")
        }

        // 6. Generate a unique one-off container name
        let containerName: String
        if let nameOverride = name {
            containerName = nameOverride
        } else {
            let uuidPrefix = String(UUID().uuidString.prefix(8).lowercased())
            containerName = "\(projectName)-\(serviceName)-run-\(uuidPrefix)"
        }

        // 7. Resolve the image to run
        let imageToRun: String
        if let img = service.image {
            try await pullImage(img, platform: service.platform, policy: service.pull_policy, logging: logging)
            imageToRun = img
        } else if service.build != nil {
            // Build-only service — use the derived image tag
            imageToRun = service.image ?? "\(serviceName):latest"
        } else {
            throw ComposeError.imageNotFound(serviceName)
        }

        // 8. Build the argv for `container run`
        var runArgs: [String] = []

        // Detach flag
        if detach {
            runArgs.append("-d")
        }

        // Remove after exit
        if rm {
            runArgs.append("--rm")
        }

        // Container name
        runArgs.append(contentsOf: ["--name", containerName])

        // Build ArgsContext for the per-concern builders
        let ctx = ComposeUp.ArgsContext(
            service: service,
            serviceName: serviceName,
            projectName: projectName,
            containerName: containerName,
            detach: detach,
            environmentVariables: environmentVariables,
            dockerCompose: dockerCompose,
            composeFilename: composeFilename
        )

        // LifecycleArgs — but we already emitted -d and --name above, so we
        // use the raw builder and skip the duplicate platform / detach / name
        // flags by calling builders individually at the concern level.
        // Instead, call the sub-concerns that LifecycleArgs embeds:
        if let platform = service.platform {
            runArgs.append(contentsOf: ["--platform", platform])
        }
        if service.stdin_open == true { runArgs.append("-i") }
        if service.tty == true { runArgs.append("-t") }
        if service.init_ == true { runArgs.append("--init") }
        if let stopSignal = service.stop_signal {
            runArgs.append(contentsOf: ["--stop-signal", stopSignal])
        }
        if let gracePeriod = service.stop_grace_period,
           let seconds = ComposeUp.LifecycleArgs.parseGoDuration(gracePeriod) {
            runArgs.append(contentsOf: ["--stop-timeout", "\(seconds)"])
        }
        if let runtime = service.runtime {
            runArgs.append(contentsOf: ["--runtime", runtime])
        }
        if let loggingConfig = service.logging {
            if let driver = loggingConfig.driver {
                runArgs.append(contentsOf: ["--log-driver", driver])
            }
            if let options = loggingConfig.options {
                for (key, value) in options.sorted(by: { $0.key < $1.key }) {
                    runArgs.append(contentsOf: ["--log-opt", "\(key)=\(value)"])
                }
            }
        }

        runArgs.append(contentsOf: ComposeUp.SecurityArgs.build(ctx))
        runArgs.append(contentsOf: ComposeUp.ResourceArgs.build(ctx))

        // Networking: only emit ports if --service-ports is set
        if servicePorts {
            runArgs.append(contentsOf: ComposeUp.NetworkingArgs.build(ctx))
        } else {
            // Emit everything from NetworkingArgs except the -p port bindings
            let networkArgs = ComposeUp.NetworkingArgs.build(ctx)
            // Filter out pairs of ["-p", "<value>"] from the args
            var filteredNetworkArgs: [String] = []
            var skipNext = false
            for arg in networkArgs {
                if skipNext {
                    skipNext = false
                    continue
                }
                if arg == "-p" {
                    skipNext = true
                    continue
                }
                filteredNetworkArgs.append(arg)
            }
            runArgs.append(contentsOf: filteredNetworkArgs)
        }

        runArgs.append(contentsOf: ComposeUp.StorageArgs.build(ctx))
        runArgs.append(contentsOf: ComposeUp.LabelsArgs.build(ctx))

        // Combined env: .env file + service env
        var combinedEnv = environmentVariables
        if let envFiles = service.env_file {
            for envFile in envFiles {
                let additionalEnvVars = loadEnvFile(
                    path: URL(fileURLWithPath: envFile, relativeTo: URL(fileURLWithPath: effectiveProjectDirectory)).path
                )
                combinedEnv.merge(additionalEnvVars) { current, _ in current }
            }
        }
        if let serviceEnv = service.environment {
            combinedEnv.merge(serviceEnv) { old, new in
                guard !new.contains("${") else { return old }
                return new
            }
        }
        combinedEnv = combinedEnv.mapValues { value in
            guard value.contains("${") else { return value }
            let varName = String(value.replacingOccurrences(of: "${", with: "").dropLast())
            return combinedEnv[varName] ?? value
        }
        for (key, value) in combinedEnv {
            runArgs.append(contentsOf: ["-e", "\(key)=\(value)"])
        }

        // Extra -e / --env flags from CLI
        for envVar in environment {
            runArgs.append(contentsOf: ["-e", envVar])
        }

        // Extra -v / --volume flags from CLI
        for vol in volumes {
            runArgs.append(contentsOf: ["-v", vol])
        }

        // User override from CLI
        if let userOverride = user {
            runArgs.append(contentsOf: ["--user", userOverride])
        } else if let serviceUser = service.user {
            runArgs.append(contentsOf: ["--user", serviceUser])
        }

        // Image
        runArgs.append(imageToRun)

        // 9. Command override (overrides service.command)
        if !command.isEmpty {
            runArgs.append(contentsOf: command)
        } else if let entrypointParts = service.entrypoint {
            runArgs.append("--entrypoint")
            runArgs.append(contentsOf: entrypointParts)
        } else if let commandParts = service.command {
            runArgs.append(contentsOf: commandParts)
        }

        // 10. Shell out
        print("Running one-off container '\(containerName)' from service '\(serviceName)'")
        print("Executing: container run \(runArgs.joined(separator: " "))")

        let _ = try await streamCommand("container", args: ["run"] + runArgs, cwd: cwd)
    }

    // MARK: - Pull image helper

    private func pullImage(_ imageName: String, platform: String?, policy: String? = nil, logging: Flags.Logging) async throws {
        let effectivePolicy: String
        switch policy?.lowercased() {
        case nil, "missing", "if_not_present":
            effectivePolicy = "missing"
        case "always":
            effectivePolicy = "always"
        case "never":
            effectivePolicy = "never"
        case "build":
            effectivePolicy = "build"
        default:
            effectivePolicy = "missing"
        }

        let imageList = try await ClientImage.list()
        let imageExists = imageList.contains(where: {
            $0.description.reference.components(separatedBy: "/").last == imageName
        })

        switch effectivePolicy {
        case "never", "build":
            guard imageExists else {
                throw ComposeError.imageNotFound(imageName)
            }
            return
        case "always":
            break
        default:
            guard !imageExists else { return }
        }

        print("Pulling Image \(imageName)...")

        var commands = [imageName]
        if let platform {
            commands.append(contentsOf: ["--platform", platform])
        }

        let imagePull = try Application.ImagePull.parse(commands + logging.passThroughCommands())
        try await imagePull.run()
    }

    // MARK: - Stream command helper

    @discardableResult
    private func streamCommand(_ command: String, args: [String] = [], cwd: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [command] + args
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
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
