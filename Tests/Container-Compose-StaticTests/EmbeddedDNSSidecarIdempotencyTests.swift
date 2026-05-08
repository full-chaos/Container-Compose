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

// CHAOS-1490 + CHAOS-1493 regression coverage.
//
// CHAOS-1490: `EmbeddedDNSSidecar.start()` previously issued `container run
// --name <project>-compose-dns` without any pre-flight existence check. A
// sidecar orphaned by a prior failed `up` caused every subsequent `up` to fail
// with `container with id <name> already exists`.
//
// CHAOS-1493: the original CHAOS-1490 fix unconditionally recreated the sidecar
// every `up`, which broke DNS for services adopted by CHAOS-1492 (their
// `/etc/resolv.conf` was burned in at original launch). The contract was
// upgraded to probe-then-ADOPT-or-replace: a sidecar is adopted when its image
// matches `EmbeddedDNSSidecar.image` AND it is `.running` AND every expected
// network is attached. Diverging or non-running sidecars still get
// stop+delete+recreate so orphan-recovery still works.
//
// Branches pinned here:
//   1. Matching sidecar (running + image match + all networks) is ADOPTED
//      with no stop/delete/run argv (CHAOS-1493).
//   2. Diverging image triggers stop+delete+recreate (CHAOS-1490 orphan fix).
//   3. Stopped status triggers stop+delete+recreate.
//   4. Missing network attachment triggers stop+delete+recreate.
//   5. No pre-existing sidecar means no stop/delete (no behavior change for
//      the happy path).
//   6. Zone file persists across re-runs — not wiped if already on disk
//      (CHAOS-1493 zone-no-wipe, Oracle Q1 #2).

import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite("Embedded DNS sidecar idempotency (CHAOS-1490 + CHAOS-1493)")
struct EmbeddedDNSSidecarIdempotencyTests {

    // MARK: - Adoption branch (CHAOS-1493)

