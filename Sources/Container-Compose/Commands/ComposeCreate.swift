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
import SystemPackage
@preconcurrency import Rainbow
import Yams

// CHAOS-1446 Phase 3: ComposeCreate's DAG-ordered create phase captures the
// resolved `DockerCompose` value into per-service @Sendable child task
// closures so each service's `createService(...)` call sees the same
// model. DockerCompose is a value-type Codable container with all-immutable
// stored properties; @unchecked Sendable is the smallest correct expression
// of that invariant (Swift 6 strict-concurrency cannot synthesize plain
// Sendable for Codable structs without explicit declaration). Mirrors the
// same conformance pattern Phase 2 added for Service / Build in
// Compose+BuildService.swift.
extension DockerCompose: @unchecked Sendable {}

/// Provisions containers (pull/build images, create networks/volumes, create containers)
/// without starting them. Mirrors `compose up` but replaces `container run` with
/// `container create`. If Apple `container` does not support the `create` sub-command
/// a warning is printed and no containers are created.
public struct ComposeCreate: AsyncParsableCommand, ComposeCommand, @unchecked Sendable {
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

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwd)
    }

    private var fileManager: FileManager { FileManager.default }
    var projectName: String?
    private var environmentVariables: [String: String] = [:]

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()

        // Validate the compose file for semantic correctness before any side
        // effects (network/volume creation, container provisioning) are attempted.
        try dockerCompose.validate()

        environmentVariables = loadEnvFile(path: envFilePath)

        if let version = dockerCompose.version {
            print("Info: Docker Compose file version: \(version)")
        }

        let resolvedName = resolveProjectName(for: dockerCompose)
        projectName = resolvedName
        let resolvedServices = try filterServices(
            dockerCompose,
            profilesArg: profile,
            servicesArg: services
        )

        if RuntimeExecutionMode.isRemote {
            try await remoteCreate(resolvedServices)
            return
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

        // CHAOS-1446 Phase 3: provision in two phases.
        //
        // Phase A — PARALLEL image preparation. Pull or build every service's
        // image up-front via `runBoundedThrowingFanOut` (same pattern as
        // Phase 2's compose pull/build). When the DAG-ordered create phase
        // runs next, each service's `pullImage`/`buildService` call inside
        // `createService` short-circuits because the image is already
        // present. Bounded by the shared `--parallel` flag (default 16).
        //
        // Phase B — DAG-ordered `container create`. Each service waits for
        // every dependency to publish `.created` via DependencyCoordinator
        // before issuing its own create. Honors `depends_on` for downstream
        // tooling that expects dep ordering even at create time. ComposeCreate
        // is `@unchecked Sendable` so capturing `self` by value (`createCtx`)
        // is permitted under the @Sendable closure boundary.
        let parallelLimit = try ParallelLimitResolver.resolved(cli: projectFlags.parallel)
        let createCtx = self
        let envSnapshot = environmentVariables
        let rebuildSnapshot = rebuild
        let noCacheSnapshot = noCache
        let pullSnapshot = pull
        let loggingArgs = logging.passThroughCommands()

        print("\n--- Preparing Images ---")
        let imagePrepItems = resolvedServices.map { (key: $0.serviceName, value: $0.service) }
        _ = try await runBoundedThrowingFanOut(items: imagePrepItems, limit: parallelLimit) { name, service in
            if let buildConfig = service.build {
                _ = try await createCtx.buildService(
                    buildConfig,
                    for: service,
                    serviceName: name,
                    environmentVariables: envSnapshot,
                    rebuild: rebuildSnapshot,
                    noCache: noCacheSnapshot,
                    passThroughCommands: loggingArgs
                )
            } else if let img = service.image {
                let qualifiedImage = ComposeUp.qualifyImageReference(img)
                let effectivePolicy = pullSnapshot ? "always" : service.pull_policy
                try await pullImage(
                    image: qualifiedImage,
                    policy: effectivePolicy,
                    platform: service.platform,
                    loggingArguments: loggingArgs
                )
            }
            // Service has neither `image` nor `build`: createService below
            // throws ComposeError.imageNotFound. Skip image prep here.
        }
        print("--- Images Prepared ---\n")

        print("\n--- Creating Containers ---")
        let coord = DependencyCoordinator()
        let forwardGraph = buildForwardDependencyGraph(services: resolvedServices)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (serviceName, service) in resolvedServices {
                group.addTask {
                    for dep in forwardGraph[serviceName] ?? [] {
                        try await coord.awaitMilestone(for: dep, milestone: .created)
                    }
                    try await createCtx.createService(
                        service,
                        serviceName: serviceName,
                        from: dockerCompose
                    )
                    await coord.publishMilestone(.created, for: serviceName)
                }
            }
            try await group.waitForAll()
        }
        print("--- Containers Created ---\n")
    }

    private func remoteCreate(_ services: [(serviceName: String, service: Service)]) async throws {
        guard let projectName else { return }
        let runtime = RuntimeEnvironment.current

        print("\n--- Creating Remote Containers ---")
        for (serviceName, service) in services {
            let containerName = effectiveContainerName(
                projectName: projectName,
                serviceName: serviceName,
                explicit: service.container_name
            )

            if (try? await runtime.get(id: containerName)) != nil {
                print("Info: Remote container '\(containerName)' already exists, skipping.")
                continue
            }

            guard let image = service.image else {
                if service.build != nil {
                    throw RuntimeError.notSupported(operation: "remote compose create for build-only service '\(serviceName)'", conformer: "RemoteRuntime")
                }
                throw ComposeError.imageNotFound(serviceName)
            }

            let config = RuntimeCreateConfiguration(
                imageReference: ComposeUp.qualifyImageReference(image),
                cpus: Int(service.cpus_top ?? 1),
                hostname: service.hostname,
                environment: remoteEnvironment(for: service, baseEnvironment: environmentVariables),
                command: service.command ?? [],
                workingDirectory: service.working_dir,
                publishedPorts: remotePublishedPorts(for: service),
                capabilities: RuntimeCapabilities(add: service.cap_add ?? [], drop: service.cap_drop ?? []),
                securityOpt: service.security_opt,
                readOnly: service.read_only,
                user: service.user,
                groupAdd: service.group_add,
                privileged: service.privileged
            )
            _ = try await runtime.create(id: containerName, configuration: config)
            print("Created remote container: \(containerName)")
        }
        print("--- Remote Containers Created ---\n")
    }

    // MARK: - Network / Volume helpers (mirrors ComposeUp)

    private func createVolumeHardLink(name volumeName: String, config volumeConfig: Volume) async {
        guard let projectName else { return }
        let actualVolumeName = volumeConfig.name ?? volumeName
        let volumePath = FilePath(NSHomeDirectory())
            .pushing(FilePath(".containers/Volumes/\(projectName)/\(actualVolumeName)"))
            .lexicallyNormalized()
            .string
        print("Warning: Volume '\(actualVolumeName)' is a named volume. Linking to \(volumePath).")
        try? fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true)
    }

    private func setupNetwork(name networkName: String, config networkConfig: Network?) async throws {
        // CHAOS-1497: also honor deprecated `external: { name: ... }` form.
        let actualNetworkName = networkConfig?.name
            ?? networkConfig?.external?.name
            ?? networkName

        if let externalNetwork = networkConfig?.external, externalNetwork.isExternal {
            print("Info: Network '\(networkName)' is declared as external, skipping creation.")
            return
        }

        print("Creating network: \(networkName) (actual: \(actualNetworkName))")
        let spec = ComposeUp.runtimeNetworkSpec(name: actualNetworkName, config: networkConfig)
        do {
            _ = try await RuntimeEnvironment.current.createNetwork(spec: spec)
            print("Network '\(networkName)' created")
        } catch RuntimeError.alreadyExists {
            print("Network '\(networkName)' already exists")
        }
    }

    // MARK: - Service creation

    private func createService(_ service: Service, serviceName: String, from dockerCompose: DockerCompose) async throws {
        guard let projectName else { throw ComposeError.invalidProjectName }

        var imageToRun: String

        if let buildConfig = service.build {
            imageToRun = try await buildService(
                buildConfig,
                for: service,
                serviceName: serviceName,
                environmentVariables: environmentVariables,
                rebuild: rebuild,
                noCache: noCache,
                passThroughCommands: logging.passThroughCommands()
            )
        } else if let img = service.image {
            let qualifiedImage = ComposeUp.qualifyImageReference(img)
            let effectivePolicy = pull ? "always" : service.pull_policy
            try await pullImage(
                image: qualifiedImage,
                policy: effectivePolicy,
                platform: service.platform,
                loggingArguments: logging.passThroughCommands()
            )
            imageToRun = qualifiedImage
        } else {
            throw ComposeError.imageNotFound(serviceName)
        }

        let containerName = effectiveContainerName(
            projectName: projectName,
            serviceName: serviceName,
            explicit: service.container_name
        )

        var createArgs: [String] = []

        // Volume mounts
        if let volumes = service.volumes {
            for volume in volumes {
                let args = try await configVolume(volume)
                createArgs.append(contentsOf: args)
            }
        }

        // Environment variables
        var combinedEnv = mergeServiceEnvironment(
            baseline: environmentVariables,
            serviceEnvFile: service.env_file,
            serviceEnvironment: service.environment,
            projectDirectory: effectiveProjectDirectory
        )

        combinedEnv = combinedEnv.mapValues { value in
            guard value.contains("${") else { return value }
            let variableName = String(value.replacingOccurrences(of: "${", with: "").dropLast())
            return combinedEnv[variableName] ?? value
        }

        for (key, value) in combinedEnv {
            createArgs.append(contentsOf: ["-e", "\(key)=\(value)"])
        }

        // Reuse the per-concern arg builders from ComposeUp
        let supportsHealthcheckFlags = service.healthcheck == nil
            ? false
            : await ComposeUp.LifecycleArgs.supportsHealthcheckFlags(for: "create")
        let supportsBlkioFlags = service.blkio_config == nil
            ? false
            : await ComposeUp.ResourceArgs.supportsBlkioFlags(for: "create")
        let supportsRestartFlag = service.restart == nil
            ? false
            : await ComposeUp.LifecycleArgs.supportsRestartFlag(for: "create")

        let ctx = ComposeUp.ArgsContext(
            service: service,
            serviceName: serviceName,
            projectName: projectName,
            containerName: containerName,
            detach: false,
            environmentVariables: environmentVariables,
            dockerCompose: dockerCompose,
            composeFilename: composeFilename,
            supportsHealthcheckFlags: supportsHealthcheckFlags,
            supportsBlkioFlags: supportsBlkioFlags,
            supportsRestartFlag: supportsRestartFlag
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

        if !isNamedVolumeSource(source) {
            // CHAOS-1438: delegate to VolumeMountFSChecker so the bind-mount
            // semantics stay in sync with ComposeUp.configVolume. Previously
            // this branch had its own inline copy that (a) silently dropped
            // file-source binds and (b) silently `mkdir`'d missing sources
            // — both of which are fixed by the shared checker.
            switch VolumeMountFSChecker.check(
                source: source,
                destination: destination,
                cwd: cwd,
                fileManager: fileManager
            ) {
            case .mount(let args):
                runCommandArgs.append(contentsOf: args)
            case .skipMissing(let src):
                print("Warning: Volume mount source '\(src)' does not exist on host. Skipping this volume. Create the file or directory at the source path before running compose create if you intended to mount it.")
            }
        } else {
            guard let projectName else { return [] }
            let volumePath = FilePath(NSHomeDirectory())
                .pushing(FilePath(".containers/Volumes/\(projectName)/\(source)"))
                .lexicallyNormalized()
                .string

            print("Warning: Volume source '\(source)' is a named volume. Linking to \(volumePath).")
            try fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true)
            // Preserve the Compose target exactly; only replace the named
            // volume source with the host directory used to emulate it.
            runCommandArgs.append(contentsOf: ["-v", "\(volumePath):\(destination)"])
        }

        return runCommandArgs
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
