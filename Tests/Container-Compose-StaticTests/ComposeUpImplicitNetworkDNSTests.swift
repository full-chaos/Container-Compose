//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
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

// CHAOS-1494: implicit-network DNS injection.
//
// Before this fix:
//   - A compose file with NO top-level `networks:` block AND services that
//     omit `service.networks` would launch services on apple/container's
//     built-in `default` bridge (192.168.65.0/24).
//   - `EmbeddedDNSSidecar.start` was guarded behind `projectNetworkNames !=
//     []` so the sidecar never started either, leaving services with no
//     DNS sidecar at all.
//   - Even if we forced a sidecar onto a project net, the default bridge
//     and project nets are isolated (verified empirically: 100% packet
//     loss between `192.168.65.0/24` and `192.168.66.0/24`), so injecting
//     `--dns <project-net-IP>` into a default-bridge service would never
//     resolve.
//
// Fix: synthesize a project-scoped implicit default network
// `<projectName>-default` when (a) the compose file declares no top-level
// `networks:` AND (b) at least one selected service has neither
// `service.networks` nor `network_mode`. The sidecar attaches to the
// synthesized network alongside any user-declared networks. Services that
// omit `service.networks` are wired to it via:
//   1. `Compose+ArgsNetworking.NetworkingArgs.build` emits `--network
//      <implicit> --dns <sidecar-ip>`.
//   2. `Compose+ArgsLabels.LabelsArgs.build` emits a matching
//      `compose.dns.resolvers.<implicit>=<ip>` label.
//   3. `Compose+Adoption.expectedNetworkNamesForService` and
//      `Compose+Adoption.dnsDivergenceReason` treat the implicit network
//      as the expected attachment for divergence checks.
//
// The bare `default` name is reserved by apple/container
// (`com.apple.container.resource.role: builtin`), so the synthesized
// network uses `<projectName>-default` to sidestep the collision.

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite("ComposeUp implicit-network DNS injection (CHAOS-1494)", .serialized)
struct ComposeUpImplicitNetworkDNSTests {

    // MARK: - Pure helper unit tests

    @Test("computeImplicitDefaultNetworkName returns synthesized name when no networks declared and a service omits service.networks")
    func computeImplicitWhenNeeded() {
        let service = Service(image: "alpine:latest")
        let dockerCompose = DockerCompose(
            version: nil, name: nil,
            services: ["web": service],
            volumes: nil, networks: nil,
            configs: nil, secrets: nil
        )
        let result = ComposeUp.computeImplicitDefaultNetworkName(
            services: [(serviceName: "web", service: service)],
            dockerCompose: dockerCompose,
            projectName: "cc-test-1494-helper"
        )
        #expect(result == "cc-test-1494-helper-default")
    }

    @Test("computeImplicitDefaultNetworkName returns nil when compose declares top-level networks")
    func noImplicitWhenTopLevelNetworksDeclared() {
        let service = Service(image: "alpine:latest")
        let dockerCompose = DockerCompose(
            version: nil, name: nil,
            services: ["web": service],
            volumes: nil,
            networks: ["mynet": Network()],
            configs: nil, secrets: nil
        )
        let result = ComposeUp.computeImplicitDefaultNetworkName(
            services: [(serviceName: "web", service: service)],
            dockerCompose: dockerCompose,
            projectName: "cc-test-1494-helper"
        )
        #expect(result == nil, "medium case (networks declared, service has no service.networks) is intentionally not addressed in CHAOS-1494; tracked as CHAOS-1498")
    }

    @Test("computeImplicitDefaultNetworkName returns nil when every service has explicit service.networks")
    func noImplicitWhenAllServicesExplicit() {
        let service = Service(image: "alpine:latest", networks: ServiceNetworks.list(["mynet"]))
        let dockerCompose = DockerCompose(
            version: nil, name: nil,
            services: ["web": service],
            volumes: nil, networks: nil,
            configs: nil, secrets: nil
        )
        let result = ComposeUp.computeImplicitDefaultNetworkName(
            services: [(serviceName: "web", service: service)],
            dockerCompose: dockerCompose,
            projectName: "cc-test-1494-helper"
        )
        #expect(result == nil)
    }

