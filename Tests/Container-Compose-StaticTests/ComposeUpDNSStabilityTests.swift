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

// CHAOS-1493 end-to-end regression: DNS resolver IP stability across `up` cycles.
//
// Before this fix:
//   - CHAOS-1490 unconditionally recreated the embedded DNS sidecar every `up`.
//   - CHAOS-1492 kept project services running across `up` invocations.
//   - Services' `/etc/resolv.conf` was burned in at original launch via
//     `--dns <ip>` argv. The runtime offers no way to update it post-create.
//   - Net result: when the sidecar's IP changed across runs, adopted services
//     pointed at a dead resolver and silently lost DNS.
//
// Fix layered into two passes:
//   1. `Compose+ArgsLabels.build` writes `compose.dns.resolvers.<network>=<ip>`
//      labels at create time so the IP that went into `/etc/resolv.conf` is
//      durably recorded on the container.
//   2. `Compose+Adoption.specDivergenceReason` reads those labels back on the
//      next `up` and forces a `.recreate` when they don't match the current
//      sidecar's `perNetworkIPs`.
//
// This file pins the contract end-to-end via two focused `cmd.run()` passes:
//   - Pass 1 (no prior state): asserts the create-time argv contains
//     `--dns <ipA>` AND `--label compose.dns.resolvers.<net>=<ipA>`.
//   - Pass 2 (simulated post-pass-1 state, sidecar recreated to <ipB>):
//     asserts the service is stop+deleted via the client provider (because
//     CHAOS-1492's `applyRecreations` routes through `provider.stop/.delete`)
//     AND the new `container run` argv carries `--dns <ipB>` (NOT the stale
//     `<ipA>`) plus the corresponding label `compose.dns.resolvers.<net>=<ipB>`.

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

@Suite("ComposeUp DNS resolver stability across re-runs (CHAOS-1493)", .serialized)
struct ComposeUpDNSStabilityTests {

    // MARK: - Pass 1: fresh `up` writes labels + --dns at create time

