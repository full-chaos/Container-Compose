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
        return resolvedPath(for: envFile, relativeTo: cwd)
    }

    @Flag(name: [.customShort("b"), .customLong("build")])
    var rebuild: Bool = false

    @Flag(name: .long, help: "Do not use cache")
    var noCache: Bool = false

    /// CHAOS-1492: opt-in flag to recreate every project container even when
    /// its existing snapshot matches the compose spec. Mirrors
    /// `docker compose up --force-recreate`.
    @Flag(name: .long, help: "Recreate containers even if their configuration matches.")
    var forceRecreate: Bool = false

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
    /// CHAOS-1493: relaxed from `private` to `internal` so `Compose+Adoption.swift`'s
    /// extension can read it for the divergence-check expected-value computations.
    var environmentVariables: [String: String] = [:]
    private var containerIps: [String: String] = [:]
    /// CHAOS-1493: relaxed from `private` to `internal` so `Compose+Adoption.swift`'s
    /// extension can read it for DNS-divergence checks. Mutated only from inside
    /// `ComposeUp.run()` per the existing CHAOS-1490 lifecycle contract.
    var dnsSidecar: SidecarHandle?

    /// CHAOS-1494: synthesized implicit project default network name (e.g.
    /// `<projectName>-default`) for services that omit `service.networks` so
    /// they can attach to a project network where the embedded DNS sidecar
    /// lives. `nil` when the compose file declares its own top-level
    /// `networks:` (in which case the user-declared networks govern
    /// attachment) OR when no selected service needs the implicit fallback
    /// (every service has explicit `service.networks` or `network_mode`).
    /// Computed once near the top of `run()` and read by per-service argv
    /// builders + adoption divergence checks. `internal` so
    /// `Compose+Adoption.swift`'s extension can read it.
    var implicitDefaultNetworkName: String?
    private var dnsZoneServices: [CoreDNSConfig.ServiceRecord] = []
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

    /// CHAOS-1492: per-service adoption decisions, populated by
    /// `resolveAdoption(_:)` at the top of `run()`. Consulted by
    /// `configService(...)` to short-circuit the spawn step for adopted
    /// services (they're already running; we just rebuild env / DNS state).
    /// `internal` so the static suite can populate fixtures directly.
    var adoptionDecisions: [String: AdoptionDecision] = [:]

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

        let services = try selectServices(from: dockerCompose)

        if RuntimeExecutionMode.isRemote {
            try await remoteUp(services, from: dockerCompose)
            return
        }

        // CHAOS-1494/1498: Decide whether this project needs a synthesized
        // implicit default network BEFORE we create top-level networks. The
        // synthesis trigger fires whenever at least one selected service has
        // neither `service.networks` nor `network_mode` — regardless of
        // whether the compose file declares its own top-level `networks:`.
        // Per docker-compose semantics, services that omit `service.networks`
        // attach to the project's `<projectName>-default` network so they
        // can reach peer services + the embedded DNS sidecar even when
        // the project also defines other networks (CHAOS-1498).
        implicitDefaultNetworkName = Self.computeImplicitDefaultNetworkName(
            services: services,
            projectName: resolvedName
        )

        // Process top-level networks BEFORE adoption + sidecar so the sidecar
        // launch (which `--network`-attaches to project networks) sees them.
        // Network create is idempotent — BridgeContainerClientRuntime.createNetwork
        // catches `RuntimeError.alreadyExists` so re-runs no-op cleanly.

        if let networks = dockerCompose.networks, !networks.isEmpty {
            print("\n--- Processing Networks ---")
            for (networkName, networkConfig) in networks {
                try await setupNetwork(name: networkName, config: networkConfig)
            }
            print("--- Networks Processed ---\n")
        }

        // CHAOS-1494/1498: create the synthesized implicit default network
        // when applicable. `setupNetwork` routes through
        // `BridgeContainerClientRuntime.createNetwork`, which is idempotent on
        // `RuntimeError.alreadyExists`, so re-runs no-op cleanly. This
        // creation step runs AFTER the top-level networks loop above so the
        // implicit network coexists with any user-declared networks
        // (CHAOS-1498 medium case).
        if let implicitName = implicitDefaultNetworkName {
            print("\n--- Processing Implicit Default Network ---")
            print("Info: synthesizing implicit default network '\(implicitName)' for services without explicit 'service.networks' (CHAOS-1494/1498).")
            try await setupNetwork(name: implicitName, config: nil)
            print("--- Implicit Default Network Processed ---\n")
        }

        let projectNetworks = projectNetworkNames(from: dockerCompose, includingImplicit: implicitDefaultNetworkName)

        // CHAOS-1492 / 1493: adoption is decided AFTER the sidecar launches so
        // `specDivergenceReason` can compare each service's recorded DNS labels
        // / `dns.nameservers` against the current `dnsSidecar.perNetworkIPs`.
        // CHAOS-1492 originally placed adoption at the top of `run()`; CHAOS-1493
        // moves it inside the sidecar-onward do-catch so `dnsSidecar` is
        // populated when `resolveAdoption` runs.

        // CHAOS-1490: wrap sidecar-onward body so any thrown error tears down
        // the DNS sidecar before propagating. The `--rm` flag on the sidecar's
        // `container run` only fires when the container exits cleanly — a wait
        // timeout / image pull failure / etc. would otherwise orphan the sidecar
        // and block the next `up`. The normal exit path (detach return or
        // `waitForever`) is OUTSIDE the do-catch, so successful runs leave the
        // sidecar running for the project's lifetime alongside its services.
        do {
            if !projectNetworks.isEmpty {
                print("\n--- Starting Embedded DNS Resolver ---")
                dnsSidecar = try await EmbeddedDNSSidecar.start(
                    projectName: resolvedName,
                    networkNames: projectNetworks,
                    runner: RunnerEnvironment.current,
                    clientProvider: ContainerClientEnvironment.current
                )
                print("--- Embedded DNS Resolver Started ---\n")
            }

            // Adoption + recreation sweep (was previously at the top of run()).
            adoptionDecisions = try await resolveAdoption(services, dockerCompose: dockerCompose)
            try await applyRecreations(services, decisions: adoptionDecisions)


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
        } catch {
            // Best-effort sidecar teardown. Read `self.dnsSidecar` at catch time
            // (not via prior capture) so we see whatever value `start(...)` left
            // before throwing. `EmbeddedDNSSidecar.stop` is idempotent on the
            // `container stop` / `container delete` invocations — "already gone"
            // is treated as success.
            //
            // CHAOS-1493: ASYMMETRIC teardown. Only tear down sidecars THIS `up`
            // launched. Adopted sidecars (probe-then-adopt path) belong to whoever
            // originally launched them and may still be serving DNS for prior-run
            // services that are NOT in this `up`'s service set; killing them would
            // be worse than the original orphan-leak bug.
            if let handle = self.dnsSidecar, !handle.wasAdopted {
                print("--- Tearing down Embedded DNS Resolver (up failed) ---")
                try? await EmbeddedDNSSidecar.stop(
                    handle: handle,
                    runner: RunnerEnvironment.current
                )
            }
            throw error
        }

        if !detach {
            await waitForever()
        }
    }

    /// Resolves the runnable service set: profile/service filter, scale-N
    /// expansion (Phase 3F — `service-1`…`service-N` replicas), then narrow to
    /// any explicit service names passed on the CLI plus their dependents.
    private func selectServices(from dockerCompose: DockerCompose) throws -> [(serviceName: String, service: Service)] {
        var services = try filterServices(
            dockerCompose,
            profilesArg: profile,
            servicesArg: []
        )

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

        if !self.services.isEmpty {
            // CHAOS-1446 Phase 2 follow-up: read transitive dependents from a
            // forward-edge inversion of `dependsOn.serviceNames` rather than
            // `Service.dependedBy`. See ComposeCommand.swift `filterServices`
            // for the full root-cause writeup; same fix shape applied here.
            let requested = Set(self.services)
            let reverseGraph = buildReverseDependencyGraph(services: services)
            services = services.filter { serviceName, _ in
                requested.contains(serviceName)
                    || (reverseGraph[serviceName] ?? []).contains(where: requested.contains)
            }
        }

        return services
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
                let spec = ComposeUp.runtimeNetworkSpec(name: networkName, config: networkConfig)
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

    /// Look up the per-attachment IPv4 address for the named service's container.
    /// `internal` (not private) so CHAOS-1475 regression tests in
    /// `Container-Compose-StaticTests` can pin the gateway-vs-address contract.
    internal func getIPForRunningService(_ serviceName: String, explicitContainerName: String?) async throws -> String? {
        guard let projectName else { return nil }

        let containerName = effectiveContainerName(
            projectName: projectName,
            serviceName: serviceName,
            explicit: explicitContainerName
        )

        let provider = ContainerClientEnvironment.current
        let container = try await provider.get(id: containerName)
        // CHAOS-1475 MUST-FIX #1: use the per-attachment container IP, NOT the
        // network gateway IP. Service-name DNS A records and env-var
        // substitution must point at the container itself.
        let ip = container.networks.compactMap { $0.ipv4Address.address.description }.first

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

    private mutating func updateEnvironmentWithServiceIP(_ serviceName: String, explicitContainerName: String?) async throws -> String? {
        let ip = try await getIPForRunningService(serviceName, explicitContainerName: explicitContainerName)
        self.containerIps[serviceName] = ip
        for (key, value) in environmentVariables.map({ ($0, $1) }) where value == serviceName {
            self.environmentVariables[key] = ip ?? value
        }
        return ip
    }

    /// CHAOS-1495 note: this iterates **top-level** network keys, not service-level
    /// references, so env-substitution does NOT happen here — a top-level YAML
    /// key like `${PROJECT_NET}` would be passed to apple/container literally.
    /// `setupNetwork` has the same limitation (creates a network named
    /// `"${PROJECT_NET}"` literal). The `name:` override IS honored, matching
    /// `setupNetwork`'s `actualNetworkName` formula. Service-level references
    /// route through `resolveCanonicalNetworkName`, which DOES env-substitute,
    /// so service `networks: [${PROJECT_NET}]` against a top-level `default-net:`
    /// resolves correctly via the env. Env-substituting top-level keys would
    /// require coordinated changes in `setupNetwork`'s `actualNetworkName`
    /// derivation; deferred.
    ///
    /// CHAOS-1494: extended to optionally include the project's synthesized
    /// implicit default network so the embedded DNS sidecar attaches to it
    /// alongside any user-declared top-level networks. The implicit name is
    /// project-scoped (`<projectName>-default`) and pre-canonicalized, so it
    /// does NOT need to route through `resolveCanonicalNetworkName`.
    private func projectNetworkNames(
        from dockerCompose: DockerCompose,
        includingImplicit implicitName: String? = nil
    ) -> [String] {
        var names: [String] = []
        if let networks = dockerCompose.networks {
            names.append(contentsOf: networks.keys.sorted().map { networkName in
                // CHAOS-1497: also honor deprecated `external: { name: ... }` form.
                networks[networkName]??.name
                    ?? networks[networkName]??.external?.name
                    ?? networkName
            })
        }
        // CHAOS-1494: append the synthesized implicit default network when
        // present. Avoid double-listing if the user happened to declare a
        // top-level network with the same name (defensive; the synthesis
        // gate already prevents this in normal flow).
        if let implicitName, !names.contains(implicitName) {
            names.append(implicitName)
        }
        return names
    }

    /// CHAOS-1494/1498: decides whether the project needs a synthesized
    /// implicit default network, and if so returns its name
    /// (`<projectName>-default`).
    ///
    /// Trigger: at least one selected service has `service.networks == nil`
    /// AND `service.network_mode == nil` — i.e. would otherwise miss sidecar
    /// DNS injection. The presence of user-declared top-level `networks:` is
    /// NOT a gate; per docker-compose semantics a service that omits
    /// `service.networks` always lands on the project's default network even
    /// when other networks are declared (CHAOS-1498 medium case).
    ///
    /// Returns `nil` when every selected service overrides attachment via
    /// `service.networks` or `network_mode` (no implicit needed; avoids
    /// creating an unused network). Profile filtering happens at the caller
    /// via `selectServices(from:)` so only post-filter services are
    /// considered.
    ///
    /// `apple/container` reserves the bare network name `default` for its
    /// built-in 192.168.65.0/24 bridge (`com.apple.container.resource.role:
    /// builtin`) and rejects `container network create default`. The
    /// `<projectName>-default` form sidesteps the collision and scopes the
    /// network to this project, mirroring the `<project>-<service>` container
    /// naming convention.
    ///
    /// Originally CHAOS-1494 also required `dockerCompose.networks` to be
    /// nil/empty so the surgical fix did not disturb projects that already
    /// declared their own networks. CHAOS-1498 lifts that gate — the medium
    /// case now correctly synthesizes the implicit network alongside
    /// user-declared ones.
    internal static func computeImplicitDefaultNetworkName(
        services: [(serviceName: String, service: Service)],
        projectName: String
    ) -> String? {
        let needsImplicit = services.contains { _, service in
            service.networks == nil && service.network_mode == nil
        }
        guard needsImplicit else { return nil }
        return "\(projectName)-default"
    }

    private mutating func updateEmbeddedDNSZone(service: Service, serviceName: String, ip: String?) throws {
        guard let dnsSidecar, let ip else { return }
        dnsZoneServices.removeAll { $0.name == serviceName }
        dnsZoneServices.append(CoreDNSConfig.ServiceRecord(
            name: serviceName,
            ip: ip,
            aliases: dnsAliases(for: service)
        ))

        try EmbeddedDNSSidecar.refreshZone(
            handle: dnsSidecar,
            services: dnsZoneServices
        )
    }

    private func dnsAliases(for service: Service) -> [String] {
        guard let serviceNetworks = service.networks else { return [] }
        var aliases: [String] = []
        var seen: Set<String> = []
        for entry in serviceNetworks.entries {
            for alias in entry.config.aliases ?? [] where !seen.contains(alias) {
                seen.insert(alias)
                aliases.append(alias)
            }
        }
        return aliases
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

    /// Emit warnings for compose network fields that still have no equivalent
    /// in the fork's network create API.
    private func warnUnsupportedNetworkFields(networkName: String, config networkConfig: Network?) {
        if let configCount = networkConfig?.ipam?.config?.count, configCount > 1 {
            print(
                "Warning: Network '\(networkName)' declares multiple ipam.config entries; only the first is passed to Apple container network create."
            )
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

    internal static func runtimeNetworkSpec(name actualNetworkName: String, config networkConfig: Network?) -> RuntimeCreateNetworkSpec {
        let ipamConfig = networkConfig?.ipam?.config?.first
        return RuntimeCreateNetworkSpec(
            name: actualNetworkName,
            driver: networkConfig?.driver ?? "bridge",
            subnet: ipamConfig?.subnet,
            gateway: ipamConfig?.gateway,
            ipRange: ipamConfig?.ip_range,
            auxAddresses: ipamConfig?.aux_addresses ?? [:],
            driverOptions: networkConfig?.driver_opts ?? [:],
            attachable: networkConfig?.attachable ?? false,
            enableIPv6: networkConfig?.enable_ipv6 ?? false,
            isInternal: networkConfig?.isInternal ?? false,
            labels: networkConfig?.labels ?? [:]
        )
    }

    private func setupNetwork(name networkName: String, config networkConfig: Network?) async throws {
        // CHAOS-1497: also honor deprecated `external: { name: ... }` form.
        let actualNetworkName = networkConfig?.name
            ?? networkConfig?.external?.name
            ?? networkName  // Use explicit name or key as name

        if let externalNetwork = networkConfig?.external, externalNetwork.isExternal {
            print("Info: Network '\(networkName)' is declared as external.")
            print("This tool assumes external network '\(externalNetwork.name ?? actualNetworkName)' already exists and will not attempt to create it.")
        } else {
            // Emit warnings for unsupported compose fields before attempting creation.
            warnUnsupportedNetworkFields(networkName: networkName, config: networkConfig)

            let spec = ComposeUp.runtimeNetworkSpec(name: actualNetworkName, config: networkConfig)

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

        try await waitForServiceDependencies(service, serviceName: serviceName, from: dockerCompose)

        // CHAOS-1303 / CHAOS-1421: Parity fields — decode-only; warn (deduped) and skip at runtime.
        warnUnsupportedContainerParityFields(service)

        if let models = service.models, !models.isEmpty, !didWarnServiceModelsUnsupported {
            print("'service.models' Detected, But Not Supported")
            didWarnServiceModelsUnsupported = true
        }
        if service.provider != nil, !didWarnServiceProviderUnsupported {
            print("'service.provider' Detected, But Not Supported")
            didWarnServiceProviderUnsupported = true
        }

        // Provider-only services (no image, no build) are gated out: the
        // unsupported-warning has been emitted above and there's nothing to run.
        if service.provider != nil, service.image == nil, service.build == nil {
            return
        }

        // CHAOS-1492: containerName resolution must happen before the
        // adoption gate so it's available to the wait/IP/DNS rebuild path
        // for adopted services as well as the spawn path for create /
        // recreate.
        let containerName: String
        if let explicitContainerName = service.container_name {
            containerName = explicitContainerName
            print("Info: Using explicit container_name: \(containerName)")
        } else {
            containerName = "\(projectName)-\(serviceName)"
        }

        // CHAOS-1492: skip the spawn for adopted services. Their existing
        // process is already running; we just need to rebuild downstream
        // env-var and DNS-zone state so peer services can resolve them.
        // `waitUntilServiceIsRunning` runs in both branches; on an
        // already-running container its first poll returns immediately.
        let isAdopting = (adoptionDecisions[serviceName] == .adopt)

        if !isAdopting {
            let imageToRun = try await resolveServiceImage(service, serviceName: serviceName)

            printDeployDiagnostic(service: service, serviceName: serviceName)

            let runCommandArgs = try await assembleRunArgs(
                service: service,
                serviceName: serviceName,
                containerName: containerName,
                imageToRun: imageToRun,
                projectName: projectName,
                from: dockerCompose
            )

            printNetworksDiagnostic(service: service, serviceName: serviceName)

            launchService(serviceName: serviceName, runCommandArgs: runCommandArgs)
        }

        let resolvedIP: String?
        do {
            try await waitUntilServiceIsRunning(serviceName, explicitContainerName: service.container_name)
            resolvedIP = try await updateEnvironmentWithServiceIP(serviceName, explicitContainerName: service.container_name)
        } catch {
            // Container readiness/IP-resolution failures are surfaced but do not
            // halt the project — other services may still come up successfully.
            print(error)
            return
        }

        // CHAOS-1475 MUST-FIX #2: do NOT swallow embedded-DNS-zone refresh
        // failures. Service-name resolution is downstream of these writes,
        // so a silent failure here would produce stale zone data and broken
        // service discovery. Log to stderr with a clear prefix and rethrow.
        do {
            try updateEmbeddedDNSZone(service: service, serviceName: serviceName, ip: resolvedIP)
        } catch {
            FileHandle.standardError.write(Data(
                "Error: failed to refresh embedded DNS resolver zone for service '\(serviceName)': \(error)\n".utf8
            ))
            throw error
        }
    }

    /// Phase 1.4 — depends_on object-form gate. Topo-sort already orders
    /// dependencies before dependents, but for `condition: service_healthy` and
    /// `condition: service_completed_successfully` we must wait until each
    /// dependency reaches the declared state before starting this service.
    /// List-form depends_on (implicit `condition: service_started`) is also
    /// honored here; the wait is a no-op once the dep is running.
    private func waitForServiceDependencies(_ service: Service, serviceName: String, from dockerCompose: DockerCompose) async throws {
        guard let dependencies = service.dependsOn?.entries, !dependencies.isEmpty else { return }
        for (depName, entry) in dependencies {
            do {
                let depContainerName: String? = (dockerCompose.services[depName] ?? nil)?.container_name ?? nil
                try await waitForCondition(depName, explicitContainerName: depContainerName, condition: entry.condition)
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

    /// Resolves the image tag for a service: builds it if `build:` is set,
    /// pulls it if only `image:` is set, throws if neither is configured.
    private mutating func resolveServiceImage(_ service: Service, serviceName: String) async throws -> String {
        if let buildConfig = service.build {
            return try await buildService(
                buildConfig,
                for: service,
                serviceName: serviceName,
                environmentVariables: environmentVariables,
                rebuild: rebuild,
                noCache: noCache
            )
        }
        if let img = service.image {
            let qualifiedImage = Self.qualifyImageReference(img)
            try await pullImage(
                image: qualifiedImage,
                policy: service.pull_policy,
                platform: service.platform,
                loggingArguments: logging.passThroughCommands()
            )
            return qualifiedImage
        }
        // Should not happen due to Service init validation, but as a fallback.
        throw ComposeError.imageNotFound(serviceName)
    }

    /// Assembles the full `container run` argv: volumes, merged env, the
    /// per-concern Compose+Args*.swift builders, and the image+entrypoint tail.
    private mutating func assembleRunArgs(
        service: Service,
        serviceName: String,
        containerName: String,
        imageToRun: String,
        projectName: String,
        from dockerCompose: DockerCompose
    ) async throws -> [String] {
        var runCommandArgs: [String] = []

        // Volume mounts: still inline because configVolume(_:) is async and
        // mutates the filesystem (creates missing host dirs). Phase 2D will
        // make the helper pure and move this into StorageArgs.
        if let volumes = service.volumes {
            for volume in volumes {
                let args = try await configVolume(volume, from: dockerCompose)
                runCommandArgs.append(contentsOf: args)
            }
        }

        let combinedEnv = mergeAndExpandServiceEnv(service)
        for (key, value) in combinedEnv {
            runCommandArgs.append(contentsOf: ["-e", "\(key)=\(value)"])
        }

        // Hand off the rest of the argv to the per-concern builders. They are
        // intentionally pure; ordering across concerns doesn't matter to
        // `container run` so we group by domain rather than by --flag.
        let supportsHealthcheckFlags = service.healthcheck == nil
            ? false
            : await LifecycleArgs.supportsHealthcheckFlags(for: "run")
        let supportsBlkioFlags = service.blkio_config == nil
            ? false
            : await ResourceArgs.supportsBlkioFlags(for: "run")
        let supportsRestartFlag = service.restart == nil
            ? false
            : await LifecycleArgs.supportsRestartFlag(for: "run")

        // CHAOS-1496: pre-compute the (a)-layer fingerprint env so
        // `LabelsArgs.fingerprintLabels` can hash it without re-doing the
        // merge. NOT the same as `combinedEnv` above (which has the (b)
        // containerIps rewrite applied) — see `mergeServiceEnvForFingerprint`
        // for the rationale.
        let fingerprintEnv = mergeServiceEnvForFingerprint(service)

        let ctx = ArgsContext(
            service: service,
            serviceName: serviceName,
            projectName: projectName,
            containerName: containerName,
            detach: detach,
            environmentVariables: environmentVariables,
            dockerCompose: dockerCompose,
            composeFilename: composeFilename,
            dnsSidecar: dnsSidecar,
            fingerprintEnv: fingerprintEnv,
            supportsHealthcheckFlags: supportsHealthcheckFlags,
            supportsBlkioFlags: supportsBlkioFlags,
            supportsRestartFlag: supportsRestartFlag,
            implicitDefaultNetwork: implicitDefaultNetworkName
        )
        runCommandArgs.append(contentsOf: LifecycleArgs.build(ctx))
        runCommandArgs.append(contentsOf: SecurityArgs.build(ctx))
        runCommandArgs.append(contentsOf: ResourceArgs.build(ctx))
        runCommandArgs.append(contentsOf: NetworkingArgs.build(ctx))
        runCommandArgs.append(contentsOf: StorageArgs.build(ctx))
        runCommandArgs.append(contentsOf: LabelsArgs.build(ctx))
        runCommandArgs.append(contentsOf: ConfigsSecretsArgs.build(ctx))

        // Emit `--entrypoint <first>` (a pre-image flag) + image + remaining
        // entrypoint args + command, so the runtime parses entrypoint/command
        // exactly as the compose spec requires. See `imageAndEntrypointTail`.
        runCommandArgs.append(contentsOf: Self.imageAndEntrypointTail(
            image: imageToRun,
            entrypoint: service.entrypoint,
            command: service.command
        ))

        return runCommandArgs
    }

    /// CHAOS-1496: extracted from `mergeAndExpandServiceEnv` so the env-hash
    /// fingerprint label can capture USER-DECLARED env only — the post-merge
    /// state after `${VAR}` substitution but BEFORE peer-service-name → IP
    /// rewriting via `containerIps`.
    ///
    /// Why split: `containerIps` is populated INCREMENTALLY in `configService`
    /// (see `updateEnvironmentWithServiceIP`) AFTER each service launches.
    /// `resolveAdoption` runs BEFORE the first `configService` call (per
    /// CHAOS-1493 ordering inside the sidecar-onward do-catch in `run()`),
    /// so at adoption time `containerIps` is empty. If the env hash baked in
    /// peer-IP values at create time and then re-computed against an empty
    /// `containerIps` at adoption time, every service whose env references a
    /// peer service by name (e.g. `DB_HOST: postgres`) would spuriously
    /// diverge on every `up` and trigger a recreate cascade. Peer-IP drift
    /// is already covered by `dnsDivergenceReason` (CHAOS-1493) and the new
    /// image-label check (CHAOS-1496); double-encoding it here breaks
    /// CHAOS-1492 adoption.
    ///
    /// `internal` so `Compose+Adoption.swift` can reuse the same merge for
    /// the new `envHashDivergence` label-primary check.
    func mergeServiceEnvForFingerprint(_ service: Service) -> [String: String] {
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

        return combinedEnv
    }

    /// Builds the merged env: .env files → service env_file paths → service
    /// environment map → ${VAR} substitution → service-name → IP rewrite.
    /// CHAOS-1493: relaxed from `private` to `internal` so `Compose+Adoption.swift`'s
    /// extension can compute the expected env for service-level divergence checks.
    /// CHAOS-1496: split into `mergeServiceEnvForFingerprint` (the (a) layer)
    /// + a final containerIps rewrite (the (b) layer) so the fingerprint
    /// label scheme can hash the (a) layer in isolation. Argv emission of
    /// `-e KEY=VALUE` continues to use the full form below.
    func mergeAndExpandServiceEnv(_ service: Service) -> [String: String] {
        var combinedEnv = mergeServiceEnvForFingerprint(service)

        combinedEnv = combinedEnv.mapValues({ value in
            containerIps[value] ?? value
        })

        return combinedEnv
    }

    /// `deploy` is parsed but mostly orchestrator-only; emit the same
    /// diagnostic the inline implementation used to. Resource limits from
    /// `deploy.resources.limits` are still applied via `ResourceArgs`.
    private func printDeployDiagnostic(service: Service, serviceName: String) {
        guard service.deploy != nil else { return }
        print("Note: The 'deploy' configuration for service '\(serviceName)' was parsed successfully.")
        print(
            "However, this 'container-compose' tool does not currently support 'deploy' functionality (e.g., replicas, resources, update strategies) as it is primarily for orchestration platforms like Docker Swarm or Kubernetes, not direct 'container run' commands."
        )
        print("The service will be run as a single container based on other configurations.")
    }

    /// Networks diagnostic — purely informational, references composeFilename.
    private func printNetworksDiagnostic(service: Service, serviceName: String) {
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
    }

    /// Picks a console color for the service and dispatches the streaming
    /// `container run` Task. The Task is fire-and-forget; readiness/IP are
    /// polled by the caller via `waitUntilServiceIsRunning`.
    private mutating func launchService(serviceName: String, runCommandArgs: [String]) {
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
            // so the path-existence logic is unit-testable in isolation
            // (CHAOS-1410, behaviour updated in CHAOS-1438).
            switch VolumeMountFSChecker.check(
                source: source,
                destination: destination,
                cwd: cwd,
                fileManager: fileManager
            ) {
            case .mount(let args):
                runCommandArgs.append(contentsOf: args)
            case .skipMissing(let src):
                // CHAOS-1438: the checker no longer silently `mkdir`s missing
                // sources (the previous behaviour silently materialised
                // directories at file paths, breaking init-script binds).
                // We surface the missing source as a warning and skip this
                // single mount so one bad volume entry does not abort the
                // whole project.
                print("Warning: Volume mount source '\(src)' does not exist on host. Skipping this volume. Create the file or directory at the source path before running compose up if you intended to mount it.")
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