    @Test("computeImplicitDefaultNetworkName returns nil when only services use network_mode")
    func noImplicitWhenAllServicesUseNetworkMode() {
        let service = Service(image: "alpine:latest", network_mode: "host")
        let dockerCompose = DockerCompose(
            version: nil, name: nil,
            services: ["web": service],
            volumes: nil, networks: nil,
            configs: nil, secrets: nil
        )
        let result = ComposeUp.computeImplicitDefaultNetworkName(
            services: [(serviceName: "web", service: service)],
            dockerCompose: dockerCompose,
            projectName: "cc-test-1494-helper"
        )
        #expect(result == nil, "network_mode overrides project-network attachment, so no implicit network is needed")
    }

    @Test("computeImplicitDefaultNetworkName returns synthesized name even with explicit empty networks: {} top-level")
    func implicitWhenNetworksMapIsEmpty() {
        let service = Service(image: "alpine:latest")
        let dockerCompose = DockerCompose(
            version: nil, name: nil,
            services: ["web": service],
            volumes: nil,
            networks: [:],
            configs: nil, secrets: nil
        )
        let result = ComposeUp.computeImplicitDefaultNetworkName(
            services: [(serviceName: "web", service: service)],
            dockerCompose: dockerCompose,
            projectName: "cc-test-1494-empty"
        )
        #expect(result == "cc-test-1494-empty-default", "explicit empty `networks: {}` should also trigger implicit synthesis")
    }

    // MARK: - End-to-end pass 1: implicit network is synthesized + service attaches