    @Test("Pass 1: cmd.run() emits --dns and compose.dns.resolvers label for each service network")
    func pass1WritesDNSLabelsAndArgv() async throws {
        let project = uniqueProjectName()
        let serviceName = "web"
        let serviceContainerName = "\(project)-\(serviceName)"
        let sidecarName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let netName = "default"
        let ipA = "10.0.0.5"

        let directory = try Self.makeProject(yaml: """
            name: \(project)
            services:
              \(serviceName):
                image: alpine:latest
                networks:
                  - \(netName)
            networks:
              \(netName):
                driver: bridge
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = RecordingRunner()
        let provider = DNSStabilityProvider(
            sidecarName: sidecarName,
            serviceContainerName: serviceContainerName,
            networkName: netName,
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
        let serviceArgv = try #require(argvs.first(where: { argv in
            argv.starts(with: ["container", "run"])
                && argv.firstIndex(of: "--name").map { $0 + 1 < argv.count && argv[$0 + 1] == serviceContainerName } == true
        }), "expected service container run argv for \(serviceContainerName)")

        // --dns <ipA> emitted by NetworkingArgs.build
        let dnsIdx = try #require(serviceArgv.firstIndex(of: "--dns"),
                                   "service argv must include --dns")
        #expect(serviceArgv[dnsIdx + 1] == ipA,
                "pass 1 service argv --dns must use the sidecar's IP")

        // compose.dns.resolvers.<network>=<ipA> label emitted by LabelsArgs.build
        let expectedLabel = "compose.dns.resolvers.\(netName)=\(ipA)"
        #expect(serviceArgv.contains(expectedLabel),
                "pass 1 service argv must include the DNS-resolver label")
    }

    // MARK: - Pass 2: sidecar IP drift forces service recreate with new --dns

    @Test("Pass 2: after sidecar IP changes, adopted services with stale DNS label are recreated with the new --dns")
    func pass2RecreatesServicesOnDNSDrift() async throws {
        let project = uniqueProjectName()
        let serviceName = "web"
        let serviceContainerName = "\(project)-\(serviceName)"
        let sidecarName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let netName = "default"
        let ipA = "10.0.0.5"   // pass 1's sidecar IP, baked into existing service's label
        let ipB = "10.0.0.99"  // pass 2's NEW sidecar IP after recreate

        let directory = try Self.makeProject(yaml: """
            name: \(project)
            services:
              \(serviceName):
                image: alpine:latest
                networks:
                  - \(netName)
            networks:
              \(netName):
                driver: bridge
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = RecordingRunner()

        // Seed the provider with pass-1 state:
        //   - sidecar is `.stopped` (so probe-then-adopt rejects and forces a
        //     recreate; post-start poll observes the new running sidecar at ipB)
        //   - service is `.running` with the stale `compose.dns.resolvers.<net>=ipA` label
        let stoppedSidecarSnapshot = try Self.sidecarSnapshot(
            id: sidecarName,
            status: .stopped,
            networkName: netName,
            ip: ipA
        )
        let staleServiceSnapshot = try Self.serviceSnapshot(
            id: serviceContainerName,
            imageReference: "docker.io/library/alpine:latest",
            networkName: netName,
            labels: ["compose.dns.resolvers.\(netName)": ipA]
        )

        let provider = DNSStabilityProvider(
            sidecarName: sidecarName,
            serviceContainerName: serviceContainerName,
            networkName: netName,
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

        // 1. Service was stop+delete'd via the client provider (CHAOS-1492's
        //    applyRecreations routes through provider.stop/.delete).
        let entries = await provider.recordedEntries()
        #expect(entries.contains(.stop(id: serviceContainerName)),
                "service must be stopped by applyRecreations on DNS divergence")
        #expect(entries.contains(.delete(id: serviceContainerName, force: false)),
                "service must be deleted by applyRecreations on DNS divergence")

        // 2. The freshly-launched service argv must carry `--dns <ipB>`, NOT `<ipA>`.
        //    This is THE assertion that catches the original CHAOS-1493 regression.
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
                "pass 2 service argv must carry NEW sidecar IP via --dns")
        #expect(!allDNSValues.contains(ipA),
                "pass 2 service argv must NOT carry the stale --dns from pass 1")

        // 3. The new label must reflect the new IP, not the old one.
        let newLabel = "compose.dns.resolvers.\(netName)=\(ipB)"
        let staleLabel = "compose.dns.resolvers.\(netName)=\(ipA)"
        #expect(serviceArgv.contains(newLabel),
                "pass 2 service must record the new sidecar IP via compose.dns.resolvers label")
        #expect(!serviceArgv.contains(staleLabel),
                "pass 2 service must NOT carry the stale label")
    }

    // MARK: - Test fixtures

    /// `cc-test-` prefix marks the fixture origin per repo convention; UUID
    /// suffix avoids host config-root collisions (`~/.container-compose/<project>/dns/`).
    private func uniqueProjectName() -> String {
        "cc-test-dns-stab-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            .prefix(12).description
    }

    private static func makeProject(yaml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "compose-dnsstab-\(UUID().uuidString)", directoryHint: .isDirectory)
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

// MARK: - DNSStabilityProvider

/// Minimal `ContainerClientProvider` for the two-pass DNS-stability test.
///
/// The two `cmd.run()` invocations (pass 1 and pass 2) probe the sidecar AND
/// each service via `provider.get(id:)`. The sidecar additionally undergoes a
/// post-launch poll loop. This provider models all of that with a small
/// per-id call counter so we can return:
///   - sidecar's first `get(id:)` → `sidecarSeed` (or "not found" if nil)
///   - sidecar's subsequent `get(id:)` → a `.running` snapshot with `postStartSidecarIP`
///   - service's `get(id:)` → `serviceSeed` (or "not found" if nil)
/// `stop(id:)` and `delete(id:)` are recorded for assertion. Other methods
/// return harmless empty values.
private actor DNSStabilityProvider: ContainerClientProvider {

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
            // Subsequent calls (post-start poll) — return running sidecar at the
            // post-start IP.
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
            // Subsequent calls model `waitUntilServiceIsRunning` after the new
            // container_run argv was emitted by `launchService`. Returning a
            // `.running` snapshot terminates the poll quickly so the test stays
            // sub-30s.
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
            domain: "DNSStabilityProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no resource '\(id)' (DNS stability test fake)"]
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
