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

public struct ComposeUp: AsyncParsableCommand, ComposeCommand, @unchecked Sendable {
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

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    private var fileManager: FileManager { FileManager.default }
    var projectName: String?
    private var environmentVariables: [String: String] = [:]
    private var containerIps: [String: String] = [:]
    private var containerConsoleColors: [String: NamedColor] = [:]
    private var didWarnServiceModelsUnsupported = false
    private var didWarnServiceProviderUnsupported = false
    // The next three are mutated from `Compose+VolumeMigration.swift`. Swift
    // extensions can't add stored properties, so they live here and must be
    // at least `internal` for the extension's mutating methods to compile.
    var preparedNamedVolumes: Set<String> = []
    /// CHAOS-1398/CHAOS-1405: snapshot of volumes already in the runtime
    /// registry, loaded once per `up` and consulted before each `createVolume`
    /// call so the create path doesn't re-trigger apple/container's
    /// "volume.img already exists" filesystem error on re-runs, while still
    /// retaining metadata for config-drift warnings.
    var existingNamedVolumeRegistryCache: [String: RuntimeVolume] = [:]
    var existingNamedVolumeRegistryCacheLoaded: Bool = false

    private static let availableContainerConsoleColors: Set<NamedColor> = [
        .blue, .cyan, .magenta, .lightBlack, .lightBlue, .lightCyan, .lightYellow, .yellow, .lightGreen, .green,
    ]