    @Test("Pass 1: cmd.run() with no top-level networks emits --network <project>-default --dns <ip> and matching label")
    func pass1ImplicitNetworkSynthesizedAndAttached() async throws {
        let project = uniqueProjectName()
        let serviceName = "web"
        let serviceContainerName = "\(project)-\(serviceName)"
        let sidecarName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let implicitNet = "\(project)-default"
        let ipA = "10.0.0.5"

        // Compose with NO top-level `networks:` block and a service that omits
        // `service.networks`. This is the CHAOS-1494 trigger case.
        let directory = try Self.makeProject(yaml: """
            name: \(project)
            services:
              \(serviceName):
                image: alpine:latest
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = RecordingRunner()
        let provider = ImplicitNetProvider(
            sidecarName: sidecarName,
            serviceContainerName: serviceContainerName,
            networkName: implicitNet,
            sidecarSeed: nil,
            postStartSidecarIP: ipA,
            serviceSeed: nil
        )

        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await RunnerEnvironment.$current.withValue(runner) {
                var cmd = try ComposeUp.parse(["--cwd", directory.path, "-p", project, "-d"])
                try await cmd.run()
            }
        }
        defer { try? FileManager.default.removeItem(atPath: EmbeddedDNSSidecar.configRootPath(for: project).string) }

        let argvs = await runner.argvs()

        // Asserts the implicit network was created via the runtime seam.
        // `BridgeContainerClientRuntime.createNetwork` runs as part of
        // `ComposeUp.setupNetwork(...)` and goes through `RunnerEnvironment`
        // as a `.swiftAPI(name: "NetworkCreate")` invocation. The recorded
        // argv shape is `[networkName, ...flags]` (no `container network
        // create` prefix — that's added by the production binding).
        let networkCreateArgvs = await runner.swiftAPIArgvs(named: "NetworkCreate")
        #expect(
            networkCreateArgvs.contains(where: { argv in argv.first == implicitNet }),
            "ComposeUp.run() must invoke NetworkCreate for the synthesized implicit default network '\(implicitNet)'; recorded NetworkCreate argvs: \(networkCreateArgvs)"
        )

        // Service argv carries --network <implicit> and --dns <sidecarIP>.
        let serviceArgv = try #require(argvs.first(where: { argv in
            argv.starts(with: ["container", "run"])
                && argv.firstIndex(of: "--name").map { $0 + 1 < argv.count && argv[$0 + 1] == serviceContainerName } == true
        }), "expected service container run argv for \(serviceContainerName)")

        let networkIdx = try #require(serviceArgv.firstIndex(of: "--network"))
        #expect(serviceArgv.indices.contains(networkIdx + 1) && serviceArgv[networkIdx + 1] == implicitNet,
                "service argv must attach to the synthesized implicit default network")

        let dnsIdx = try #require(serviceArgv.firstIndex(of: "--dns"),
                                  "service argv must include --dns for the implicit network")
        #expect(serviceArgv.indices.contains(dnsIdx + 1) && serviceArgv[dnsIdx + 1] == ipA,
                "service argv --dns must point at the embedded DNS sidecar's IP on the implicit network")

        let expectedLabel = "compose.dns.resolvers.\(implicitNet)=\(ipA)"
        #expect(serviceArgv.contains(expectedLabel),
                "service argv must record the sidecar IP via the per-network label so divergence detection works on re-up")
    }

    // MARK: - Empty list is explicit-empty, not implicit

    @Test("Service with explicit empty networks: [] does NOT receive implicit attachment or --dns")
    func emptyServiceNetworksListIsExplicitEmpty() async throws {
        // Build the ArgsContext directly so we can isolate the
        // NetworkingArgs.build behavior from the rest of `cmd.run()`. The
        // YAML form `networks: []` decodes into a non-nil ServiceNetworks
        // with zero entries, which Oracle ruled should be treated as
        // explicit-empty (no implicit fallback).
        let service = Service(
            image: "alpine:latest",
            networks: ServiceNetworks.list([])
        )
        let dockerCompose = DockerCompose(
            version: nil, name: "cc-test-1494-emptylist",
            services: ["web": service],
            volumes: nil, networks: nil,
            configs: nil, secrets: nil
        )
        let sidecarHandle = SidecarHandle(
            projectName: "cc-test-1494-emptylist",
            containerName: EmbeddedDNSSidecar.sidecarContainerName(for: "cc-test-1494-emptylist"),
            configRoot: EmbeddedDNSSidecar.configRootPath(for: "cc-test-1494-emptylist"),
            perNetworkIPs: ["cc-test-1494-emptylist-default": "10.0.0.5"],
            wasAdopted: false
        )
        let ctx = ComposeUp.ArgsContext(
            service: service,
            serviceName: "web",
            projectName: "cc-test-1494-emptylist",
            containerName: "cc-test-1494-emptylist-web",
            detach: true,
            environmentVariables: [:],
            dockerCompose: dockerCompose,
            composeFilename: nil,
            dnsSidecar: sidecarHandle,
            implicitDefaultNetwork: "cc-test-1494-emptylist-default"
        )

        let networkingArgs = ComposeUp.NetworkingArgs.build(ctx)
        let labelsArgs = ComposeUp.LabelsArgs.build(ctx)

        #expect(!networkingArgs.contains("--network"),
                "explicit empty `networks: []` must not synthesize a --network attachment")
        #expect(!networkingArgs.contains("--dns"),
                "explicit empty `networks: []` must not inject --dns")
        #expect(!labelsArgs.contains(where: { $0.hasPrefix("compose.dns.resolvers.") }),
                "explicit empty `networks: []` must not emit DNS-resolver labels")
    }

    // MARK: - network_mode overrides implicit attachment

    @Test("Service with network_mode set and no service.networks does NOT receive implicit attachment")
    func networkModeOverridesImplicitAttachment() async throws {
        let service = Service(
            image: "alpine:latest",
            network_mode: "host"
        )
        let dockerCompose = DockerCompose(
            version: nil, name: "cc-test-1494-netmode",
            services: ["web": service],
            volumes: nil, networks: nil,
            configs: nil, secrets: nil
        )
        let sidecarHandle = SidecarHandle(
            projectName: "cc-test-1494-netmode",
            containerName: EmbeddedDNSSidecar.sidecarContainerName(for: "cc-test-1494-netmode"),
            configRoot: EmbeddedDNSSidecar.configRootPath(for: "cc-test-1494-netmode"),
            perNetworkIPs: ["cc-test-1494-netmode-default": "10.0.0.5"],
            wasAdopted: false
        )
        let ctx = ComposeUp.ArgsContext(
            service: service,
            serviceName: "web",
            projectName: "cc-test-1494-netmode",
            containerName: "cc-test-1494-netmode-web",
            detach: true,
            environmentVariables: [:],
            dockerCompose: dockerCompose,
            composeFilename: nil,
            dnsSidecar: sidecarHandle,
            implicitDefaultNetwork: "cc-test-1494-netmode-default"
        )

        let networkingArgs = ComposeUp.NetworkingArgs.build(ctx)
        let labelsArgs = ComposeUp.LabelsArgs.build(ctx)

        // The standalone `--network host` from network_mode is allowed; we
        // assert ABOUT the implicit-network attachment specifically.
        let implicitAttached = networkingArgs.firstIndex(of: "--network").map { idx in
            networkingArgs.indices.contains(idx + 1) && networkingArgs[idx + 1] == "cc-test-1494-netmode-default"
        } ?? false
        #expect(!implicitAttached,
                "network_mode service must not be attached to the implicit default project network")
        #expect(!networkingArgs.contains("--dns"),
                "network_mode service must not receive sidecar --dns injection (the network is unreachable from `host` mode anyway)")
        #expect(!labelsArgs.contains(where: { $0.hasPrefix("compose.dns.resolvers.") }),
                "network_mode service must not emit DNS-resolver labels")
    }

    // MARK: - Pass 2: sidecar IP drift forces implicit-network service recreate

    @Test("Pass 2: implicit-network service with stale compose.dns.resolvers label is recreated with new --dns when sidecar IP drifts")
    func pass2RecreatesImplicitServiceOnDNSDrift() async throws {
        let project = uniqueProjectName()
        let serviceName = "web"
        let serviceContainerName = "\(project)-\(serviceName)"
        let sidecarName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let implicitNet = "\(project)-default"
        let ipA = "10.0.0.5"
        let ipB = "10.0.0.99"

        let directory = try Self.makeProject(yaml: """
            name: \(project)
            services:
              \(serviceName):
                image: alpine:latest
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Seed the provider with pass-1 state: stopped sidecar (forces
        // recreate; post-start poll observes the new running sidecar at
        // ipB) + service running with the stale label.
        let stoppedSidecarSnapshot = try Self.sidecarSnapshot(
            id: sidecarName,
            status: .stopped,
            networkName: implicitNet,
            ip: ipA
        )
        let staleServiceSnapshot = try Self.serviceSnapshot(
            id: serviceContainerName,
            imageReference: "docker.io/library/alpine:latest",
            networkName: implicitNet,
            labels: ["compose.dns.resolvers.\(implicitNet)": ipA]
        )

        let runner = RecordingRunner()
        let provider = ImplicitNetProvider(
            sidecarName: sidecarName,
            serviceContainerName: serviceContainerName,
            networkName: implicitNet,
            sidecarSeed: stoppedSidecarSnapshot,
            postStartSidecarIP: ipB,
            serviceSeed: staleServiceSnapshot
        )

        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await RunnerEnvironment.$current.withValue(runner) {
                var cmd = try ComposeUp.parse(["--cwd", directory.path, "-p", project, "-d"])
                try await cmd.run()
            }
        }
        defer { try? FileManager.default.removeItem(atPath: EmbeddedDNSSidecar.configRootPath(for: project).string) }

        // 1. Service was stop+delete'd by applyRecreations.
        let entries = await provider.recordedEntries()
        #expect(entries.contains(.stop(id: serviceContainerName)),
                "implicit-network service must be stopped on DNS-divergence recreate")
        #expect(entries.contains(.delete(id: serviceContainerName, force: false)),
                "implicit-network service must be deleted on DNS-divergence recreate")

