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

// CHAOS-1490 regression coverage for the second half of the fix.
//
// `ComposeUp.run()` previously had no `defer`/`catch` around the body that
// follows `EmbeddedDNSSidecar.start(...)`. A wait timeout, image pull failure,
// or any other error after sidecar launch would propagate out without tearing
// down the sidecar. Combined with the `--rm` flag only firing on clean exit,
// every failed `up` orphaned the sidecar and blocked the next `up`.
//
// Contract pinned here: when a service step throws AFTER the sidecar has been
// successfully launched, `ComposeUp.run()` must (a) emit `container stop`
// followed by `container delete` for the sidecar via the `RunCommandRunner`
// seam (matches `EmbeddedDNSSidecar.stop`'s argv shape), then (b) rethrow the
// original error.

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

@Suite("ComposeUp DNS sidecar teardown on failure (CHAOS-1490)")
struct ComposeUpSidecarTeardownTests {

    @Test("up tears down DNS sidecar when an image pull failure aborts a service start")
    func upTearsDownSidecarOnServiceStartFailure() async throws {
        // Project name is unique so the sidecar config root under
        // ~/.container-compose/<project>/dns/ does not collide between runs.
        let project = uniqueProjectName()
        let sidecarName = EmbeddedDNSSidecar.sidecarContainerName(for: project)

        // Minimal fixture: one network (so sidecar fires) + one service with
        // an image reference (so pullImage runs and can be made to throw).
        let yaml = """
            name: \(project)
            services:
              app:
                image: alpine:latest
                networks:
                  - default
            networks:
              default:
                driver: bridge
            """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = RecordingRunner()
        // Force ImagePull to throw → resolveServiceImage → configService propagates
        // the error up to ComposeUp.run()'s services loop, which now sits inside
        // the do-catch added by this PR.
        await runner.stubThrow(
            swiftAPIName: "ImagePull",
            error: NSError(
                domain: "ComposeUpSidecarTeardownTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "stub: image pull blew up"]
            )
        )

        // Provider returns a running snapshot for the sidecar's container name
        // (so `EmbeddedDNSSidecar.start`'s post-launch `waitForRunningSidecar`
        // loop terminates) and throws "not found" for everything else (so
        // `stopOldStuff`'s probe of the service container is a no-op and
        // `setupNetwork`'s `networkGet` falls through to create).
        let provider = SidecarRunningProvider(
            runningSnapshot: try Self.snapshot(
                id: sidecarName,
                networkName: "default",
                ip: "10.0.0.42"
            )
        )

        // --detach short-circuits waitForever (though the throw fires first).
        let runError: (any Error)? = await RunnerEnvironment.$current.withValue(runner) { @Sendable in
            await ContainerClientEnvironment.$current.withValue(provider) { @Sendable in
                do {
                    var cmd = try ComposeUp.parse(["--detach", "-f", compose.path])
                    try await cmd.run()
                    return nil
                } catch {
                    return error
                }
            }
        }

        #expect(runError != nil, "run() must rethrow the ImagePull failure")

        // Teardown must issue `container stop <sidecar>` then `container delete <sidecar>`
        // via the runner seam (matches EmbeddedDNSSidecar.stop's argv shape).
        let argvs = await runner.argvs()

        let stopIdx = try #require(
            argvs.firstIndex(of: ["container", "stop", sidecarName]),
            "expected sidecar teardown to issue 'container stop \(sidecarName)'"
        )
        let deleteIdx = try #require(
            argvs.firstIndex(of: ["container", "delete", sidecarName]),
            "expected sidecar teardown to issue 'container delete \(sidecarName)'"
        )
        #expect(stopIdx < deleteIdx, "stop must precede delete (mirrors stopOldStuff order)")

        // Sanity: the sidecar's `container run` argv was emitted before the
        // teardown, confirming start() actually launched before the failure.
        let sidecarRunIdx = try #require(
            argvs.firstIndex(where: { argv in
                argv.starts(with: ["container", "run"]) &&
                    argv.contains("--name") &&
                    argv.contains(sidecarName)
            }),
            "expected sidecar 'container run' argv before teardown"
        )
        #expect(sidecarRunIdx < stopIdx, "sidecar must have been launched before teardown fires")
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

    private func writeTempCompose(_ yaml: String) throws -> (dir: URL, compose: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let compose = dir.appendingPathComponent("docker-compose.yaml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)
        return (dir, compose)
    }

    private static func snapshot(
        id: String,
        networkName: String,
        ip: String
    ) throws -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            size: 0
        )
        // CHAOS-1493: non-matching image so the new probe-then-ADOPT-or-replace
        // logic rejects adoption (wasAdopted=false) and the catch block tears the
        // sidecar down on failure. With a matching image, the sidecar would be
        // adopted (wasAdopted=true) and the catch correctly leaves it alone, but
        // this test verifies the teardown contract for sidecars launched by
        // THIS `up` — not for adopted ones.
        let image = ImageDescription(reference: "docker.io/coredns/coredns:1.10.0", descriptor: descriptor)
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
}

// MARK: - SidecarRunningProvider

/// Minimal `ContainerClientProvider` that returns one running snapshot for the
/// sidecar's container id and "not found" for everything else. Kept local per
/// the lead's "test plumbing local" guidance — `RecordingContainerClientProvider`
/// always throws on `get(id:)` so it cannot satisfy `EmbeddedDNSSidecar.start`'s
/// post-launch `waitForRunningSidecar` poll on its own.
private struct SidecarRunningProvider: ContainerClientProvider {
    let runningSnapshot: ContainerSnapshot

    func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> ContainerSnapshot {
        throw notFound(id: id)
    }

    func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] { [] }

    func get(id: String) async throws -> ContainerSnapshot {
        guard runningSnapshot.id == id else {
            throw notFound(id: id)
        }
        return runningSnapshot
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
            domain: "SidecarRunningProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no resource '\(id)' (sidecar teardown test fake)"]
        )
    }
}
