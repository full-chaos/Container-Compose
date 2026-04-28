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
//  ComposeCreate.swift
//  Container-Compose
//

import ArgumentParser
import ContainerCommands
import ContainerAPIClient
import ContainerizationExtras
import Foundation
@preconcurrency import Rainbow
import Yams

/// Provisions containers (pull/build images, create networks/volumes, create containers)
/// without starting them. Mirrors `compose up` but replaces `container run` with
/// `container create`. If Apple `container` does not support the `create` sub-command
/// a warning is printed and no containers are created.
public struct ComposeCreate: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "create",
        abstract: "Create containers without starting them"
    )

    @Argument(help: "Specify the services to create")
    var services: [String] = []

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @Flag(name: [.customShort("b"), .customLong("build")], help: "Build images before creating containers")
    var rebuild: Bool = false

    @Flag(name: .long, help: "Do not use cache when building")
    var noCache: Bool = false

    @Flag(name: .long, help: "Always pull the image before creating the container")
    var pull: Bool = false

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

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwdURL)
    }

    /// Project root for outside-container relative-path resolution. Honors
    /// `--project-directory`, falls back to the compose file's directory.
    private var effectiveProjectDirectory: String {
        resolveProjectDirectory(
            cliOverride: projectFlags.projectDirectory,
            composeFilePath: composePath,
            cwd: cwd
        )
    }

    private var fileManager: FileManager { FileManager.default }
    var projectName: String?
    private var environmentVariables: [String: String] = [:]

    public mutating func run() async throws {
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        environmentVariables = loadEnvFile(path: envFilePath)

        if let version = dockerCompose.version {
            print("Info: Docker Compose file version: \(version)")
        }

        // Precedence: --project-name CLI flag > compose file `name:` > directory basename.
        let resolvedName = resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )
        projectName = resolvedName
        if let cliName = projectFlags.projectName, !cliName.isEmpty {
            print("Info: Using project name from --project-name flag: \(cliName)")
        } else if dockerCompose.name != nil {
            print("Info: Docker Compose project name: \(resolvedName)")
        } else {
            print("Info: Using directory name as project name: \(resolvedName)")
        }

        var resolvedServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        resolvedServices = Service.filterByProfiles(resolvedServices, activeProfiles: activeProfiles)

        resolvedServices = try Service.topoSortConfiguredServices(resolvedServices)

        if !self.services.isEmpty {
            resolvedServices = resolvedServices.filter { serviceName, service in
                self.services.contains(serviceName) || self.services.contains(where: { service.dependedBy.contains($0) })
            }
        }

        // Process top-level networks
        if let networks = dockerCompose.networks {
            print("\n--- Processing Networks ---")
            for (networkName, networkConfig) in networks {
                try await setupNetwork(name: networkName, config: networkConfig)
            }
            print("--- Networks Processed ---\n")
        }

        // Process top-level volumes
        if let volumes = dockerCompose.volumes {
            print("\n--- Processing Volumes ---")
            for (volumeName, volumeConfig) in volumes {
                guard let volumeConfig else { continue }
                await createVolumeHardLink(name: volumeName, config: volumeConfig)
            }
            print("--- Volumes Processed ---\n")
        }

        // Provision each service
        print("\n--- Creating Containers ---")
        for (serviceName, service) in resolvedServices {
            try await createService(service, serviceName: serviceName, from: dockerCompose)
        }
        print("--- Containers Created ---\n")
    }

    // MARK: - Image provisioning

    private func pullImage(_ imageName: String, platform: String?, policy: String? = nil) async throws {
        let effectivePolicy: String
        if pull {
            effectivePolicy = "always"
        } else {
            switch policy?.lowercased() {
            case nil, "missing", "if_not_present":
                effectivePolicy = "missing"
            case "always":
                effectivePolicy = "always"
            case "never", "build":
                effectivePolicy = "never"
            default:
                effectivePolicy = "missing"
            }
        }

        let imageList = try await ContainerClientEnvironment.current.imageList()
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

        print("Pulling image \(imageName)...")
        var commands = [imageName]
        if let platform {
            commands.append(contentsOf: ["--platform", platform])
        }
        let imagePullArgv = commands + logging.passThroughCommands()
        _ = try await RunnerEnvironment.current.run(
            RunRequest(kind: .swiftAPI(name: "ImagePull"), argv: imagePullArgv, cwd: nil),
            onStdout: nil,
            onStderr: nil
        )
    }

    private func buildService(_ buildConfig: Build, for service: Service, serviceName: String) async throws -> String {
        var inlineTempURL: URL? = nil
        defer { inlineTempURL.flatMap { try? FileManager.default.removeItem(at: $0) } }

        let imageToRun = service.image ?? "\(serviceName):latest"
        let imageList = try await ContainerClientEnvironment.current.imageList()
        if !rebuild, imageList.contains(where: { $0.description.reference.components(separatedBy: "/").last == imageToRun }) {
            return imageToRun
        }

        var commands = [URL(fileURLWithPath: buildConfig.context, relativeTo: URL(fileURLWithPath: effectiveProjectDirectory)).path]

        for (key, value) in buildConfig.args ?? [:] {
            commands.append(contentsOf: ["--build-arg", "\(key)=\(resolveVariable(value, with: environmentVariables))"])
        }

        if let inlineContent = buildConfig.dockerfile_inline {
            if buildConfig.dockerfile != nil {
                print("Warning: Both 'dockerfile' and 'dockerfile_inline' are set for service '\(serviceName)'. 'dockerfile_inline' takes priority.")
            }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".Dockerfile")
            try inlineContent.write(to: tempURL, atomically: true, encoding: .utf8)
            inlineTempURL = tempURL
            commands.append(contentsOf: ["--file", tempURL.path])
        } else {
            commands.append(contentsOf: ["--file", URL(fileURLWithPath: buildConfig.dockerfile ?? "Dockerfile", relativeTo: URL(fileURLWithPath: effectiveProjectDirectory)).path])
        }

        if noCache {
            commands.append("--no-cache")
        }

        if let target = buildConfig.target {
            commands.append(contentsOf: ["--target", target])
        }

        for ref in buildConfig.cache_from ?? [] {
            commands.append(contentsOf: ["--cache-from", ref])
        }
        for ref in buildConfig.cache_to ?? [] {
            commands.append(contentsOf: ["--cache-to", ref])
        }
        for (key, value) in buildConfig.labels ?? [:] {
            commands.append(contentsOf: ["--label", "\(key)=\(value)"])
        }
        if let network = buildConfig.network {
            commands.append(contentsOf: ["--network", network])
        }
        for secretId in buildConfig.secrets ?? [] {
            commands.append(contentsOf: ["--secret", "id=\(secretId)"])
        }
        for sshKey in buildConfig.ssh ?? [] {
            commands.append(contentsOf: ["--ssh", sshKey])
        }

        if let buildPlatforms = buildConfig.platforms, !buildPlatforms.isEmpty {
            if buildPlatforms.count > 1 {
                print("Warning: Service '\(serviceName)' declares \(buildPlatforms.count) build platforms. Only the first will be used.")
            }
            let split = buildPlatforms[0].split(separator: "/")
            let os = String(split.first ?? "linux")
            let arch = String(split.count >= 2 ? split.last! : "arm64")
            commands.append(contentsOf: ["--os", os, "--arch", arch])
        } else {
            let split = service.platform?.split(separator: "/")
            let os = String(split?.first ?? "linux")
            let arch = String(((split ?? []).count >= 1 ? split?.last : nil) ?? "arm64")
            commands.append(contentsOf: ["--os", os, "--arch", arch])
        }

        if let shmSize = buildConfig.shm_size {
            commands.append(contentsOf: ["--shm-size", shmSize])
        }

        commands.append(contentsOf: ["--tag", imageToRun])

        let cpuCount = Int64(service.deploy?.resources?.limits?.cpus ?? "2") ?? 2
        let memoryLimit = service.deploy?.resources?.limits?.memory ?? "2048MB"
        commands.append(contentsOf: ["--cpus", "\(cpuCount)", "--memory", memoryLimit])

        let buildArgv = commands + logging.passThroughCommands()
        print("\n----------------------------------------")
        print("Building image for service: \(serviceName) (Tag: \(imageToRun))")
        _ = try await RunnerEnvironment.current.run(
            RunRequest(kind: .swiftAPI(name: "BuildCommand"), argv: buildArgv, cwd: nil),
            onStdout: nil,
            onStderr: nil
        )
        print("Image build for \(serviceName) completed.")
        print("----------------------------------------")

        return imageToRun
    }

    // MARK: - Network / Volume helpers (mirrors ComposeUp)

    private func createVolumeHardLink(name volumeName: String, config volumeConfig: Volume) async {
        guard let projectName else { return }
        let actualVolumeName = volumeConfig.name ?? volumeName
        let volumeUrl = URL.homeDirectory.appending(path: ".containers/Volumes/\(projectName)/\(actualVolumeName)")
        let volumePath = volumeUrl.path(percentEncoded: false)
        print("Warning: Volume '\(actualVolumeName)' is a named volume. Linking to \(volumePath).")
        try? fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true)
    }

    private func setupNetwork(name networkName: String, config networkConfig: Network?) async throws {
        let actualNetworkName = networkConfig?.name ?? networkName

        if let externalNetwork = networkConfig?.external, externalNetwork.isExternal {
            print("Info: Network '\(networkName)' is declared as external, skipping creation.")
            return
        }

        var networkCreateArgs: [String] = ["network", "create"]

        if let labels = networkConfig?.labels, !labels.isEmpty {
            for (labelKey, labelValue) in labels.sorted(by: { $0.key < $1.key }) {
                networkCreateArgs.append(contentsOf: ["--label", "\(labelKey)=\(labelValue)"])
            }
        }

        print("Creating network: \(networkName) (actual: \(actualNetworkName))")
        guard (try? await ContainerClientEnvironment.current.networkGet(id: actualNetworkName)) == nil else {
            print("Network '\(networkName)' already exists")
            return
        }

        let networkCreateArgv = [actualNetworkName] + logging.passThroughCommands()
        _ = try await RunnerEnvironment.current.run(
            RunRequest(kind: .swiftAPI(name: "NetworkCreate"), argv: networkCreateArgv, cwd: nil),
            onStdout: nil,
            onStderr: nil
        )
        print("Network '\(networkName)' created")
    }

    // MARK: - Service creation

    private mutating func createService(_ service: Service, serviceName: String, from dockerCompose: DockerCompose) async throws {
        guard let projectName else { throw ComposeError.invalidProjectName }

        var imageToRun: String

        if let buildConfig = service.build {
            imageToRun = try await buildService(buildConfig, for: service, serviceName: serviceName)
        } else if let img = service.image {
            try await pullImage(img, platform: service.platform, policy: service.pull_policy)
            imageToRun = img
        } else {
            throw ComposeError.imageNotFound(serviceName)
        }

        let containerName: String
        if let explicitName = service.container_name {
            containerName = explicitName
            print("Info: Using explicit container_name: \(containerName)")
        } else {
            containerName = "\(projectName)-\(serviceName)"
        }

        var createArgs: [String] = []

        // Volume mounts
        if let volumes = service.volumes {
            for volume in volumes {
                let args = try await configVolume(volume)
                createArgs.append(contentsOf: args)
            }
        }

        // Environment variables
        var combinedEnv: [String: String] = environmentVariables

        if let envFiles = service.env_file {
            for envFile in envFiles {
                let additionalEnvVars = loadEnvFile(path: URL(fileURLWithPath: envFile, relativeTo: URL(fileURLWithPath: effectiveProjectDirectory)).path)
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
            let variableName = String(value.replacingOccurrences(of: "${", with: "").dropLast())
            return combinedEnv[variableName] ?? value
        }

        for (key, value) in combinedEnv {
            createArgs.append(contentsOf: ["-e", "\(key)=\(value)"])
        }

        // Reuse the per-concern arg builders from ComposeUp
        let ctx = ComposeUp.ArgsContext(
            service: service,
            serviceName: serviceName,
            projectName: projectName,
            containerName: containerName,
            detach: false,
            environmentVariables: environmentVariables,
            dockerCompose: dockerCompose,
            composeFilename: composeFilename
        )
        createArgs.append(contentsOf: ComposeUp.LifecycleArgs.build(ctx))
        createArgs.append(contentsOf: ComposeUp.SecurityArgs.build(ctx))
        createArgs.append(contentsOf: ComposeUp.ResourceArgs.build(ctx))
        createArgs.append(contentsOf: ComposeUp.NetworkingArgs.build(ctx))
        createArgs.append(contentsOf: ComposeUp.StorageArgs.build(ctx))
        createArgs.append(contentsOf: ComposeUp.LabelsArgs.build(ctx))

        // Emit `--entrypoint <first>` (a pre-image flag) + image + remaining
        // entrypoint args + command, so the runtime parses entrypoint/command
        // exactly as the compose spec requires. See `imageAndEntrypointTail`.
        // Fix for `docs/plans/PLAN.md` §1 at the `compose create` site (PR-4
        // of the recorder seam migration; the previous 9-line block placed
        // `--entrypoint` *after* the image, which the runtime then misparsed
        // as the in-container command).
        createArgs.append(contentsOf: Self.imageAndEntrypointTail(
            image: imageToRun,
            entrypoint: service.entrypoint,
            command: service.command
        ))

        // Capability probe: Apple `container` did not always expose the
        // `create` sub-command. Route the probe through the runner seam so
        // tests can stub the answer (PR-4 of the recorder migration; see
        // docs/plans/PLAN-recorder-seam.md §7).
        let probeRequest = RunRequest(
            kind: .probe,
            argv: ["container", "create", "--help"],
            cwd: nil
        )
        let probeResult: RunResult
        do {
            probeResult = try await RunnerEnvironment.current.run(
                probeRequest,
                onStdout: nil,
                onStderr: nil
            )
        } catch {
            print("Warning: Apple container doesn't support 'create'; please use 'compose up' instead.")
            return
        }
        guard probeResult.probeAvailable else {
            print("Warning: Apple container doesn't support 'create'; please use 'compose up' instead.")
            return
        }

        print("\nCreating container (without starting): \(containerName)")

        // Route through the RunCommandRunner seam (PR-4 of the recorder
        // migration; see docs/plans/PLAN-recorder-seam.md §7 / §9 PR-4).
        // The previous `shellCreate` helper was deleted; `ProductionRunner`
        // preserves the same `Process()` semantics byte-for-byte.
        let createArgv = ["container", "create", "--name", containerName] + createArgs
        let request = RunRequest(kind: .awaitOnly, argv: createArgv, cwd: cwd)
        do {
            let result = try await RunnerEnvironment.current.run(
                request,
                onStdout: nil,
                onStderr: nil
            )
            guard result.exitCode == 0 else {
                throw NSError(
                    domain: "ComposeCreate",
                    code: Int(result.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: "container create exited with status \(result.exitCode)"]
                )
            }
            print("Successfully created container: \(containerName)")
        } catch {
            // If `container create` is not supported by Apple container, surface a helpful message.
            print("Warning: Failed to create container '\(containerName)': \(error)")
            print("Note: Apple's 'container' CLI may not support the 'create' subcommand. Use 'compose up' to start containers directly.")
        }
    }

    // MARK: - Volume helper (mirrors ComposeUp.configVolume)

    private func configVolume(_ volume: String) async throws -> [String] {
        let resolvedVolume = resolveVariable(volume, with: environmentVariables)
        var runCommandArgs: [String] = []

        let components = resolvedVolume.split(separator: ":", maxSplits: 2).map(String.init)
        guard components.count >= 2 else {
            print("Warning: Volume entry '\(resolvedVolume)' has invalid format. Skipping.")
            return []
        }

        let source = components[0]
        let destination = components[1]

        if source.contains("/") || source.starts(with: ".") || source.starts(with: "..") {
            var isDirectory: ObjCBool = false
            let fullHostPath = (source.starts(with: "/") || source.starts(with: "~")) ? source : (cwd + "/" + source)

            if fileManager.fileExists(atPath: fullHostPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    runCommandArgs.append(contentsOf: ["-v", "\(source):\(destination)"])
                } else {
                    print("Warning: Volume mount source '\(source)' is a file. Skipping.")
                }
            } else {
                do {
                    try fileManager.createDirectory(atPath: fullHostPath, withIntermediateDirectories: true, attributes: nil)
                    print("Info: Created missing host directory for volume: \(fullHostPath)")
                    runCommandArgs.append(contentsOf: ["-v", "\(source):\(destination)"])
                } catch {
                    print("Error: Could not create host directory '\(fullHostPath)': \(error.localizedDescription). Skipping.")
                }
            }
        } else {
            guard let projectName else { return [] }
            let volumeUrl = URL.homeDirectory.appending(path: ".containers/Volumes/\(projectName)/\(source)")
            let volumePath = volumeUrl.path(percentEncoded: false)
            let destinationUrl = URL(fileURLWithPath: destination).deletingLastPathComponent()
            let destinationPath = destinationUrl.path(percentEncoded: false)

            print("Warning: Volume source '\(source)' is a named volume. Linking to \(volumePath).")
            try fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true)
            runCommandArgs.append(contentsOf: ["-v", "\(volumePath):\(destinationPath)"])
        }

        return runCommandArgs
    }
}