        // 2. Fresh argv carries `--dns <ipB>`, NOT `<ipA>`.
        let argvs = await runner.argvs()
        let serviceArgv = try #require(argvs.first(where: { argv in
            argv.starts(with: ["container", "run"])
                && argv.firstIndex(of: "--name").map { $0 + 1 < argv.count && argv[$0 + 1] == serviceContainerName } == true
        }), "expected fresh container run argv for \(serviceContainerName)")

        let allDNSValues: [String] = serviceArgv.indices.compactMap { idx in
            guard serviceArgv[idx] == "--dns", serviceArgv.indices.contains(idx + 1) else { return nil }
            return serviceArgv[idx + 1]
        }
        #expect(allDNSValues.contains(ipB),
                "pass 2 implicit-network service argv must carry the NEW sidecar IP via --dns")
        #expect(!allDNSValues.contains(ipA),
                "pass 2 implicit-network service argv must NOT carry the stale --dns from pass 1")

        // 3. New label reflects the new IP.
        #expect(serviceArgv.contains("compose.dns.resolvers.\(implicitNet)=\(ipB)"),
                "pass 2 implicit-network service must record the new sidecar IP via per-network label")
        #expect(!serviceArgv.contains("compose.dns.resolvers.\(implicitNet)=\(ipA)"),
                "pass 2 implicit-network service must NOT carry the stale label")
    }

    // MARK: - Adoption upgrade-path: pre-CHAOS-1494 container forces conservative recreate

    @Test("specDivergenceReason returns the pre-CHAOS-1494 upgrade message when the implicit-network label is missing")
    func upgradePathRecreatesPre1494Container() async throws {
        // Simulate a service container that was created BEFORE CHAOS-1494
        // shipped: it has no compose.dns.resolvers.<implicit> label and no
        // recorded nameservers because it was never attached to a project
        // network at all (it was on apple/container's default bridge, with
        // no DNS sidecar).
        let project = "cc-test-1494-upgrade"
        let serviceContainerName = "\(project)-web"
        let implicitNet = "\(project)-default"
        let sidecarIP = "10.0.0.5"
        let pre1494Snapshot = try Self.serviceSnapshot(
            id: serviceContainerName,
            imageReference: "docker.io/library/alpine:latest",
            networkName: "default",  // pre-1494: on the runtime built-in default
            labels: [:]
        )
        let service = Service(image: "alpine:latest")

        let reason = ComposeUp.specDivergenceReason(
            existing: pre1494Snapshot,
            expected: service,
            expectedSidecarIPs: [implicitNet: sidecarIP],
            expectedNetworkNames: [implicitNet],
            expectedPublishedPorts: [],
            expectedEnvironment: [:],
            expectedCommand: nil,
            implicitDefaultNetwork: implicitNet
        )
        let unwrapped = try #require(reason)
        #expect(unwrapped.contains("pre-CHAOS-1494"),
                "implicit-network upgrade path must surface a CHAOS-1494-specific reason so the recreate is auditable: '\(unwrapped)'")
        #expect(unwrapped.contains(implicitNet),
                "upgrade message must reference the implicit network name: '\(unwrapped)'")
    }

    // MARK: - Test fixtures

    /// `cc-test-` prefix marks the fixture origin per repo convention; UUID
    /// suffix avoids host config-root collisions (`~/.container-compose/<project>/dns/`).
    private func uniqueProjectName() -> String {
        "cc-test-1494-impl-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            .prefix(12).description
    }

    private static func makeProject(yaml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "compose-implicitnet-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try yaml.write(to: directory.appending(path: "compose.yml"), atomically: true, encoding: .utf8)
        return directory
    }

    private static func sidecarSnapshot(
        id: String,
        status: RuntimeStatus,
        networkName: String,
        ip: String
    ) throws -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            size: 0
        )
        let image = ImageDescription(reference: EmbeddedDNSSidecar.image, descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "/coredns",
            arguments: ["-conf", "/etc/coredns/Corefile"],
            environment: [],
            workingDirectory: "/"
        )
        let configuration = ContainerConfiguration(id: id, image: image, process: process)
        let attachment = ContainerResource.Attachment(
            network: networkName,
            hostname: id,
            ipv4Address: try CIDRv4("\(ip)/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        return ContainerSnapshot(
            configuration: configuration,
            status: status,
            networks: [attachment]
        )
    }

    private static func serviceSnapshot(
        id: String,
        imageReference: String,
        networkName: String,
        labels: [String: String]
    ) throws -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:\(String(repeating: "0", count: 64))",
            size: 0
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/"
        )
        var configuration = ContainerConfiguration(
            id: id,
            image: ImageDescription(reference: imageReference, descriptor: descriptor),
            process: process
        )
        configuration.labels = labels
        let attachment = ContainerResource.Attachment(
            network: networkName,
            hostname: id,
            ipv4Address: try CIDRv4("10.0.0.10/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        return ContainerSnapshot(
            configuration: configuration,
            status: .running,
            networks: [attachment]
        )
    }
}