    public mutating func run() async throws {
        // Decode + recursively merge includes (Phase 3E) and resolve extends
        // (Phase 3F) before anything else touches the model.
        let dockerCompose = try loadAndResolve()

        // Validate the compose file for semantic correctness before any side
        // effects (network/volume creation, container starts) are attempted.
        try dockerCompose.validate()

        // Load environment variables from .env file
        environmentVariables = loadEnvFile(path: envFilePath)

        // Handle 'version' field
        if let version = dockerCompose.version {
            print("Info: Docker Compose file version parsed as: \(version)")
            print("Note: The 'version' field influences how a Docker Compose CLI interprets the file, but this custom 'container-compose' tool directly interprets the schema.")
        }

        // Determine project name for container naming.
        let resolvedName = resolveProjectName(for: dockerCompose)
        projectName = resolvedName

        if let models = dockerCompose.models, !models.isEmpty {
            print("'top.models' Detected, But Not Supported")
        }

        // Get services to use. Keep service-name filtering below after scale
        // expansion to preserve ComposeUp's existing scaled-service semantics.
        var services = try filterServices(
            dockerCompose,
            profilesArg: profile,
            servicesArg: []
        )

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

        if RuntimeExecutionMode.isRemote {
            try await remoteUp(services, from: dockerCompose)
            return
        }

        // Stop Services
        try await stopOldStuff(services, remove: true)

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

    private func remoteUp(
        _ services: [(serviceName: String, service: Service)],
        from dockerCompose: DockerCompose
    ) async throws {
        guard let projectName else { return }
        let runtime = RuntimeEnvironment.current

        if let networks = dockerCompose.networks {
            for (networkName, networkConfig) in networks {
                guard let networkConfig else { continue }
                let ipamConfig = networkConfig.ipam?.config?.first
                let spec = RuntimeCreateNetworkSpec(
                    name: networkName,
                    driver: networkConfig.driver ?? "bridge",
                    subnet: ipamConfig?.subnet,
                    gateway: ipamConfig?.gateway,
                    labels: networkConfig.labels ?? [:]
                )
                _ = try? await runtime.createNetwork(spec: spec)
            }
        }

        if let volumes = dockerCompose.volumes {
            for (volumeName, volumeConfig) in volumes {
                guard volumeConfig != nil else { continue }
                _ = try? await runtime.createVolume(spec: RuntimeCreateVolumeSpec(name: volumeName))
            }
        }

        for (serviceName, service) in services {
            let containerName = effectiveContainerName(
                projectName: projectName,
                serviceName: serviceName,
                explicit: service.container_name
            )

            if let existing = try? await runtime.get(id: containerName) {
                try? await runtime.stop(id: existing.id, options: .default)
                try? await runtime.remove(id: existing.id, force: true)
            }

            guard let image = service.image else {
                if service.build != nil {
                    throw RuntimeError.notSupported(operation: "remote compose up for build-only service '\(serviceName)'", conformer: "RemoteRuntime")
                }
                throw ComposeError.imageNotFound(serviceName)
            }

            let config = RuntimeCreateConfiguration(
                imageReference: Self.qualifyImageReference(image),
                cpus: Int(service.cpus_top ?? 1),
                hostname: service.hostname,
                environment: remoteEnvironment(for: service),
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
            try await runtime.start(id: containerName)
            print("Started remote container: \(containerName)")
        }
    }

    private func remoteEnvironment(for service: Service) -> [String] {
        var merged = environmentVariables
        for (key, value) in service.environment ?? [:] {
            merged[key] = value
        }
        return merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    private func remotePublishedPorts(for service: Service) -> [RuntimePublishedPort] {
        (service.ports ?? []).compactMap { raw in
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let hostPart = String(parts[parts.count - 2])
            let containerPart = String(parts[parts.count - 1])
            guard
                let hostPort = UInt16(hostPart),
                let containerPort = UInt16(containerPart.split(separator: "/").first ?? "")
            else { return nil }
            let proto = containerPart.hasSuffix("/udp") ? RuntimePortProtocol.udp : .tcp
            return RuntimePublishedPort(
                hostAddress: "0.0.0.0",
                hostPort: hostPort,
                containerPort: containerPort,
                proto: proto
            )
        }
    }

    func waitForever() async -> Never {
        for await _ in AsyncStream<Void>(unfolding: {}) {
            // This will never run
        }
        fatalError("unreachable")
    }

    private func getIPForRunningService(_ serviceName: String, explicitContainerName: String?) async throws -> String? {
        guard let projectName else { return nil }

        let containerName = effectiveContainerName(
            projectName: projectName,
            serviceName: serviceName,
            explicit: explicitContainerName
        )

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
    private func waitUntilServiceIsRunning(_ serviceName: String, explicitContainerName: String?, timeout: TimeInterval = 30, interval: TimeInterval = 0.5) async throws {
        guard let projectName else { return }
        let containerName = effectiveContainerName(
            projectName: projectName,
            serviceName: serviceName,
            explicit: explicitContainerName
        )

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

    internal func stopOldStuff(_ services: [(serviceName: String, service: Service)], remove: Bool) async throws {
        guard let projectName else { return }
        let containerNames = services.map { entry in
            effectiveContainerName(
                projectName: projectName,
                serviceName: entry.serviceName,
                explicit: entry.service.container_name
            )
        }

        for containerName in containerNames {
            print("Stopping container: \(containerName)")
            let provider = ContainerClientEnvironment.current
            guard let container = try? await provider.get(id: containerName) else { continue }

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

    private mutating func updateEnvironmentWithServiceIP(_ serviceName: String, explicitContainerName: String?) async throws {
        let ip = try await getIPForRunningService(serviceName, explicitContainerName: explicitContainerName)
        self.containerIps[serviceName] = ip
        for (key, value) in environmentVariables.map({ ($0, $1) }) where value == serviceName {
            self.environmentVariables[key] = ip ?? value
        }
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

    // MARK: - Network creation helpers

    /// Emit warnings for compose network fields that have no equivalent in
    /// apple/container's network create API. Called before every `createNetwork`
    /// invocation so the user knows which parts of their config are ignored.
    private func warnUnsupportedNetworkFields(networkName: String, config networkConfig: Network?) {
        // driver_opts: NetworkCreate has no --opt flag.
        if let driverOpts = networkConfig?.driver_opts, !driverOpts.isEmpty {
            print(
                "Warning: Network '\(networkName)' specifies driver_opts \(driverOpts) which are not supported by Apple container network create; ignoring."
            )
        }

        // Attachable: not supported by Apple container network create.
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

        // IPAM config unsupported sub-fields.
        if let ipamConfigs = networkConfig?.ipam?.config {
            for ipamConfig in ipamConfigs {
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

        // IPAM driver/options.
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
    }

    private func setupNetwork(name networkName: String, config networkConfig: Network?) async throws {
        let actualNetworkName = networkConfig?.name ?? networkName  // Use explicit name or key as name

        if let externalNetwork = networkConfig?.external, externalNetwork.isExternal {
            print("Info: Network '\(networkName)' is declared as external.")
            print("This tool assumes external network '\(externalNetwork.name ?? actualNetworkName)' already exists and will not attempt to create it.")
        } else {
            // Emit warnings for unsupported compose fields before attempting creation.
            warnUnsupportedNetworkFields(networkName: networkName, config: networkConfig)

            // Build a backend-neutral spec from the compose Network model.
            // CHAOS-1408: network creation now routes through the Runtime abstraction
            // rather than shelling out via RunnerEnvironment/RunCommandRunner.
            // Subnet and gateway (IPAM) are intentionally excluded here — that is
            // CHAOS-1409 territory and those fields are being added to
            // RuntimeCreateNetworkSpec there in parallel.
            let driver = networkConfig?.driver ?? "bridge"
            let spec = RuntimeCreateNetworkSpec(
                name: actualNetworkName,
                driver: driver,
                labels: networkConfig?.labels ?? [:]
            )

            print("Creating network: \(networkName) (Actual name: \(actualNetworkName))")

            do {
                _ = try await RuntimeEnvironment.current.createNetwork(spec: spec)
                print("Network '\(networkName)' created")
            } catch RuntimeError.alreadyExists {
                // Idempotent: network already exists from a previous run. This
                // matches the pre-migration behaviour where `networkGet` returning
                // non-nil caused an early return with "already exists".
                print("Network '\(networkName)' already exists")
            }
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

        // CHAOS-1303 / CHAOS-1421: Parity fields — decode-only; warn (deduped) and skip at runtime.
        if service.cgroup_parent != nil {
            warnUnsupportedRuntimeFieldOnce(
                "service.cgroup_parent",
                "Note: 'cgroup_parent' is parsed but not supported by Apple container; ignored."
            )
        }
        if service.credential_spec != nil {
            warnUnsupportedRuntimeFieldOnce(
                "service.credential_spec",
                "Note: 'credential_spec' is parsed but not supported by Apple container; ignored."
            )
        }
        if service.isolation != nil {
            warnUnsupportedRuntimeFieldOnce(
                "service.isolation",
                "Note: 'isolation' is parsed but not supported by Apple container; ignored."
            )
        }
        if let labelFile = service.label_file, !labelFile.isEmpty {
            warnUnsupportedRuntimeFieldOnce(
                "service.label_file",
                "Note: 'label_file' is parsed but not supported by Apple container; ignored."
            )
        }
        if let postStart = service.post_start, !postStart.isEmpty {
            warnUnsupportedRuntimeFieldOnce(
                "service.post_start",
                "Note: 'post_start' is parsed but not supported by Apple container; ignored."
            )
        }
        if let preStop = service.pre_stop, !preStop.isEmpty {
            warnUnsupportedRuntimeFieldOnce(
                "service.pre_stop",
                "Note: 'pre_stop' is parsed but not supported by Apple container; ignored."
            )
        }
        if service.pull_refresh_after != nil {
            warnUnsupportedRuntimeFieldOnce(
                "service.pull_refresh_after",
                "Note: 'pull_refresh_after' is parsed but not supported by Apple container; ignored."
            )
        }
        if service.use_api_socket != nil {
            warnUnsupportedRuntimeFieldOnce(
                "service.use_api_socket",
                "Note: 'use_api_socket' is parsed but not supported by Apple container; ignored."
            )
        }
        if let annotations = service.annotations, !annotations.isEmpty {
            warnUnsupportedRuntimeFieldOnce(
                "service.annotations",
                "Note: 'annotations' is parsed but not supported by Apple container; ignored."
            )
        }
        if service.attach != nil {
            warnUnsupportedRuntimeFieldOnce(
                "service.attach",
                "Note: 'attach' is parsed but not supported by Apple container; ignored."
            )
        }
        if service.cgroup != nil {
            warnUnsupportedRuntimeFieldOnce(
                "service.cgroup",
                "Note: 'cgroup' is parsed but not supported by Apple container; ignored."
            )
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
            imageToRun = try await buildService(
                buildConfig,
                for: service,
                serviceName: serviceName,
                environmentVariables: environmentVariables,
                rebuild: rebuild,
                noCache: noCache
            )
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
            try await waitUntilServiceIsRunning(serviceName, explicitContainerName: service.container_name)
            try await updateEnvironmentWithServiceIP(serviceName, explicitContainerName: service.container_name)
        } catch {
            print(error)
        }
    }


    private mutating func configVolume(_ volume: String, from dockerCompose: DockerCompose) async throws -> [String] {
        let resolvedVolume = resolveVariable(volume, with: environmentVariables)

        var runCommandArgs: [String] = []

        // Delegate pure string parsing to VolumeMountParser.
        let spec: VolumeMountSpec
        switch VolumeMountParser.parse(resolvedVolume) {
        case .success(let parsed):
            spec = parsed
        case .failure:
            print("Warning: Volume entry '\(resolvedVolume)' has an invalid format (expected 'source:destination'). Skipping.")
            return []
        }

        let source = spec.originalSource
        let destination = spec.destination

        // Warn-and-skip unsupported mount mode (e.g. :ro, :rw, :Z, :z).
        // apple/container does not accept a mode suffix on -v arguments.
        // We emit a one-time per-key warning so the user knows the flag
        // is being silently ignored, then continue mounting without it.
        // This aligns with the warn-and-skip convention established for
        // other unsupported compose fields (Compose+ArgsStorage.swift etc.).
        if let mode = spec.mode {
            warnUnsupportedRuntimeFieldOnce(
                "volume.mode:\(resolvedVolume)",
                "Warning: Volume mount mode ':\(mode)' on '\(resolvedVolume)' is not supported by apple/container and will be ignored. Mount will use container default permissions."
            )
        }

        switch spec.kind {
        case .bindMount:
            // Bind mount: delegate filesystem-checking to VolumeMountFSChecker
            // so the path-existence / auto-creation logic is unit-testable in
            // isolation (CHAOS-1410).
            switch VolumeMountFSChecker.check(
                source: source,
                destination: destination,
                cwd: cwd,
                fileManager: fileManager
            ) {
            case .mount(let args):
                runCommandArgs.append(contentsOf: args)
            case .skipFile(let src):
                print("Warning: Volume mount source '\(src)' is a file. The 'container' tool does not support direct file mounts. Skipping this volume.")
            case .created(let fullHostPath, let args):
                print("Info: Created missing host directory for volume: \(fullHostPath)")
                runCommandArgs.append(contentsOf: args)
            case .skipCreateError(let fullHostPath, let underlyingError):
                print("Error: Could not create host directory '\(fullHostPath)' for volume '\(resolvedVolume)': \(underlyingError). Skipping this volume.")
            }

        case .namedVolume:
            let preparedSource = try await prepareNamedVolumeSource(named: source, from: dockerCompose)
            runCommandArgs.append("-v")
            runCommandArgs.append("\(preparedSource.mountSource):\(destination)")

        case .tmpfs:
            // A volume entry with an empty source is treated as tmpfs; not currently
            // supported as a short-form volume in apple/container. Warn and skip.
            warnUnsupportedRuntimeFieldOnce(
                "volume.tmpfs:\(resolvedVolume)",
                "Warning: tmpfs short-form volume entry '\(resolvedVolume)' is not supported by apple/container; ignored."
            )
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
