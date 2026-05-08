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

import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite("Embedded DNS sidecar argv")
struct EmbeddedDNSSidecarArgvTests {

    // MARK: - start() argv

    @Test("start emits the expected container run argv shape")
    func startEmitsRunArgv() async throws {
        let project = uniqueProjectName()
        let networks = ["frontend", "backend"]
        let runner = RecordingRunner()
        let provider = SidecarFakeProvider(
            snapshot: try Self.snapshot(
                id: EmbeddedDNSSidecar.sidecarContainerName(for: project),
                networks: [
                    (name: "frontend", ip: "192.168.65.10"),
                    (name: "backend", ip: "192.168.65.11"),
                ]
            )
        )

        let handle = try await EmbeddedDNSSidecar.start(
            projectName: project,
            networkNames: networks,
            runner: runner,
            clientProvider: provider
        )
        defer { try? FileManager.default.removeItem(atPath: handle.configRoot.string) }

        let runArgvs = await runner.runArgvs()
        #expect(runArgvs.count == 1)
        guard let argv = runArgvs.first else {
            Issue.record("Expected exactly one container run argv")
            return
        }

        // Prefix shape: container run --rm -d --name <name>
        #expect(Array(argv.prefix(6)) == [
            "container", "run", "--rm", "-d", "--name",
            EmbeddedDNSSidecar.sidecarContainerName(for: project),
        ])

        // --network flags appear in declared order, one per network.
        #expect(Self.values(after: "--network", in: argv) == networks)

        // --mount points host configRoot at /etc/coredns read-only.
        let expectedMount = "type=bind,source=\(handle.configRoot.string),target=/etc/coredns,readonly"
        #expect(Self.value(after: "--mount", in: argv) == expectedMount)

        // Trailing: image -conf /etc/coredns/Corefile
        #expect(Array(argv.suffix(3)) == [
            EmbeddedDNSSidecar.image,
            "-conf",
            "/etc/coredns/Corefile",
        ])

        // Handle's perNetworkIPs is resolved from the snapshot.
        #expect(handle.perNetworkIPs == [
            "frontend": "192.168.65.10",
            "backend": "192.168.65.11",
        ])
        #expect(handle.containerName == "\(project)-compose-dns")
        #expect(handle.projectName == project)
    }

    @Test("start emits one --network flag per network in declared order")
    func startEmitsOneNetworkFlagPerNetwork() async throws {
        let project = uniqueProjectName()
        let networks = ["alpha", "bravo", "charlie"]
        let runner = RecordingRunner()
        let provider = SidecarFakeProvider(
            snapshot: try Self.snapshot(
                id: EmbeddedDNSSidecar.sidecarContainerName(for: project),
                networks: networks.enumerated().map { (idx, name) in
                    (name: name, ip: "10.0.0.\(10 + idx)")
                }
            )
        )

        let handle = try await EmbeddedDNSSidecar.start(
            projectName: project,
            networkNames: networks,
            runner: runner,
            clientProvider: provider
        )
        defer { try? FileManager.default.removeItem(atPath: handle.configRoot.string) }

        let runArgvs = await runner.runArgvs()
        guard let argv = runArgvs.first else {
            Issue.record("Expected one container run argv")
            return
        }
        let networkValues = Self.values(after: "--network", in: argv)
        #expect(networkValues == networks)
        #expect(networkValues.count == 3)
    }

    @Test("start writes Corefile and empty zone file before launching")
    func startWritesInitialConfigBeforeLaunch() async throws {
        let project = uniqueProjectName()
        let runner = RecordingRunner()
        let provider = SidecarFakeProvider(
            snapshot: try Self.snapshot(
                id: EmbeddedDNSSidecar.sidecarContainerName(for: project),
                networks: [(name: "primary", ip: "10.0.0.42")]
            )
        )

        let handle = try await EmbeddedDNSSidecar.start(
            projectName: project,
            networkNames: ["primary"],
            runner: runner,
            clientProvider: provider
        )
        defer { try? FileManager.default.removeItem(atPath: handle.configRoot.string) }

        // Corefile lives at <configRoot>/Corefile.
        let corefilePath = handle.configRoot
            .pushing(FilePath("Corefile"))
            .lexicallyNormalized()
        let corefileContents = try String(contentsOfFile: corefilePath.string, encoding: .utf8)
        #expect(corefileContents.contains("\(project).test"))
        #expect(corefileContents.contains("file /etc/coredns/zones/\(project).zone"))
        #expect(corefileContents.contains("reload 5s"))

        // Initial zone is non-empty (SOA + headers) but has no service records.
        let zonePath = handle.configRoot
            .pushing(FilePath("zones"))
            .pushing(FilePath("\(project).zone"))
            .lexicallyNormalized()
        let zoneContents = try String(contentsOfFile: zonePath.string, encoding: .utf8)
        #expect(zoneContents.contains("$ORIGIN \(project).test."))
        #expect(zoneContents.contains("SOA"))
        // No service A records yet.
        #expect(!zoneContents.contains("IN A   "))
    }

    // MARK: - refreshZone()

    @Test("refreshZone writes file atomically and replaces previous zone")
    func refreshZoneWritesAtomically() async throws {
        let project = uniqueProjectName()
        let runner = RecordingRunner()
        let provider = SidecarFakeProvider(
            snapshot: try Self.snapshot(
                id: EmbeddedDNSSidecar.sidecarContainerName(for: project),
                networks: [(name: "net0", ip: "10.0.0.5")]
            )
        )

        let handle = try await EmbeddedDNSSidecar.start(
            projectName: project,
            networkNames: ["net0"],
            runner: runner,
            clientProvider: provider
        )
        defer { try? FileManager.default.removeItem(atPath: handle.configRoot.string) }

        let zonePath = handle.configRoot
            .pushing(FilePath("zones"))
            .pushing(FilePath("\(project).zone"))
            .lexicallyNormalized()

        let services: [CoreDNSConfig.ServiceRecord] = [
            CoreDNSConfig.ServiceRecord(name: "postgres", ip: "10.0.0.10", aliases: ["db"]),
            CoreDNSConfig.ServiceRecord(name: "redis", ip: "10.0.0.11", aliases: []),
        ]
        try EmbeddedDNSSidecar.refreshZone(handle: handle, services: services)

        let zoneContents = try String(contentsOfFile: zonePath.string, encoding: .utf8)
        #expect(zoneContents.contains("postgres"))
        #expect(zoneContents.contains("10.0.0.10"))
        #expect(zoneContents.contains("redis"))
        #expect(zoneContents.contains("10.0.0.11"))
        #expect(zoneContents.contains("db"))

        // No leftover .tmp files in the zones directory.
        let zonesDir = handle.configRoot
            .pushing(FilePath("zones"))
            .lexicallyNormalized()
        let entries = try FileManager.default.contentsOfDirectory(atPath: zonesDir.string)
        #expect(entries.allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test("refreshZone overwrites previous content")
    func refreshZoneOverwritesPrevious() async throws {
        let project = uniqueProjectName()
        let runner = RecordingRunner()
        let provider = SidecarFakeProvider(
            snapshot: try Self.snapshot(
                id: EmbeddedDNSSidecar.sidecarContainerName(for: project),
                networks: [(name: "net0", ip: "10.0.0.5")]
            )
        )

        let handle = try await EmbeddedDNSSidecar.start(
            projectName: project,
            networkNames: ["net0"],
            runner: runner,
            clientProvider: provider
        )
        defer { try? FileManager.default.removeItem(atPath: handle.configRoot.string) }

        try EmbeddedDNSSidecar.refreshZone(
            handle: handle,
            services: [CoreDNSConfig.ServiceRecord(name: "first", ip: "10.0.0.20", aliases: [])]
        )
        try EmbeddedDNSSidecar.refreshZone(
            handle: handle,
            services: [CoreDNSConfig.ServiceRecord(name: "second", ip: "10.0.0.21", aliases: [])]
        )

        let zonePath = handle.configRoot
            .pushing(FilePath("zones"))
            .pushing(FilePath("\(project).zone"))
            .lexicallyNormalized()
        let contents = try String(contentsOfFile: zonePath.string, encoding: .utf8)
        #expect(contents.contains("second"))
        #expect(!contents.contains("first"))
    }

    // MARK: - stop()

    @Test("stop emits container stop then container delete")
    func stopEmitsStopThenDelete() async throws {
        let project = uniqueProjectName()
        let configRoot = EmbeddedDNSSidecar.configRootPath(for: project)
        let handle = SidecarHandle(
            projectName: project,
            containerName: EmbeddedDNSSidecar.sidecarContainerName(for: project),
            configRoot: configRoot,
            perNetworkIPs: [:]
        )
        let runner = RecordingRunner()

        try await EmbeddedDNSSidecar.stop(handle: handle, runner: runner)

        let argvs = await runner.argvs()
        #expect(argvs == [
            ["container", "stop", handle.containerName],
            ["container", "delete", handle.containerName],
        ])
    }

    @Test("stop tolerates non-zero exits (best-effort teardown)")
    func stopToleratesNonZeroExits() async throws {
        let project = uniqueProjectName()
        let handle = SidecarHandle(
            projectName: project,
            containerName: EmbeddedDNSSidecar.sidecarContainerName(for: project),
            configRoot: EmbeddedDNSSidecar.configRootPath(for: project),
            perNetworkIPs: [:]
        )
        let runner = RecordingRunner()
        // Both stop and delete return exit 1 — should NOT throw.
        await runner.stub(argvPrefix: ["container", "stop"], exitCode: 1)
        await runner.stub(argvPrefix: ["container", "delete"], exitCode: 1)

        try await EmbeddedDNSSidecar.stop(handle: handle, runner: runner)

        let argvs = await runner.argvs()
        #expect(argvs.count == 2)
    }

    @Test("stop removes config dir by default")
    func stopRemovesConfigDirByDefault() async throws {
        let project = uniqueProjectName()
        let configRoot = EmbeddedDNSSidecar.configRootPath(for: project)
        // Create the dir so we can verify removal.
        try FileManager.default.createDirectory(
            atPath: configRoot.string,
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.fileExists(atPath: configRoot.string))

        let handle = SidecarHandle(
            projectName: project,
            containerName: EmbeddedDNSSidecar.sidecarContainerName(for: project),
            configRoot: configRoot,
            perNetworkIPs: [:]
        )
        let runner = RecordingRunner()

        // Empty environment → no KEEP variable → removal proceeds.
        try await EmbeddedDNSSidecar.stop(
            handle: handle,
            runner: runner,
            environment: [:]
        )

        #expect(!FileManager.default.fileExists(atPath: configRoot.string))
    }

    @Test("stop preserves config dir when CONTAINER_COMPOSE_KEEP_DNS_STATE=1")
    func stopPreservesConfigDirWhenKeepEnvSet() async throws {
        let project = uniqueProjectName()
        let configRoot = EmbeddedDNSSidecar.configRootPath(for: project)
        try FileManager.default.createDirectory(
            atPath: configRoot.string,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: configRoot.string) }

        let handle = SidecarHandle(
            projectName: project,
            containerName: EmbeddedDNSSidecar.sidecarContainerName(for: project),
            configRoot: configRoot,
            perNetworkIPs: [:]
        )
        let runner = RecordingRunner()

        try await EmbeddedDNSSidecar.stop(
            handle: handle,
            runner: runner,
            environment: ["CONTAINER_COMPOSE_KEEP_DNS_STATE": "1"]
        )

        #expect(FileManager.default.fileExists(atPath: configRoot.string))
    }

    @Test("stop removes config dir when KEEP env is set to value other than 1")
    func stopRemovesConfigDirWhenKeepEnvNotOne() async throws {
        let project = uniqueProjectName()
        let configRoot = EmbeddedDNSSidecar.configRootPath(for: project)
        try FileManager.default.createDirectory(
            atPath: configRoot.string,
            withIntermediateDirectories: true
        )
        let handle = SidecarHandle(
            projectName: project,
            containerName: EmbeddedDNSSidecar.sidecarContainerName(for: project),
            configRoot: configRoot,
            perNetworkIPs: [:]
        )
        let runner = RecordingRunner()

        try await EmbeddedDNSSidecar.stop(
            handle: handle,
            runner: runner,
            environment: ["CONTAINER_COMPOSE_KEEP_DNS_STATE": "0"]
        )

        #expect(!FileManager.default.fileExists(atPath: configRoot.string))
    }

    // MARK: - Validation

    @Test("start fails fast when no networks are provided")
    func startFailsWhenNoNetworks() async throws {
        let project = uniqueProjectName()
        let runner = RecordingRunner()
        let provider = SidecarFakeProvider(snapshot: nil)

        await #expect(throws: EmbeddedDNSSidecarError.self) {
            _ = try await EmbeddedDNSSidecar.start(
                projectName: project,
                networkNames: [],
                runner: runner,
                clientProvider: provider
            )
        }

        // No container run argv emitted.
        let runArgvs = await runner.runArgvs()
        #expect(runArgvs.isEmpty)
    }

    @Test("start propagates non-zero runner exit as commandFailed")
    func startPropagatesRunnerFailure() async throws {
        let project = uniqueProjectName()
        let runner = RecordingRunner()
        await runner.stub(argvPrefix: ["container", "run"], exitCode: 125)
        let provider = SidecarFakeProvider(snapshot: nil)

        await #expect(throws: EmbeddedDNSSidecarError.self) {
            _ = try await EmbeddedDNSSidecar.start(
                projectName: project,
                networkNames: ["net0"],
                runner: runner,
                clientProvider: provider
            )
        }

        // Cleanup: the failing path may have created the config dir.
        let configRoot = EmbeddedDNSSidecar.configRootPath(for: project)
        try? FileManager.default.removeItem(atPath: configRoot.string)
    }

    // MARK: - SidecarHandle conveniences

    @Test("SidecarHandle.forCleanup synthesizes a deterministic handle from projectName")
    func forCleanupSynthesizesDeterministicHandle() {
        let project = "sample-project"
        let home = URL(fileURLWithPath: "/tmp/cc-test-home", isDirectory: true)

        let handle = SidecarHandle.forCleanup(
            projectName: project,
            homeDirectoryURL: home
        )

        #expect(handle.projectName == project)
        #expect(handle.containerName == "sample-project-compose-dns")
        #expect(handle.configRoot.string == "/tmp/cc-test-home/.container-compose/sample-project/dns")
        #expect(handle.perNetworkIPs.isEmpty)
    }

    @Test("SidecarHandle.forCleanup is idempotent for the same projectName")
    func forCleanupIsIdempotent() {
        let home = URL(fileURLWithPath: "/var/cc-home", isDirectory: true)
        let first = SidecarHandle.forCleanup(projectName: "acme", homeDirectoryURL: home)
        let second = SidecarHandle.forCleanup(projectName: "acme", homeDirectoryURL: home)

        #expect(first.containerName == second.containerName)
        #expect(first.configRoot.string == second.configRoot.string)
        #expect(first.searchDomain == second.searchDomain)
    }

    @Test("SidecarHandle.searchDomain composes <projectName>.test")
    func searchDomainComposesProjectDotTest() {
        let handle = SidecarHandle(
            projectName: "myproject",
            containerName: "myproject-compose-dns",
            configRoot: FilePath("/tmp/cc/myproject/dns"),
            perNetworkIPs: [:]
        )
        #expect(handle.searchDomain == "myproject.test")
    }

    @Test("SidecarHandle round-trips through JSONEncoder / JSONDecoder")
    func sidecarHandleRoundTripsThroughJSON() throws {
        let original = SidecarHandle(
            projectName: "myproject",
            containerName: "myproject-compose-dns",
            configRoot: FilePath("/Users/test/.container-compose/myproject/dns"),
            perNetworkIPs: [
                "frontend": "10.0.0.10",
                "backend": "10.0.0.11",
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(SidecarHandle.self, from: data)

        #expect(decoded.projectName == original.projectName)
        #expect(decoded.containerName == original.containerName)
        #expect(decoded.configRoot == original.configRoot)
        #expect(decoded.perNetworkIPs == original.perNetworkIPs)
    }

    // MARK: - Test fixtures

    /// Project names embed a UUID so parallel tests never share a host
    /// `~/.container-compose/<project>/dns/` directory.
    private func uniqueProjectName() -> String {
        // RFC 1035 labels: alphanumerics + hyphen, no leading/trailing hyphen,
        // 1-63 chars. UUID lowercased + the "p-" prefix satisfies that.
        "p-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            .prefix(20).description
    }

    private static func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), argv.indices.contains(index + 1) else {
            return nil
        }
        return argv[index + 1]
    }

    private static func values(after flag: String, in argv: [String]) -> [String] {
        argv.indices.compactMap { index in
            guard argv[index] == flag, argv.indices.contains(index + 1) else { return nil }
            return argv[index + 1]
        }
    }

    private static func snapshot(
        id: String,
        networks: [(name: String, ip: String)]
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
            environment: []
        )
        let configuration = ContainerConfiguration(id: id, image: image, process: process)
        let attachments = try networks.map { network -> ContainerResource.Attachment in
            ContainerResource.Attachment(
                network: network.name,
                hostname: id,
                ipv4Address: try CIDRv4("\(network.ip)/24"),
                ipv4Gateway: try IPv4Address(network.ip),
                ipv6Address: nil,
                macAddress: nil
            )
        }
        return ContainerSnapshot(
            configuration: configuration,
            status: .running,
            networks: attachments
        )
    }
}

// MARK: - SidecarFakeProvider

/// Minimal `ContainerClientProvider` for sidecar tests. Returns a single
/// pre-built snapshot from `get(id:)` (matching id only); throws "not found"
/// otherwise. All other methods return harmless empty values — the sidecar
/// exercise never calls them.
private actor SidecarFakeProvider: ContainerClientProvider {
    private let snapshot: ContainerSnapshot?

    init(snapshot: ContainerSnapshot?) {
        self.snapshot = snapshot
    }

    func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> ContainerSnapshot {
        throw notFound(id: id)
    }

    func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] { [] }

    func get(id: String) async throws -> ContainerSnapshot {
        guard let snapshot, snapshot.id == id else {
            throw notFound(id: id)
        }
        return snapshot
    }

    func stop(id: String, opts: ContainerStopOptions) async throws {}
    func delete(id: String, force: Bool) async throws {}
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
            domain: "SidecarFakeProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no resource '\(id)' (sidecar test fake)"]
        )
    }
}