    @Test("start adopts a matching pre-existing sidecar with no stop/delete/run")
    func startAdoptsMatchingSidecar() async throws {
        let project = uniqueProjectName()
        let containerName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let runner = RecordingRunner()

        // Matching: image == EmbeddedDNSSidecar.image (default), .running, every
        // expected network attached. The probe finds it and adoptIfMatching
        // returns a SidecarHandle with `wasAdopted: true`.
        let provider = IdempotencyFakeProvider(
            seededSnapshot: try Self.snapshot(
                id: containerName,
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

        let entries = await provider.recordedEntries()
        let stopCount = entries.filter {
            if case .stop = $0 { return true }
            return false
        }.count
        let deleteCount = entries.filter {
            if case .delete = $0 { return true }
            return false
        }.count
        #expect(stopCount == 0, "adopted sidecar must NOT be stopped")
        #expect(deleteCount == 0, "adopted sidecar must NOT be deleted")

        // No `container run` argv: start returned without launching.
        let runArgvs = await runner.runArgvs()
        #expect(runArgvs.isEmpty, "adopted sidecar must NOT trigger container run; got \(runArgvs)")

        // Handle must reflect adoption + carry the snapshot's per-network IPs.
        #expect(handle.wasAdopted == true, "adopted handle must carry wasAdopted=true")
        #expect(handle.perNetworkIPs == ["primary": "10.0.0.42"])
    }

    // MARK: - Recreate branches (CHAOS-1490 + CHAOS-1493 divergence cases)

    @Test("start recreates an existing sidecar whose image diverges from EmbeddedDNSSidecar.image")
    func startRecreatesOnImageDivergence() async throws {
        let project = uniqueProjectName()
        let containerName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let runner = RecordingRunner()

        // Wrong image triggers the recreate path; post-start poll uses the
        // correctly-imaged snapshot so waitForRunningSidecar terminates.
        let provider = IdempotencyFakeProvider(
            seededSnapshot: try Self.snapshot(
                id: containerName,
                networks: [(name: "primary", ip: "10.0.0.42")],
                imageReference: "docker.io/coredns/coredns:1.10.0"
            ),
            postStartSnapshot: try Self.snapshot(
                id: containerName,
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

        let entries = await provider.recordedEntries()
        let getIdx = try #require(entries.firstIndex(where: {
            if case .get(let id) = $0 { return id == containerName }
            return false
        }))
        let stopIdx = try #require(entries.firstIndex(where: {
            if case .stop(let id) = $0 { return id == containerName }
            return false
        }))
        let deleteIdx = try #require(entries.firstIndex(where: {
            if case .delete(let id, _) = $0 { return id == containerName }
            return false
        }))
        #expect(getIdx < stopIdx, "probe must precede stop")
        #expect(stopIdx < deleteIdx, "stop must precede delete")

        let runArgvs = await runner.runArgvs()
        #expect(runArgvs.count == 1, "recreated sidecar must trigger one container run")
        let argv = try #require(runArgvs.first)
        #expect(Array(argv.prefix(6)) == [
            "container", "run", "--rm", "-d", "--name", containerName,
        ])
        #expect(handle.wasAdopted == false, "recreated handle must carry wasAdopted=false")
    }

    @Test("start recreates an existing sidecar that is not running")
    func startRecreatesWhenStatusIsStopped() async throws {
        let project = uniqueProjectName()
        let containerName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let runner = RecordingRunner()

        let provider = IdempotencyFakeProvider(
            seededSnapshot: try Self.snapshot(
                id: containerName,
                networks: [(name: "primary", ip: "10.0.0.42")],
                status: .stopped
            ),
            postStartSnapshot: try Self.snapshot(
                id: containerName,
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

        let entries = await provider.recordedEntries()
        let didStop = entries.contains { if case .stop = $0 { return true }; return false }
        let didDelete = entries.contains { if case .delete = $0 { return true }; return false }
        #expect(didStop, "stopped sidecar must be stopped before relaunch")
        #expect(didDelete, "stopped sidecar must be deleted before relaunch")

        let runArgvs = await runner.runArgvs()
        #expect(runArgvs.count == 1, "non-running sidecar must trigger relaunch")
        #expect(handle.wasAdopted == false)
    }

    @Test("start recreates an existing sidecar missing one of the expected networks")
    func startRecreatesWhenNetworkAttachmentMissing() async throws {
        let project = uniqueProjectName()
        let containerName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let runner = RecordingRunner()

        // Seed: only `primary` attached. Expected: `primary` AND `secondary`.
        // adoptIfMatching's allSatisfy guard fails; recreate path runs.
        // Post-start poll observes both networks so waitForRunningSidecar terminates.
        let provider = IdempotencyFakeProvider(
            seededSnapshot: try Self.snapshot(
                id: containerName,
                networks: [(name: "primary", ip: "10.0.0.42")]
            ),
            postStartSnapshot: try Self.snapshot(
                id: containerName,
                networks: [
                    (name: "primary", ip: "10.0.0.42"),
                    (name: "secondary", ip: "10.0.0.43"),
                ]
            )
        )

        let handle = try await EmbeddedDNSSidecar.start(
            projectName: project,
            networkNames: ["primary", "secondary"],
            runner: runner,
            clientProvider: provider
        )
        defer { try? FileManager.default.removeItem(atPath: handle.configRoot.string) }

        let entries = await provider.recordedEntries()
        let didStop = entries.contains { if case .stop = $0 { return true }; return false }
        let didDelete = entries.contains { if case .delete = $0 { return true }; return false }
        #expect(didStop, "sidecar missing a network must be stopped before relaunch")
        #expect(didDelete, "sidecar missing a network must be deleted before relaunch")

        let runArgvs = await runner.runArgvs()
        #expect(runArgvs.count == 1, "sidecar missing a network must trigger relaunch")
        #expect(handle.wasAdopted == false)
    }

    // MARK: - No-replace branch

    @Test("start does NOT call stop or delete when no sidecar exists")
    func startSkipsStopDeleteWhenNoSidecarExists() async throws {
        let project = uniqueProjectName()
        let containerName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let runner = RecordingRunner()

        // No seeded snapshot for the sidecar's container name. The probe
        // throws (recorded fake's "not found" path); start should fall through
        // to the launch + post-start-poll. We seed the post-start snapshot
        // separately so `waitForRunningSidecar` succeeds.
        let provider = IdempotencyFakeProvider(
            seededSnapshot: nil,
            postStartSnapshot: try Self.snapshot(
                id: containerName,
                networks: [(name: "primary", ip: "10.0.0.5")]
            )
        )

        let handle = try await EmbeddedDNSSidecar.start(
            projectName: project,
            networkNames: ["primary"],
            runner: runner,
            clientProvider: provider
        )
        defer { try? FileManager.default.removeItem(atPath: handle.configRoot.string) }

        let entries = await provider.recordedEntries()
        let stopCount = entries.filter {
            if case .stop = $0 { return true }
            return false
        }.count
        let deleteCount = entries.filter {
            if case .delete = $0 { return true }
            return false
        }.count

        #expect(stopCount == 0, "no stop when no pre-existing sidecar")
        #expect(deleteCount == 0, "no delete when no pre-existing sidecar")

        // Standard run argv still emitted.
        let runArgvs = await runner.runArgvs()
        #expect(runArgvs.count == 1)
    }

    // MARK: - Zone-no-wipe branch (CHAOS-1493, Oracle Q1 #2)

    @Test("start preserves an existing on-disk zone file (does not wipe records of adopted services)")
    func startPreservesExistingZoneFile() async throws {
        let project = uniqueProjectName()
        let containerName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let configRoot = EmbeddedDNSSidecar.configRootPath(for: project)
        let zonesDir = EmbeddedDNSSidecar.zonesDirectory(within: configRoot)
        let zonePath = EmbeddedDNSSidecar.zoneFilePath(within: configRoot, projectName: project)
        let corefilePath = EmbeddedDNSSidecar.corefilePath(within: configRoot)

        // Pre-create the zone file with sentinel content. start() must NOT
        // overwrite this with an empty zone, regardless of adopt vs recreate.
        try FileManager.default.createDirectory(
            atPath: zonesDir.string,
            withIntermediateDirectories: true
        )
        let sentinel = "; SENTINEL — pre-existing zone content for CHAOS-1493 test\n"
        try sentinel.write(toFile: zonePath.string, atomically: true, encoding: .utf8)
        let preExistingCorefile = "; SENTINEL — pre-existing Corefile content\n"
        try preExistingCorefile.write(toFile: corefilePath.string, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: configRoot.string) }

        let provider = IdempotencyFakeProvider(
            seededSnapshot: nil,
            postStartSnapshot: try Self.snapshot(
                id: containerName,
                networks: [(name: "primary", ip: "10.0.0.5")]
            )
        )
        let runner = RecordingRunner()

        _ = try await EmbeddedDNSSidecar.start(
            projectName: project,
            networkNames: ["primary"],
            runner: runner,
            clientProvider: provider
        )

        let zoneAfter = try String(contentsOfFile: zonePath.string, encoding: .utf8)
        #expect(zoneAfter == sentinel, "zone file must not be wiped")
        let corefileAfter = try String(contentsOfFile: corefilePath.string, encoding: .utf8)
        #expect(corefileAfter == preExistingCorefile, "Corefile must not be wiped")
    }

    @Test("start writes initial zone + Corefile when neither exists on disk")
    func startWritesInitialZoneWhenAbsent() async throws {
        let project = uniqueProjectName()
        let containerName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let configRoot = EmbeddedDNSSidecar.configRootPath(for: project)
        let zonePath = EmbeddedDNSSidecar.zoneFilePath(within: configRoot, projectName: project)
        let corefilePath = EmbeddedDNSSidecar.corefilePath(within: configRoot)
        // Ensure clean state — no pre-existing files.
        try? FileManager.default.removeItem(atPath: configRoot.string)
        defer { try? FileManager.default.removeItem(atPath: configRoot.string) }

        let provider = IdempotencyFakeProvider(
            seededSnapshot: nil,
            postStartSnapshot: try Self.snapshot(
                id: containerName,
                networks: [(name: "primary", ip: "10.0.0.5")]
            )
        )
        let runner = RecordingRunner()

        _ = try await EmbeddedDNSSidecar.start(
            projectName: project,
            networkNames: ["primary"],
            runner: runner,
            clientProvider: provider
        )

        // Both files must exist now and have the expected initial content.
        #expect(FileManager.default.fileExists(atPath: zonePath.string),
                "zone file must be created on first start")
        #expect(FileManager.default.fileExists(atPath: corefilePath.string),
                "Corefile must be created on first start")
        let corefile = try String(contentsOfFile: corefilePath.string, encoding: .utf8)
        #expect(corefile.contains("reload 5s"), "Corefile content must be the CoreDNS template")
    }

    // MARK: - Test fixtures

    /// Project names embed a UUID so parallel tests never share a host
    /// `~/.container-compose/<project>/dns/` directory. `cc-test-` prefix marks
    /// the fixture origin per repo convention.
    private func uniqueProjectName() -> String {
        // RFC 1035 labels: alphanumerics + hyphen, no leading/trailing hyphen,
        // 1-63 chars. UUID lowercased + the "cc-test-" prefix satisfies that.
        "cc-test-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            .prefix(16).description
    }

    private static func snapshot(
        id: String,
        networks: [(name: String, ip: String)],
        imageReference: String = EmbeddedDNSSidecar.image,
        status: RuntimeStatus = .running,
        labels: [String: String] = [:]
    ) throws -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            size: 0
        )
        let image = ImageDescription(reference: imageReference, descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "/coredns",
            arguments: ["-conf", "/etc/coredns/Corefile"],
            environment: [],
            workingDirectory: "/"
        )
        var configuration = ContainerConfiguration(id: id, image: image, process: process)
        configuration.labels = labels
        let attachments = try networks.map { entry -> ContainerResource.Attachment in
            ContainerResource.Attachment(
                network: entry.name,
                hostname: id,
                ipv4Address: try CIDRv4("\(entry.ip)/24"),
                ipv4Gateway: try IPv4Address("10.0.0.1"),
                ipv6Address: nil,
                macAddress: nil
            )
        }
        return ContainerSnapshot(
            configuration: configuration,
            status: status,
            networks: attachments
        )
    }
}

