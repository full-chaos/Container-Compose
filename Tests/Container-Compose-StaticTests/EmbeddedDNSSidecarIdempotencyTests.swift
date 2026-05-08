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

// CHAOS-1490 regression coverage.
//
// `EmbeddedDNSSidecar.start()` previously issued `container run --name
// <project>-compose-dns` without any pre-flight existence check. A sidecar
// orphaned by a prior failed `up` (the `--rm` flag never fired because the
// parent process aborted) caused every subsequent `up` to fail with
// `container with id <name> already exists`. The contract pinned here mirrors
// `ComposeUp.stopOldStuff`: probe `clientProvider.get(id:)`, then stop +
// delete the existing container before relaunching.
//
// Two branches are pinned:
//   1. Pre-existing sidecar is gracefully replaced (get → stop → delete →
//      run argv emitted).
//   2. No pre-existing sidecar means no stop/delete is issued (no behavior
//      change for the happy path).

import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite("Embedded DNS sidecar idempotency (CHAOS-1490)")
struct EmbeddedDNSSidecarIdempotencyTests {

    // MARK: - Replace branch

    @Test("start replaces a pre-existing sidecar via stop + delete before relaunching")
    func startReplacesPreExistingSidecar() async throws {
        let project = uniqueProjectName()
        let containerName = EmbeddedDNSSidecar.sidecarContainerName(for: project)
        let runner = RecordingRunner()

        // Seed a snapshot for the sidecar's container name so the probe hits.
        // The post-start poll (`waitForRunningSidecar`) also observes the same
        // snapshot — it only requires `.running` status + a per-network IP, so
        // the seeded snapshot serves both phases.
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

        // Order: get → stop → delete → (subsequent gets from the post-start poll
        // do not matter for this assertion).
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

        // After stop+delete, the standard `container run` argv must still be
        // emitted (i.e. start did not bail out).
        let runArgvs = await runner.runArgvs()
        #expect(runArgvs.count == 1)
        let argv = try #require(runArgvs.first)
        #expect(Array(argv.prefix(6)) == [
            "container", "run", "--rm", "-d", "--name", containerName,
        ])
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
        networks: [(name: String, ip: String)]
    ) throws -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            size: 0
        )
        let image = ImageDescription(reference: "docker.io/coredns/coredns:1.11.1", descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "/coredns",
            arguments: ["-conf", "/etc/coredns/Corefile"],
            environment: [],
            workingDirectory: "/"
        )
        let configuration = ContainerConfiguration(id: id, image: image, process: process)
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
            status: .running,
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
