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

// CHAOS-1475 Phase 11.F MUST-FIX #1 regression coverage.
//
// `ComposeUp.getIPForRunningService` previously returned the per-attachment
// `ipv4Gateway` instead of the container's own `ipv4Address`. That value
// flowed into:
//
//   1. `updateEnvironmentWithServiceIP`, which substitutes service-name
//      references in environment variables, AND
//   2. `updateEmbeddedDNSZone`, which writes A records into the per-project
//      CoreDNS zone via `EmbeddedDNSSidecar.refreshZone(...)`.
//
// The mismatch meant service A records and env-var substitutions could point
// at the network gateway rather than the container itself. These tests pin
// the contract by constructing a snapshot whose `ipv4Address` and
// `ipv4Gateway` are intentionally distinct.

import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite("ComposeUp DNS IP source (CHAOS-1475 MUST-FIX #1)")
struct ComposeUpDNSIPSourceTests {

    @Test("getIPForRunningService returns the per-attachment address, NOT the gateway")
    func getIPReturnsAddressNotGateway() async throws {
        // Sentinel pair where address ≠ gateway. If the production code
        // regresses to `ipv4Gateway`, this returns "192.168.65.1" and the
        // assertion below fails.
        let containerName = "demo-proj-web"
        let address = "192.168.65.42"
        let gateway = "192.168.65.1"

        let snapshot = try Self.snapshot(
            id: containerName,
            address: address,
            gateway: gateway
        )

        var cmd = try ComposeUp.parse([])
        cmd.projectName = "demo-proj"

        let provider = SnapshotReturningProvider(snapshot: snapshot)
        let resolved = try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.getIPForRunningService("web", explicitContainerName: nil)
        }

        #expect(resolved == address, "DNS/env IP must come from ipv4Address, not ipv4Gateway")
        #expect(resolved != gateway, "DNS/env IP must not be the network gateway")
    }

    @Test("getIPForRunningService picks the first attachment's address across multiple networks")
    func getIPMultiNetworkUsesFirstAddress() async throws {
        let containerName = "demo-proj-api"
        let snapshot = try Self.multiNetworkSnapshot(
            id: containerName,
            attachments: [
                (network: "frontend", address: "10.20.0.30", gateway: "10.20.0.1"),
                (network: "backend", address: "10.30.0.30", gateway: "10.30.0.1"),
            ]
        )

        var cmd = try ComposeUp.parse([])
        cmd.projectName = "demo-proj"

        let provider = SnapshotReturningProvider(snapshot: snapshot)
        let resolved = try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.getIPForRunningService("api", explicitContainerName: nil)
        }

        #expect(resolved == "10.20.0.30", "Must return first attachment's address")
        #expect(resolved != "10.20.0.1", "Must not return first attachment's gateway")
        #expect(resolved != "10.30.0.30", "Must not skip to a later attachment")
    }

    // MARK: - Snapshot factories

    private static func snapshot(
        id: String,
        address: String,
        gateway: String
    ) throws -> ContainerSnapshot {
        try multiNetworkSnapshot(
            id: id,
            attachments: [(network: "default", address: address, gateway: gateway)]
        )
    }

    private static func multiNetworkSnapshot(
        id: String,
        attachments: [(network: String, address: String, gateway: String)]
    ) throws -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            size: 0
        )
        let image = ImageDescription(reference: "alpine:latest", descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: []
        )
        let configuration = ContainerConfiguration(id: id, image: image, process: process)
        let resourceAttachments = try attachments.map { entry -> ContainerResource.Attachment in
            ContainerResource.Attachment(
                network: entry.network,
                hostname: id,
                ipv4Address: try CIDRv4("\(entry.address)/24"),
                ipv4Gateway: try IPv4Address(entry.gateway),
                ipv6Address: nil,
                macAddress: nil
            )
        }
        return ContainerSnapshot(
            configuration: configuration,
            status: .running,
            networks: resourceAttachments
        )
    }
}

// MARK: - SnapshotReturningProvider

/// Minimal `ContainerClientProvider` that returns a single pre-built snapshot
/// from `get(id:)` for a matching id and throws "not found" otherwise. Mirrors
/// the `SidecarFakeProvider` shape in `EmbeddedDNSSidecarArgvTests` but kept
/// local so the two test files can evolve independently.
private actor SnapshotReturningProvider: ContainerClientProvider {
    private let snapshot: ContainerSnapshot

    init(snapshot: ContainerSnapshot) {
        self.snapshot = snapshot
    }

    func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> ContainerSnapshot {
        throw notFound(id: id)
    }

    func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] { [] }

    func get(id: String) async throws -> ContainerSnapshot {
        guard snapshot.id == id else {
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
            domain: "SnapshotReturningProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no resource '\(id)' (regression-test fake)"]
        )
    }
}