// MARK: - IdempotencyFakeProvider

/// Recording-aware `ContainerClientProvider` for sidecar idempotency tests.
///
/// Models the two `get(id:)` phases of `EmbeddedDNSSidecar.start` separately:
///   - `seededSnapshot`: returned by the FIRST `get(id:)` call only (the probe).
///     Pass nil to model "no pre-existing sidecar".
///   - `postStartSnapshot`: returned by SUBSEQUENT `get(id:)` calls (the
///     `waitForRunningSidecar` poll). Pass nil to default to `seededSnapshot`.
///
/// All `get`/`stop`/`delete` calls are recorded in time order so tests can
/// assert the operation sequence. `RecordingContainerClientProvider` was
/// considered but its `get(id:)` unconditionally throws — extending it would
/// ripple across unrelated tests, so this fake stays local per the lead's
/// "keep test plumbing local" guidance.
private actor IdempotencyFakeProvider: ContainerClientProvider {

    enum Entry: Sendable, Equatable {
        case get(id: String)
        case stop(id: String)
        case delete(id: String, force: Bool)
    }

    private var entries: [Entry] = []
    private var probeCallCount = 0
    private let seededSnapshot: ContainerSnapshot?
    private let postStartSnapshot: ContainerSnapshot?

    init(seededSnapshot: ContainerSnapshot?, postStartSnapshot: ContainerSnapshot? = nil) {
        self.seededSnapshot = seededSnapshot
        // Default the post-start poll snapshot to the seeded one. The replace
        // branch wants the same snapshot to satisfy both phases (probe sees it,
        // then waitForRunningSidecar still sees it after the relaunch).
        self.postStartSnapshot = postStartSnapshot ?? seededSnapshot
    }

    func recordedEntries() -> [Entry] { entries }

    // MARK: - ContainerClientProvider

    func get(id: String) async throws -> ContainerSnapshot {
        entries.append(.get(id: id))
        // First call is the pre-flight probe in `start`. Use the seeded slot.
        // All subsequent calls are post-launch polls in `waitForRunningSidecar`.
        // Use the post-start slot.
        let isProbe = probeCallCount == 0
        probeCallCount += 1
        let candidate = isProbe ? seededSnapshot : postStartSnapshot
        guard let snapshot = candidate, snapshot.id == id else {
            throw notFound(id: id)
        }
        return snapshot
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
            domain: "IdempotencyFakeProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no resource '\(id)' (idempotency test fake)"]
        )
    }
}