// MARK: Argv tail (image + entrypoint/command)

extension ComposeCreate {

    /// Builds the trailing portion of a `container create` argv: the
    /// `--entrypoint` flag (if any), the image, and any positional args.
    ///
    /// `container create` (like `container run` and `docker run` / `docker
    /// create`) accepts at most one `--entrypoint <BIN>` flag *before* the
    /// image, with any extra arguments to that entrypoint passed positionally
    /// *after* the image. Compose models `entrypoint` as `[a, b, c]` — a full
    /// argv. We therefore split: the first token becomes the `--entrypoint`
    /// value (pre-image), the remaining tokens become positional args
    /// (post-image), followed by `command` if any.
    ///
    /// `compose create` has no per-call CLI command override (unlike
    /// `compose run`), so the signature mirrors `ComposeUp.imageAndEntrypointTail`
    /// exactly. Kept as a parallel ComposeCreate-local helper rather than
    /// reusing `ComposeUp.imageAndEntrypointTail` to keep each command's argv
    /// logic readable in isolation and to avoid cross-file coupling — the
    /// PR-3 ComposeRun helper made the same call.
    ///
    /// Resulting shapes:
    /// - `entrypoint: [a, b, c]`, `command: [d, e]` → `[--entrypoint, a, <image>, b, c, d, e]`
    /// - `entrypoint: [/app/foo.sh]`, no command   → `[--entrypoint, /app/foo.sh, <image>]`
    /// - no entrypoint, `command: [d, e]`          → `[<image>, d, e]`
    /// - neither                                    → `[<image>]`
    static func imageAndEntrypointTail(
        image: String,
        entrypoint: [String]?,
        command: [String]?
    ) -> [String] {
        var tail: [String] = []
        var positional: [String] = []

        if let entrypoint, let first = entrypoint.first {
            tail.append("--entrypoint")
            tail.append(first)
            // Remaining entrypoint tokens are positional args to the entrypoint
            // and must appear *after* the image.
            positional.append(contentsOf: entrypoint.dropFirst())
        }

        tail.append(image)
        tail.append(contentsOf: positional)

        // `command` is appended after entrypoint args per the compose spec.
        if let command {
            tail.append(contentsOf: command)
        }

        return tail
    }
}

// PR-4 of the recorder migration removed the
// `private func shellCreate(...)` and `private func checkCreateSupported()`
// helpers that previously lived here. The `compose create` await-only
// shell-out and the `container create --help` capability probe now flow
// through `RunnerEnvironment.current.run(_:onStdout:onStderr:)` (see the
// call site in `createService` above). `ProductionRunner` in
// `Sources/Container-Compose/Runtime/RunCommandRunner.swift` preserves the
// previous `Process()` semantics — including the `/dev/null`-ed stdio for
// the probe and inherit-stdio for the await-only call — byte-for-byte. See
// `docs/plans/PLAN-recorder-seam.md` §7 / §10 Q4 / §11 and
// `docs/plans/PLAN.md` §1 (third and final entrypoint-bug site closed).