// MARK: - ImplicitNetProvider

/// Minimal `ContainerClientProvider` for the implicit-network end-to-end
/// tests. Identical in shape to `DNSStabilityProvider` from
/// `ComposeUpDNSStabilityTests.swift`; copied here rather than promoted to
/// `TestHelpers` so any future divergence in semantics stays scoped to the
/// suite that needs it.
private actor ImplicitNetProvider: ContainerClientProvider {

    enum Entry: Sendable, Equatable {
        case get(id: String)
        case stop(id: String)
        case delete(id: String, force: Bool)
    }

    private var entries: [Entry] = []
    private var sidecarGetCount = 0
    private var serviceGetCount = 0

    private let sidecarName: String
    private let serviceContainerName: String
    private let networkName: String
    private let sidecarSeed: ContainerSnapshot?
    private let postStartSidecarIP: String
    private let serviceSeed: ContainerSnapshot?

    init(
        sidecarName: String,
        serviceContainerName: String,
        networkName: String,
        sidecarSeed: ContainerSnapshot?,
        postStartSidecarIP: String,
        serviceSeed: ContainerSnapshot?
    ) {
        self.sidecarName = sidecarName
        self.serviceContainerName = serviceContainerName
        self.networkName = networkName
        self.sidecarSeed = sidecarSeed
        self.postStartSidecarIP = postStartSidecarIP
        self.serviceSeed = serviceSeed
    }

    func recordedEntries() -> [Entry] { entries }

    // MARK: - ContainerClientProvider

    func get(id: String) async throws -> ContainerSnapshot {
        entries.append(.get(id: id))
        if id == sidecarName {
            let isProbe = sidecarGetCount == 0
            sidecarGetCount += 1
            if isProbe {
                if let seed = sidecarSeed { return seed }
                throw notFound(id: id)
            }
            return try Self.sidecarRunningSnapshot(
                id: id,
                networkName: networkName,
                ip: postStartSidecarIP
            )
        }
        if id == serviceContainerName {
            let isFirstGet = serviceGetCount == 0
            serviceGetCount += 1
            if isFirstGet {
                if let seed = serviceSeed { return seed }
                throw notFound(id: id)
            }
            return try Self.runningServiceSnapshot(
                id: id,
                networkName: networkName
            )
        }
        throw notFound(id: id)
    }

    func stop(id: String, opts: ContainerStopOptions) async throws {
        entries.append(.stop(id: id))
    }

    func delete(id: String, force: Bool) async throws {
        entries.append(.delete(id: id, force: force))
    }

    // MARK: - Unused conformance methods

    func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> ContainerSnapshot {
        throw notFound(id: id)
    }

    func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] { [] }
    func logs(id: String) async throws -> [FileHandle] { [] }
    func logs(id: String, options: ContainerLogOptions) async throws -> [FileHandle] { [] }
    func events() async throws -> [ContainerEvent] { [] }

    func networkGet(id: String) async throws -> NetworkState {
        throw notFound(id: id)
    }

    func imageList() async throws -> [ClientImage] { [] }

    func stats(id: String) async throws -> ContainerStats {
        ContainerStats(
            id: id,
            memoryUsageBytes: nil,
            memoryLimitBytes: nil,
            cpuUsageUsec: nil,
            networkRxBytes: nil,
            networkTxBytes: nil,
            blockReadBytes: nil,
            blockWriteBytes: nil,
            numProcesses: nil
        )
    }

    func kill(id: String, signal: Int32) async throws {}
    func start(id: String) async throws {}

    private func notFound(id: String) -> any Error {
        NSError(
            domain: "ImplicitNetProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no resource '\(id)' (CHAOS-1494 implicit-network test fake)"]
        )
    }

    private static func sidecarRunningSnapshot(
        id: String,
        networkName: String,
        ip: String
    ) throws -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            size: 0
        )
        let image = ImageDescription(reference: EmbeddedDNSSidecar.image, descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "/coredns",
            arguments: ["-conf", "/etc/coredns/Corefile"],
            environment: [],
            workingDirectory: "/"
        )
        let configuration = ContainerConfiguration(id: id, image: image, process: process)
        let attachment = ContainerResource.Attachment(
            network: networkName,
            hostname: id,
            ipv4Address: try CIDRv4("\(ip)/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        return ContainerSnapshot(
            configuration: configuration,
            status: .running,
            networks: [attachment]
        )
    }

    private static func runningServiceSnapshot(
        id: String,
        networkName: String
    ) throws -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:\(String(repeating: "0", count: 64))",
            size: 0
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/"
        )
        let configuration = ContainerConfiguration(
            id: id,
            image: ImageDescription(reference: "docker.io/library/alpine:latest", descriptor: descriptor),
            process: process
        )
        let attachment = ContainerResource.Attachment(
            network: networkName,
            hostname: id,
            ipv4Address: try CIDRv4("10.0.0.20/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        return ContainerSnapshot(
            configuration: configuration,
            status: .running,
            networks: [attachment]
        )
    }
}
