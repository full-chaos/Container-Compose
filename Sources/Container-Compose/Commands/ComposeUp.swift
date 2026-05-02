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
//  ComposeUp.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/19/25.
//

import ArgumentParser
import ContainerCommands
//import ContainerClient
import ContainerAPIClient
import ContainerizationExtras
import Foundation
@preconcurrency import Rainbow
import Yams

public struct ComposeUp: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "up",
        abstract: "Start containers with compose"
    )

    @Argument(help: "Specify the services to start")
    var services: [String] = []

    @Flag(
        name: [.customShort("d"), .customLong("detach")],
        help: "Detaches from container logs. Note: If you do NOT detach, killing this process will NOT kill the container. To kill the container, run container-compose down")
    var detach: Bool = false

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    private static let supportedComposeFilenames = [
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    ]

    private var cwdURL: URL {
        URL(fileURLWithPath: cwd)
    }

    private var composePath: String {
        if let composeFilename {
            return resolvedPath(for: composeFilename, relativeTo: cwdURL)
        }

        for filename in Self.supportedComposeFilenames {
            let candidate = cwdURL.appending(path: filename).path
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return cwdURL.appending(path: Self.supportedComposeFilenames[0]).path
    }

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwdURL)
    }

    @Flag(name: [.customShort("b"), .customLong("build")])
    var rebuild: Bool = false

    @Flag(name: .long, help: "Do not use cache")
    var noCache: Bool = false

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    /// Project root used for outside-container relative-path resolution
    /// (build context, env-file, volume bind sources). Honors
    /// `--project-directory` and falls back to the compose file's directory.
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
    private var containerIps: [String: String] = [:]
    private var containerConsoleColors: [String: NamedColor] = [:]
    private var didWarnServiceModelsUnsupported = false
    private var didWarnServiceProviderUnsupported = false
    private var preparedNamedVolumes: Set<String> = []

    private static let availableContainerConsoleColors: Set<NamedColor> = [
        .blue, .cyan, .magenta, .lightBlack, .lightBlue, .lightCyan, .lightYellow, .yellow, .lightGreen, .green,
    ]
    private static let testNamedVolumeSourceOverrideEnv = "CONTAINER_COMPOSE_TEST_NAMED_VOLUME_SOURCE"

    private struct PreparedVolumeSource {
        let mountSource: String
        let actualName: String
        let usesLegacyFallback: Bool
    }

    public mutating func run() async throws {
        // Decode + recursively merge includes (Phase 3E) and resolve extends
        // (Phase 3F) before anything else touches the model. loadAndMerge
        // throws IncludeError.fileNotFound if the main file is missing.
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        // Load environment variables from .env file
        environmentVariables = loadEnvFile(path: envFilePath)

        // Handle 'version' field
        if let version = dockerCompose.version {
            print("Info: Docker Compose file version parsed as: \(version)")
            print("Note: The 'version' field influences how a Docker Compose CLI interprets the file, but this custom 'container-compose' tool directly interprets the schema.")
        }

        // Determine project name for container naming.
        // Precedence: --project-name CLI flag > compose file `name:` > directory basename.
        let resolvedName = resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )
        projectName = resolvedName
        if let cliName = projectFlags.projectName, !cliName.isEmpty {
            print("Info: Using project name from --project-name flag: \(cliName)")
        } else if let name = dockerCompose.name {
            print("Info: Docker Compose project name parsed as: \(name)")
            print(
                "Note: The 'name' field currently only affects container naming (e.g., '\(name)-serviceName'). Full project-level isolation for other resources (networks, implicit volumes) is not implemented by this tool."
            )
        } else {
            print("Info: No 'name' field found in docker-compose.yml. Using directory name as project name: \(resolvedName)")
        }

        if let models = dockerCompose.models, !models.isEmpty {
            print("'top.models' Detected, But Not Supported")
        }

        // Get Services to use
        var services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap({ serviceName, service in
            guard let service else { return nil }
            return (serviceName, service)
        })

        // Filter by active profiles before topo-sort.
        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        services = Service.filterByProfiles(services, activeProfiles: activeProfiles)

        services = try Service.topoSortConfiguredServices(services)

        // Phase 3F — expand services with scale > 1 into N named replicas
        var expanded: [(serviceName: String, service: Service)] = []
        for (name, svc) in services {
            if let scale = svc.scale, scale > 1 {
                for i in 1...scale {
                    expanded.append((serviceName: "\(name)-\(i)", service: svc))
                }
            } else {
                expanded.append((name, svc))
            }
        }
        services = expanded

        // Filter for specified services
        if !self.services.isEmpty {
            services = services.filter({ serviceName, service in
                self.services.contains(where: { $0 == serviceName }) || self.services.contains(where: { service.dependedBy.contains($0) })
            })
        }

        // Stop Services
        try await stopOldStuff(services.map({ $0.serviceName }), remove: true)

        // Process top-level networks
        // This creates named networks defined in the docker-compose.yml
        if let networks = dockerCompose.networks {
            print("\n--- Processing Networks ---")
            for (networkName, networkConfig) in networks {
                try await setupNetwork(name: networkName, config: networkConfig)
            }
            print("--- Networks Processed ---\n")
        }

        // Process top-level volumes
        // This creates named volumes defined in the docker-compose.yml
        if let volumes = dockerCompose.volumes {
            print("\n--- Processing Volumes ---")
            for (volumeName, volumeConfig) in volumes {
                guard volumeConfig != nil else { continue }
                _ = try await prepareNamedVolumeSource(named: volumeName, from: dockerCompose)
            }
            print("--- Volumes Processed ---\n")
        }

        // Process each service defined in the docker-compose.yml
        print("\n--- Processing Services ---")

        print(services.map(\.serviceName))
        for (serviceName, service) in services {
            try await configService(service, serviceName: serviceName, from: dockerCompose)
        }

        if !detach {
            await waitForever()
        }
    }

    func waitForever() async -> Never {
        for await _ in AsyncStream<Void>(unfolding: {}) {
            // This will never run
        }
        fatalError("unreachable")
    }

    private func getIPForRunningService(_ serviceName: String) async throws -> String? {
        guard let projectName else { return nil }

        let containerName = "\(projectName)-\(serviceName)"

        let provider = ContainerClientEnvironment.current
        let container = try await provider.get(id: containerName)
        let ip = container.networks.compactMap { $0.ipv4Gateway.description }.first

        return ip
    }

    /// Repeatedly checks `container list -a` until the given container is listed as `running`.
    /// - Parameters:
    ///   - containerName: The exact name of the container (e.g. "Assignment-Manager-API-db").
    ///   - timeout: Max seconds to wait before failing.
    ///   - interval: How often to poll (in seconds).
    /// - Returns: `true` if the container reached "running" state within the timeout.
    private func waitUntilServiceIsRunning(_ serviceName: String, timeout: TimeInterval = 30, interval: TimeInterval = 0.5) async throws {
        guard let projectName else { return }
        let containerName = "\(projectName)-\(serviceName)"

        let deadline = Date().addingTimeInterval(timeout)
        let provider = ContainerClientEnvironment.current

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let container = try? await provider.get(id: containerName)
            if container?.status == .running {
                return
            }
        }

        throw NSError(
            domain: "ContainerWait", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for container '\(containerName)' to be running."
            ])
    }

    private func stopOldStuff(_ services: [String], remove: Bool) async throws {
        guard let projectName else { return }
        let containers = services.map { "\(projectName)-\($0)" }

        for container in containers {
            print("Stopping container: \(container)")
            let provider = ContainerClientEnvironment.current
            guard let container = try? await provider.get(id: container) else { continue }

            do {
                try await provider.stop(id: container.id, opts: .default)
            } catch {
                print("Error Stopping Container: \(error)")
            }
            if remove {
                do {
                    try await provider.delete(id: container.id, force: false)
                } catch {
                    print("Error Removing Container: \(error)")
                }
            }
        }
    }

    // MARK: Compose Top Level Functions

    private mutating func updateEnvironmentWithServiceIP(_ serviceName: String) async throws {
        let ip = try await getIPForRunningService(serviceName)
        self.containerIps[serviceName] = ip
        for (key, value) in environmentVariables.map({ ($0, $1) }) where value == serviceName {
            self.environmentVariables[key] = ip ?? value
        }
    }

    private func resolvedVolumeName(_ volumeName: String, config volumeConfig: Volume?) -> String {
        if let externalName = volumeConfig?.external?.name, volumeConfig?.external?.isExternal == true {
            return externalName
        }
        return volumeConfig?.name ?? volumeName
    }

    private func legacyVolumeFallbackPath(projectName: String, actualVolumeName: String) -> String {
        URL.homeDirectory
            .appending(path: ".containers/Volumes/\(projectName)/\(actualVolumeName)")
            .path(percentEncoded: false)
    }

    private func migrationMarkerURL(projectName: String, actualVolumeName: String) -> URL {
        URL.homeDirectory
            .appending(path: ".container-compose/volume-migrations")
            .appending(path: "\(projectName)--\(actualVolumeName).migrated")
    }

    private func writeWarningToStandardError(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    private func mergeLegacyVolumeContents(from legacyPath: String, into destinationPath: String) throws {
        let children = try fileManager.contentsOfDirectory(atPath: legacyPath)
        for child in children {
            let sourcePath = URL(fileURLWithPath: legacyPath).appending(path: child).path(percentEncoded: false)
            let destination = URL(fileURLWithPath: destinationPath).appending(path: child).path(percentEncoded: false)
            if fileManager.fileExists(atPath: destination) {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: sourcePath, isDirectory: &isDirectory), isDirectory.boolValue {
                    try fileManager.createDirectory(atPath: destination, withIntermediateDirectories: true)
                    try mergeLegacyVolumeContents(from: sourcePath, into: destination)
                }
                continue
            }
            try fileManager.copyItem(atPath: sourcePath, toPath: destination)
        }
    }

    private func migrateLegacyNamedVolumeDataIfNeeded(
        projectName: String,
        actualVolumeName: String,
    ) async throws {
        let legacyPath = legacyVolumeFallbackPath(projectName: projectName, actualVolumeName: actualVolumeName)
        guard fileManager.fileExists(atPath: legacyPath) else { return }

        let markerURL = migrationMarkerURL(projectName: projectName, actualVolumeName: actualVolumeName)
        if fileManager.fileExists(atPath: markerURL.path(percentEncoded: false)) {
            return
        }

        let runtimeVolumeSource = if let overrideRuntimeVolumeSource = ProcessInfo.processInfo.environment[Self.testNamedVolumeSourceOverrideEnv], !overrideRuntimeVolumeSource.isEmpty {
            overrideRuntimeVolumeSource
        } else {
            try await RuntimeVolumeClient.inspect(name: actualVolumeName).source
        }
        try fileManager.createDirectory(atPath: runtimeVolumeSource, withIntermediateDirectories: true)
        try mergeLegacyVolumeContents(from: legacyPath, into: runtimeVolumeSource)

        let markerParent = markerURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: markerParent, withIntermediateDirectories: true)
        let markerMessage = "migrated"
        try markerMessage.write(to: markerURL, atomically: true, encoding: .utf8)

        writeWarningToStandardError(
            "Migration: copied legacy named-volume fallback data from '\(legacyPath)' into runtime volume '\(actualVolumeName)' at '\(runtimeVolumeSource)'. Original data was left in place."
        )
    }

    private mutating func prepareNamedVolumeSource(named volumeName: String, from dockerCompose: DockerCompose) async throws -> PreparedVolumeSource {
        guard let projectName else { throw ComposeError.invalidProjectName }

        let volumeConfig = dockerCompose.volumes?[volumeName] ?? nil
        let actualVolumeName = resolvedVolumeName(volumeName, config: volumeConfig)
        let driver = volumeConfig?.driver ?? "local"

        if driver != "local" {
            let volumePath = legacyVolumeFallbackPath(projectName: projectName, actualVolumeName: actualVolumeName)
            let volumeKey = "legacy:\(actualVolumeName)"
            if preparedNamedVolumes.insert(volumeKey).inserted {
                writeWarningToStandardError(
                    "Warning: named volume '\(actualVolumeName)' requests driver '\(driver)', which apple/container does not support for compose volume CRUD yet; using legacy hardlink fallback at '\(volumePath)'."
                )
                try fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true)
            }
            return PreparedVolumeSource(mountSource: volumePath, actualName: actualVolumeName, usesLegacyFallback: true)
        }

        let volumeKey = "runtime:\(actualVolumeName)"
        if preparedNamedVolumes.insert(volumeKey).inserted {
            if volumeConfig?.external?.isExternal == true {
                do {
                    _ = try await RuntimeVolumeClient.inspect(name: actualVolumeName)
                } catch RuntimeError.notFound {
                    throw ComposeError.externalVolumeNotFound(actualVolumeName)
                }
            } else {
                do {
                    _ = try await RuntimeEnvironment.current.createVolume(
                        spec: RuntimeCreateVolumeSpec(
                            name: actualVolumeName,
                            driver: driver,
                            labels: volumeConfig?.labels ?? [:],
                            driverOptions: volumeConfig?.driver_opts ?? [:]
                        )
                    )
                } catch RuntimeError.alreadyExists {
                    // Existing named volume is fine; continue with the runtime-managed path.
                }
            }
            try await migrateLegacyNamedVolumeDataIfNeeded(projectName: projectName, actualVolumeName: actualVolumeName)
        }

        return PreparedVolumeSource(mountSource: actualVolumeName, actualName: actualVolumeName, usesLegacyFallback: false)
    }

    /// Maps a compose `networks.<name>.driver` value to the argv fragment for
    /// `container network create`'s `--plugin` flag.
    ///
    /// Docker Compose's default driver is `bridge`, which does not exist in
    /// apple/container's plugin registry (only `container-network-vmnet` ships,
    /// and is the runtime's own `--plugin` default). Emitting `--plugin bridge`
    /// fails with *"unable to locate network plugin bridge"*. We therefore
    /// treat `nil`, `""`, and `"bridge"` as "use the runtime default" and emit
    /// nothing; any other driver is passed through so users can explicitly
    /// target a custom plugin.
    internal static func networkPluginArgs(for driver: String?) -> [String] {
        guard let driver, !driver.isEmpty, driver != "bridge" else { return [] }
        return ["--plugin", driver]
    }

    private func setupNetwork(name networkName: String, config networkConfig: Network?) async throws {
        let actualNetworkName = networkConfig?.name ?? networkName  // Use explicit name or key as name

        if let externalNetwork = networkConfig?.external, externalNetwork.isExternal {
            print("Info: Network '\(networkName)' is declared as external.")
            print("This tool assumes external network '\(externalNetwork.name ?? actualNetworkName)' already exists and will not attempt to create it.")
        } else {
            var commands: [String] = [actualNetworkName]

            commands.append(contentsOf: Self.networkPluginArgs(for: networkConfig?.driver))

            // driver_opts: NetworkCreate has no --opt flag; warn and skip.
            if let driverOpts = networkConfig?.driver_opts, !driverOpts.isEmpty {
                print(
                    "Warning: Network '\(networkName)' specifies driver_opts \(driverOpts) which are not supported by Apple container network create; ignoring."
                )
            }

            // --internal: maps to NetworkCreate's --internal flag (hostOnly mode).
            if networkConfig?.isInternal == true {
                commands.append("--internal")
            }

            // Attachable: not supported by Apple container network create; warn only.
            if networkConfig?.attachable == true {
                print(
                    "Warning: Network '\(networkName)' sets 'attachable: true' which is not supported by Apple container network create; ignoring."
                )
            }

            // enable_ipv6: use --subnet-v6 flag if an IPv6 subnet is provided in IPAM config;
            // a bare enable_ipv6 without a subnet is not directly actionable here.
            if networkConfig?.enable_ipv6 == true {
                print(
                    "Warning: Network '\(networkName)' sets 'enable_ipv6: true'. Provide an IPv6 subnet in ipam.config to pass --subnet-v6; bare flag not supported."
                )
            }

            // IPAM config: emit --subnet (IPv4) or --subnet-v6 (IPv6) for each config entry.
            // ip_range and gateway are not supported by Apple container network create; warn if present.
            if let ipamConfigs = networkConfig?.ipam?.config {
                for ipamConfig in ipamConfigs {
                    if let subnet = ipamConfig.subnet, !subnet.isEmpty {
                        // Heuristic: IPv6 subnets contain ':', IPv4 use '.'
                        if subnet.contains(":") {
                            commands.append(contentsOf: ["--subnet-v6", subnet])
                        } else {
                            commands.append(contentsOf: ["--subnet", subnet])
                        }
                    }
                    if let ipRange = ipamConfig.ip_range, !ipRange.isEmpty {
                        print(
                            "Warning: Network '\(networkName)' ipam.config ip_range '\(ipRange)' is not supported by Apple container network create; ignoring."
                        )
                    }
                    if let gateway = ipamConfig.gateway, !gateway.isEmpty {
                        print(
                            "Warning: Network '\(networkName)' ipam.config gateway '\(gateway)' is not supported by Apple container network create; ignoring."
                        )
                    }
                    if let auxAddresses = ipamConfig.aux_addresses, !auxAddresses.isEmpty {
                        print(
                            "Warning: Network '\(networkName)' ipam.config aux_addresses are not supported by Apple container network create; ignoring."
                        )
                    }
                }
            }

            // IPAM driver/options: warn if present since they have no CLI equivalent.
            if let ipamDriver = networkConfig?.ipam?.driver, !ipamDriver.isEmpty {
                print(
                    "Warning: Network '\(networkName)' ipam.driver '\(ipamDriver)' is not supported by Apple container network create; ignoring."
                )
            }
            if let ipamOptions = networkConfig?.ipam?.options, !ipamOptions.isEmpty {
                print(
                    "Warning: Network '\(networkName)' ipam.options are not supported by Apple container network create; ignoring."
                )
            }

            // Add labels — NetworkCreate.parse accepts repeated --label key=value
            if let labels = networkConfig?.labels, !labels.isEmpty {
                for (labelKey, labelValue) in labels.sorted(by: { $0.key < $1.key }) {
                    commands.append(contentsOf: ["--label", "\(labelKey)=\(labelValue)"])
                }
            }

            print("Creating network: \(networkName) (Actual name: \(actualNetworkName))")
            print("Executing container network create with args: \(commands.joined(separator: " "))")
            guard (try? await ContainerClientEnvironment.current.networkGet(id: actualNetworkName)) == nil else {
                print("Network '\(networkName)' already exists")
                return
            }

            let networkCreateArgv = commands + logging.passThroughCommands()
            _ = try await RunnerEnvironment.current.run(
                RunRequest(kind: .swiftAPI(name: "NetworkCreate"), argv: networkCreateArgv, cwd: nil),
                onStdout: nil,
                onStderr: nil
            )
            print("Network '\(networkName)' created")
        }
    }

    // MARK: Compose Service Level Functions
    private mutating func configService(_ service: Service, serviceName: String, from dockerCompose: DockerCompose) async throws {
        guard let projectName else { throw ComposeError.invalidProjectName }

        // Phase 1.4 — depends_on object-form gate. Topo-sort already orders
        // dependencies before dependents, but for `condition: service_healthy`
        // and `condition: service_completed_successfully` we must wait until
        // each dependency reaches the declared state before starting this
        // service. List-form depends_on (implicit `condition: service_started`)
        // is also honored here; the wait is a no-op once the dep is running.
        if let dependencies = service.dependsOn?.entries, !dependencies.isEmpty {
            for (depName, entry) in dependencies {
                do {
                    try await waitForCondition(depName, condition: entry.condition)
                } catch {
                    if entry.required {
                        throw error
                    }
                    print(
                        "Warning: optional dependency '\(depName)' for service " +
                        "'\(serviceName)' did not satisfy condition " +
                        "'\(entry.condition.rawValue)': \(error.localizedDescription)"
                    )
                }
            }
        }

        // CHAOS-1303: Parity fields — decode-only; warn and skip at runtime.
        if service.cgroup_parent != nil {
            print("Note: 'cgroup_parent' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if service.credential_spec != nil {
            print("Note: 'credential_spec' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if service.isolation != nil {
            print("Note: 'isolation' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if let labelFile = service.label_file, !labelFile.isEmpty {
            print("Note: 'label_file' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if let postStart = service.post_start, !postStart.isEmpty {
            print("Note: 'post_start' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if let preStop = service.pre_stop, !preStop.isEmpty {
            print("Note: 'pre_stop' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if service.pull_refresh_after != nil {
            print("Note: 'pull_refresh_after' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if service.use_api_socket != nil {
            print("Note: 'use_api_socket' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if let annotations = service.annotations, !annotations.isEmpty {
            print("Note: 'annotations' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if service.attach != nil {
            print("Note: 'attach' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if service.cgroup != nil {
            print("Note: 'cgroup' for service '\(serviceName)' is not supported by Apple container; ignored.")
        }
        if let models = service.models, !models.isEmpty, !didWarnServiceModelsUnsupported {
            print("'service.models' Detected, But Not Supported")
            didWarnServiceModelsUnsupported = true
        }
        if service.provider != nil, !didWarnServiceProviderUnsupported {
            print("'service.provider' Detected, But Not Supported")
            didWarnServiceProviderUnsupported = true
        }
        if service.provider != nil, service.image == nil, service.build == nil {
            return
        }

        var imageToRun: String

        var runCommandArgs: [String] = []

        // Handle 'build' configuration
        if let buildConfig = service.build {
            imageToRun = try await buildService(buildConfig, for: service, serviceName: serviceName)
        } else if let img = service.image {
            let qualifiedImage = Self.qualifyImageReference(img)
            // Use specified image if no build config
            // Pull image if necessary
            try await pullImage(
                image: qualifiedImage,
                policy: service.pull_policy,
                platform: service.platform,
                loggingArguments: logging.passThroughCommands()
            )
            imageToRun = qualifiedImage
        } else {
            // Should not happen due to Service init validation, but as a fallback
            throw ComposeError.imageNotFound(serviceName)
        }
        
        // 'deploy' is parsed but mostly orchestrator-only — emit the same
        // diagnostic the inline implementation used to. Resource limits from
        // deploy.resources.limits are still applied via ResourceArgs below.
        if service.deploy != nil {
            print("Note: The 'deploy' configuration for service '\(serviceName)' was parsed successfully.")
            print(
                "However, this 'container-compose' tool does not currently support 'deploy' functionality (e.g., replicas, resources, update strategies) as it is primarily for orchestration platforms like Docker Swarm or Kubernetes, not direct 'container run' commands."
            )
            print("The service will be run as a single container based on other configurations.")
        }

        // Determine container name (used in builder context and elsewhere).
        let containerName: String
        if let explicitContainerName = service.container_name {
            containerName = explicitContainerName
            print("Info: Using explicit container_name: \(containerName)")
        } else {
            containerName = "\(projectName)-\(serviceName)"
        }

        // Volume mounts: still inline because configVolume(_:) is async and
        // mutates the filesystem (creates missing host dirs). Phase 2D will
        // make the helper pure and move this into StorageArgs.
        if let volumes = service.volumes {
            for volume in volumes {
                let args = try await configVolume(volume, from: dockerCompose)
                runCommandArgs.append(contentsOf: args)
            }
        }

        // Build the merged env: .env files → service env_file paths → service
        // environment map → ${VAR} substitution → service-name → IP rewrite.
        var combinedEnv = mergeServiceEnvironment(
            baseline: environmentVariables,
            serviceEnvFile: service.env_file,
            serviceEnvironment: service.environment,
            projectDirectory: effectiveProjectDirectory
        )

        combinedEnv = combinedEnv.mapValues({ value in
            guard value.contains("${") else { return value }
            let variableName = String(value.replacingOccurrences(of: "${", with: "").dropLast())
            return combinedEnv[variableName] ?? value
        })

        combinedEnv = combinedEnv.mapValues({ value in
            containerIps[value] ?? value
        })

        for (key, value) in combinedEnv {
            runCommandArgs.append(contentsOf: ["-e", "\(key)=\(value)"])
        }

        // Hand off the rest of the argv to the per-concern builders. They are
        // intentionally pure; ordering across concerns doesn't matter to
        // `container run` so we group by domain rather than by --flag.
        let ctx = ArgsContext(
            service: service,
            serviceName: serviceName,
            projectName: projectName,
            containerName: containerName,
            detach: detach,
            environmentVariables: environmentVariables,
            dockerCompose: dockerCompose,
            composeFilename: composeFilename
        )
        runCommandArgs.append(contentsOf: LifecycleArgs.build(ctx))
        runCommandArgs.append(contentsOf: SecurityArgs.build(ctx))
        runCommandArgs.append(contentsOf: ResourceArgs.build(ctx))
        runCommandArgs.append(contentsOf: NetworkingArgs.build(ctx))
        runCommandArgs.append(contentsOf: StorageArgs.build(ctx))
        runCommandArgs.append(contentsOf: LabelsArgs.build(ctx))
        runCommandArgs.append(contentsOf: ConfigsSecretsArgs.build(ctx))

        // Networks diagnostic — kept inline because it's purely informational
        // and references composeFilename in its message.
        if let serviceNetworks = service.networks {
            print(
                "Info: Service '\(serviceName)' is configured to connect to networks: \(serviceNetworks.names.joined(separator: ", ")) ascertained from networks attribute in \(composeFilename ?? "compose file")."
            )
            print(
                "Note: This tool assumes custom networks are defined at the top-level 'networks' key or are pre-existing. This tool does not create implicit networks for services if not explicitly defined at the top-level."
            )
        } else {
            print("Note: Service '\(serviceName)' is not explicitly connected to any networks. It will likely use the default bridge network.")
        }

        // Emit `--entrypoint <first>` (a pre-image flag) + image + remaining
        // entrypoint args + command, so the runtime parses entrypoint/command
        // exactly as the compose spec requires. See `imageAndEntrypointTail`.
        runCommandArgs.append(contentsOf: Self.imageAndEntrypointTail(
            image: imageToRun,
            entrypoint: service.entrypoint,
            command: service.command
        ))

        var serviceColor: NamedColor = Self.availableContainerConsoleColors.randomElement()!

        if Array(Set(containerConsoleColors.values)).sorted(by: { $0.rawValue < $1.rawValue }) != Self.availableContainerConsoleColors.sorted(by: { $0.rawValue < $1.rawValue }) {
            while containerConsoleColors.values.contains(serviceColor) {
                serviceColor = Self.availableContainerConsoleColors.randomElement()!
            }
        }

        self.containerConsoleColors[serviceName] = serviceColor

        Task { [self, serviceColor] in
            @Sendable
            func handleOutput(_ output: String) {
                print("\(serviceName): \(output)".applyingColor(serviceColor))
            }

            print("\nStarting service: \(serviceName)")
            print("Starting \(serviceName)")
            print("----------------------------------------\n")
            // Route through the RunCommandRunner seam (PR-2 of the recorder
            // migration; see docs/plans/PLAN-recorder-seam.md §7). Production
            // behaviour is byte-for-byte unchanged: the default
            // `ProductionRunner` wraps the same `Process()` semantics that
            // `streamCommand` used.
            let request = RunRequest(
                kind: .streaming,
                argv: ["container", "run"] + runCommandArgs,
                cwd: cwd
            )
            let _ = try await RunnerEnvironment.current.run(
                request,
                onStdout: handleOutput,
                onStderr: handleOutput
            )
        }

        do {
            try await waitUntilServiceIsRunning(serviceName)
            try await updateEnvironmentWithServiceIP(serviceName)
        } catch {
            print(error)
        }
    }

    /// Builds Docker Service
    ///
    /// - Parameters:
    ///   - buildConfig: The configuration for the build
    ///   - service: The service you would like to build
    ///   - serviceName: The fallback name for the image
    ///
    /// - Returns: Image Name (`String`)
    private func buildService(_ buildConfig: Build, for service: Service, serviceName: String) async throws -> String {
        // Temp file for dockerfile_inline (cleaned up via defer).
        var inlineTempURL: URL? = nil
        defer { inlineTempURL.flatMap { try? FileManager.default.removeItem(at: $0) } }

        // Determine image tag for built image
        let imageToRun = Self.qualifyImageReference(service.image ?? "\(serviceName):latest")
        let imageList = try await ContainerClientEnvironment.current.imageList()
        if !rebuild, imageList.contains(where: { $0.description.reference == imageToRun || $0.description.reference.components(separatedBy: "/").last == imageToRun }) {
            return imageToRun
        }

        // Build command arguments
        var commands = [URL(fileURLWithPath: buildConfig.context, relativeTo: URL(fileURLWithPath: effectiveProjectDirectory)).path]

        // Add build arguments
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
            commands.append(contentsOf: ["--file", URL(fileURLWithPath: buildConfig.dockerfile ?? "Dockerfile", relativeTo: URL(fileURLWithPath: effectiveProjectDirectory)).path])
        }

        // Add caching options
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
            commands.append(contentsOf: ["--os", os])
            commands.append(contentsOf: ["--arch", arch])
        } else {
            let split = service.platform?.split(separator: "/")
            let os = String(split?.first ?? "linux")
            let arch = String(((split ?? []).count >= 1 ? split?.last : nil) ?? "arm64")
            commands.append(contentsOf: ["--os", os])
            commands.append(contentsOf: ["--arch", arch])
        }

        // Add shm-size
        if let shmSize = buildConfig.shm_size {
            commands.append(contentsOf: ["--shm-size", shmSize])
        }

        // Add image name
        commands.append(contentsOf: ["--tag", imageToRun])

        // Add CPU & Memory
        let cpuCount = Int64(service.deploy?.resources?.limits?.cpus ?? "2") ?? 2
        let memoryLimit = service.deploy?.resources?.limits?.memory ?? "2048MB"
        commands.append(contentsOf: ["--cpus", "\(cpuCount)"])
        commands.append(contentsOf: ["--memory", memoryLimit])

        print("\n----------------------------------------")
        print("Building image for service: \(serviceName) (Tag: \(imageToRun))")
        _ = try await RunnerEnvironment.current.run(
            RunRequest(kind: .swiftAPI(name: "BuildCommand"), argv: commands, cwd: nil),
            onStdout: nil,
            onStderr: nil
        )
        print("Image build for \(serviceName) completed.")
        print("----------------------------------------")

        return imageToRun
    }

    private mutating func configVolume(_ volume: String, from dockerCompose: DockerCompose) async throws -> [String] {
        let resolvedVolume = resolveVariable(volume, with: environmentVariables)

        var runCommandArgs: [String] = []

        // Parse the volume string: destination[:mode]
        let components = resolvedVolume.split(separator: ":", maxSplits: 2).map(String.init)

        guard components.count >= 2 else {
            print("Warning: Volume entry '\(resolvedVolume)' has an invalid format (expected 'source:destination'). Skipping.")
            return []
        }

        let source = components[0]
        let destination = components[1]

        // Check if the source looks like a host path (contains '/' or starts with '.')
        // This heuristic helps distinguish bind mounts from named volume references.
        if source.contains("/") || source.starts(with: ".") || source.starts(with: "..") {
            // This is likely a bind mount (local path to container path)
            var isDirectory: ObjCBool = false
            // Ensure the path is absolute or relative to the current directory for FileManager
            let fullHostPath = (source.starts(with: "/") || source.starts(with: "~")) ? source : (cwd + "/" + source)

            if fileManager.fileExists(atPath: fullHostPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // Host path exists and is a directory, add the volume
                    runCommandArgs.append("-v")
                    // Reconstruct the volume string without mode, ensuring it's source:destination
                    runCommandArgs.append("\(source):\(destination)")  // Use original source for command argument
                } else {
                    // Host path exists but is a file
                    print("Warning: Volume mount source '\(source)' is a file. The 'container' tool does not support direct file mounts. Skipping this volume.")
                }
            } else {
                // Host path does not exist, assume it's meant to be a directory and try to create it.
                do {
                    try fileManager.createDirectory(atPath: fullHostPath, withIntermediateDirectories: true, attributes: nil)
                    print("Info: Created missing host directory for volume: \(fullHostPath)")
                    runCommandArgs.append("-v")
                    runCommandArgs.append("\(source):\(destination)")  // Use original source for command argument
                } catch {
                    print("Error: Could not create host directory '\(fullHostPath)' for volume '\(resolvedVolume)': \(error.localizedDescription). Skipping this volume.")
                }
            }
        } else {
            let preparedSource = try await prepareNamedVolumeSource(named: source, from: dockerCompose)
            runCommandArgs.append("-v")
            runCommandArgs.append("\(preparedSource.mountSource):\(destination)")
        }

        return runCommandArgs
    }
}

// MARK: Argv tail (image + entrypoint/command)
extension ComposeUp {

    /// Builds the trailing portion of a `container run` argv: the
    /// `--entrypoint` flag (if any), the image, and any positional args.
    ///
    /// `container run` (like `docker run`) accepts at most one
    /// `--entrypoint <BIN>` flag *before* the image, with any extra
    /// arguments to that entrypoint passed positionally *after* the image.
    /// Compose, however, models `entrypoint` as `[a, b, c]` — a full argv.
    /// We therefore split: the first token becomes the `--entrypoint` value
    /// (pre-image), the remaining tokens become positional args (post-image),
    /// followed by `command` if any.
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

        // `command` is only honored when no `entrypoint` is present *or* as
        // additional args after a multi-token entrypoint. The compose spec
        // says command is appended after entrypoint args, so we always
        // append it when set.
        if let command {
            tail.append(contentsOf: command)
        }

        return tail
    }
}

// PR-2 of the recorder migration removed the
// `extension ComposeUp { func streamCommand(...) }` helper that previously
// lived here. All `compose up` invocations now flow through
// `RunnerEnvironment.current.run(_:onStdout:onStderr:)` (see the call site in
// `configService` above). `ProductionRunner` in
// `Sources/Container-Compose/Runtime/RunCommandRunner.swift` preserves the
// previous `Process()` semantics byte-for-byte. See
// `docs/plans/PLAN-recorder-seam.md` §7 / §11.
