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

// CHAOS-1475 Phase 11.F — embedded CoreDNS sidecar.
//
// Per-project CoreDNS sidecar container. v1 emits ONE zone per project; aliases
// are project-wide. Per-network alias split is a v2 ticket.
//
// This file owns lifecycle (start/refreshZone/stop) and argv shape. Zone/Corefile
// content is delegated to `CoreDNSConfig` (separate module member).

import ContainerAPIClient
import ContainerResource
import Darwin
import Foundation
import SystemPackage

// MARK: - SidecarHandle

/// Handle returned by `EmbeddedDNSSidecar.start(...)`. Carries the projection
/// of state that downstream callers (`ComposeUp` per-service `--dns` injection,
/// `ComposeDown` teardown, `refreshZone`) need to operate without re-deriving
/// paths or re-querying the runtime.
public struct SidecarHandle: Sendable, Codable {
    /// The compose project name (used to build the zone domain `<project>.test`).
    public let projectName: String

    /// Container name in the runtime registry: `<project>-compose-dns`.
    public let containerName: String

    /// Host config root: `~/.container-compose/<project>/dns/`. Bind-mounted
    /// into the sidecar at `/etc/coredns` (read-only). The `Corefile` lives
    /// directly inside; per-project zone files live under `zones/`.
    public let configRoot: FilePath

    /// Sidecar IP per project network. `key = network name`,
    /// `value = sidecar IPv4 on that network`. Callers inject these into other
    /// services as `--dns <ip>` per attachment.
    public let perNetworkIPs: [String: String]

    /// CHAOS-1493: true when this handle was reconstructed from an existing
    /// running sidecar (probe-then-adopt path), false when `start(...)` actually
    /// launched the sidecar in this process. Drives asymmetric teardown in
    /// `ComposeUp.run()`'s catch block: an adopted sidecar belongs to whoever
    /// originally launched it (it predates this `up`), so tearing it down on a
    /// mid-flight failure would kill DNS for ANY services from prior runs that
    /// are still legitimately running and not in this `up`'s service set.
    public let wasAdopted: Bool

    public init(
        projectName: String,
        containerName: String,
        configRoot: FilePath,
        perNetworkIPs: [String: String],
        wasAdopted: Bool = false
    ) {
        self.projectName = projectName
        self.containerName = containerName
        self.configRoot = configRoot
        self.perNetworkIPs = perNetworkIPs
        self.wasAdopted = wasAdopted
    }

    /// Domain served by the sidecar for this project: `<dns-label>.test`,
    /// where `<dns-label>` is the DNS-safe transformation of `projectName`
    /// (CHAOS-1475: project names with `_`/`.`/uppercase no longer hard-fail).
    /// Compose injects this as `--dns-search` on every project container so it
    /// matches the zone CoreDNS actually serves.
    public var searchDomain: String {
        // Fallback to a raw form is unreachable under normal operation: every
        // path that constructs a SidecarHandle (`start(...)`, `forCleanup(...)`)
        // has either already validated the project name or accepts whatever
        // string the caller supplies for cleanup-only use. The fallback exists
        // so this property remains non-throwing.
        (try? CoreDNSConfig.dnsZoneLabel(for: projectName)).map { "\($0).test" }
            ?? "\(projectName).test"
    }

    /// Synthesize a handle for cleanup paths (`ComposeDown`) where no `start()`
    /// call has run in the current process and there is therefore no live
    /// `perNetworkIPs` map. Container name + config root are derived purely
    /// from `projectName`, matching what `start(...)` would have produced.
    public static func forCleanup(
        projectName: String,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SidecarHandle {
        let configRoot = FilePath(
            homeDirectoryURL
                .appendingPathComponent(".container-compose", isDirectory: true)
                .appendingPathComponent(projectName, isDirectory: true)
                .appendingPathComponent("dns", isDirectory: true)
                .path(percentEncoded: false)
        ).lexicallyNormalized()
        return SidecarHandle(
            projectName: projectName,
            containerName: EmbeddedDNSSidecar.sidecarContainerName(for: projectName),
            configRoot: configRoot,
            perNetworkIPs: [:]
        )
    }
}

// MARK: - Errors

public enum EmbeddedDNSSidecarError: Error, Equatable, CustomStringConvertible {
    case noNetworks(project: String)
    case commandFailed(argv: [String], exitCode: Int32)
    case timedOut(name: String, networks: [String])
    case missingNetworkIPs(name: String, missing: [String])
    case atomicWriteFailed(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .noNetworks(let project):
            return "Cannot start embedded DNS sidecar for project '\(project)' without project networks"
        case .commandFailed(let argv, let exitCode):
            return "Embedded DNS sidecar command failed with exit \(exitCode): \(argv.joined(separator: " "))"
        case .timedOut(let name, let networks):
            return "Timed out waiting for embedded DNS sidecar '\(name)' on networks: \(networks.joined(separator: ", "))"
        case .missingNetworkIPs(let name, let missing):
            return "Embedded DNS sidecar '\(name)' missing IPs for networks: \(missing.joined(separator: ", "))"
        case .atomicWriteFailed(let path, let errno):
            return "Atomic write failed for '\(path)' with errno \(errno)"
        }
    }
}

// MARK: - EmbeddedDNSSidecar

public enum EmbeddedDNSSidecar {
    /// CoreDNS image — pinned to a known-good tag. Already pulled locally per
    /// the CHAOS-1475 setup; no platform-specific suffix because Apple
    /// `container` selects a matching variant from the manifest list.
    public static let image = "docker.io/coredns/coredns:1.11.1"

    /// Provision and launch the per-project CoreDNS sidecar.
    ///
    /// 1. CHAOS-1490: probe the runtime for a pre-existing sidecar with the same
    ///    name (e.g. one orphaned by a previous failed `up`); if found, stop +
    ///    delete it before relaunching so apple/container's `container run` does
    ///    not error out with `already exists`. Mirrors `ComposeUp.stopOldStuff`.
    /// 2. Computes `configRoot = ~/.container-compose/<project>/dns/` and
    ///    `zones/` underneath.
    /// 3. Writes the initial `Corefile` and an empty `<project>.zone` via
    ///    `CoreDNSConfig`. Both writes are atomic (tmp + rename).
    /// 4. Issues the `container run` argv via the supplied `runner`.
    /// 5. Polls `clientProvider.get(id:)` until the snapshot is `.running`
    ///    AND every requested network has an attachment (30 s timeout, 0.5 s
    ///    poll — matches `ComposeUp.waitUntilServiceIsRunning` cadence).
    public static func start(
        projectName: String,
        networkNames: [String],
        runner: any RunCommandRunner,
        clientProvider: any ContainerClientProvider
    ) async throws -> SidecarHandle {
        let networks = networkNames.uniquedPreservingOrder()
        guard !networks.isEmpty else {
            throw EmbeddedDNSSidecarError.noNetworks(project: projectName)
        }

        let containerName = sidecarContainerName(for: projectName)
        let configRoot = configRootPath(for: projectName)

        // CHAOS-1490 / CHAOS-1493: probe-then-ADOPT-or-replace.
        //
        // CHAOS-1490 originally added unconditional stop+delete+recreate to recover
        // from sidecars orphaned by a previous failed `up`. CHAOS-1492's
        // adoption-by-default keeps service containers alive across `up`
        // invocations, but their `/etc/resolv.conf` is set at original launch via
        // `--dns <ip>` argv — there is no way to inject a new DNS IP into a running
        // container. So if CHAOS-1490 recreates the sidecar with a new IP, adopted
        // services point at a dead resolver. CHAOS-1493 closes this by adopting the
        // existing sidecar when its config matches what we'd launch (image + every
        // expected network present + running), keeping the IP stable. Diverging or
        // non-running sidecars still get stop+delete+recreate via the orphan-recovery
        // path that mirrors `ComposeUp.stopOldStuff`.
        if let existing = try? await clientProvider.get(id: containerName) {
            if let adopted = adoptIfMatching(
                existing: existing,
                projectName: projectName,
                containerName: containerName,
                configRoot: configRoot,
                expectedNetworks: networks
            ) {
                print("Adopting existing sidecar '\(containerName)'")
                // Return early: the on-disk Corefile + zone files are correct for
                // currently-adopted services. Rewriting the empty zone here would
                // briefly drop their records before `configService` re-adds them —
                // race risk for downstream resolvers. Skip writes on the adoption path.
                return adopted
            }
            print("Found existing sidecar '\(containerName)' — replacing (spec divergence)")
            do {
                try await clientProvider.stop(id: existing.id, opts: .default)
            } catch {
                print("Error stopping existing sidecar: \(error)")
            }
            do {
                try await clientProvider.delete(id: existing.id, force: false)
            } catch {
                print("Error deleting existing sidecar: \(error)")
            }
        }

        let zonesDir = zonesDirectory(within: configRoot)
        let corefilePath = corefilePath(within: configRoot)
        let zonePath = zoneFilePath(within: configRoot, projectName: projectName)

        try FileManager.default.createDirectory(
            atPath: zonesDir.string,
            withIntermediateDirectories: true
        )

        // CHAOS-1493: only write the empty Corefile/zone when they don't already
        // exist. The host config root persists across sidecar restarts, and the
        // existing zone records are still correct for adopted services until
        // `configService` calls `refreshZone` per-service. Unconditionally wiping
        // here causes a transient NXDOMAIN window between sidecar relaunch and
        // `refreshZone` that downstream resolvers can observe (Oracle Q1 #2).
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: corefilePath.string) {
            let corefile = try CoreDNSConfig.makeCorefile(projectName: projectName)
            try writeAtomically(corefile, to: corefilePath)
        }
        if !fileManager.fileExists(atPath: zonePath.string) {
            let initialSerial = Int64(Date().timeIntervalSince1970)
            let emptyZone = try CoreDNSConfig.makeZone(
                projectName: projectName,
                services: [],
                serial: initialSerial
            )
            try writeAtomically(emptyZone, to: zonePath)
        }

        // Launch.
        let argv = runArgv(
            containerName: containerName,
            configRoot: configRoot,
            networks: networks
        )
        let result = try await runner.run(
            RunRequest(kind: .awaitOnly, argv: argv),
            onStdout: nil,
            onStderr: nil
        )
        guard result.exitCode == 0 else {
            throw EmbeddedDNSSidecarError.commandFailed(argv: argv, exitCode: result.exitCode)
        }

        // Wait for running + resolve per-network IPs from snapshot.
        let perNetworkIPs = try await waitForRunningSidecar(
            name: containerName,
            networks: networks,
            clientProvider: clientProvider
        )

        return SidecarHandle(
            projectName: projectName,
            containerName: containerName,
            configRoot: configRoot,
            perNetworkIPs: perNetworkIPs
        )
    }

    /// Regenerate and atomically replace the project's zone file with the
    /// supplied service records. CoreDNS auto-reloads after 5 s
    /// (driven by the `reload 5s` directive baked into the Corefile).
    ///
    /// Serial is derived from `Date().timeIntervalSince1970` so monotonic-
    /// clock callers produce monotonically-increasing serials. The serial is
    /// embedded in the SOA record by `CoreDNSConfig.makeZone`.
    public static func refreshZone(
        handle: SidecarHandle,
        services: [CoreDNSConfig.ServiceRecord]
    ) throws {
        let zonePath = zoneFilePath(
            within: handle.configRoot,
            projectName: handle.projectName
        )
        let serial = Int64(Date().timeIntervalSince1970)
        let zone = try CoreDNSConfig.makeZone(
            projectName: handle.projectName,
            services: services,
            serial: serial
        )
        try writeAtomically(zone, to: zonePath)
    }

    /// Stop and delete the sidecar container, then clean up the host config
    /// directory. `container stop` and `container delete` are best-effort —
    /// "not found" is expected (and ignored) when the sidecar already exited
    /// or was never created.
    ///
    /// Set `CONTAINER_COMPOSE_KEEP_DNS_STATE=1` to retain the config root
    /// across runs (useful for debugging zone contents post-mortem).
    public static func stop(handle: SidecarHandle, runner: any RunCommandRunner) async throws {
        try await stop(
            handle: handle,
            runner: runner,
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Test-only entrypoint: takes an explicit environment dictionary so
    /// `CONTAINER_COMPOSE_KEEP_DNS_STATE` behavior can be exercised without
    /// mutating the process-wide env table.
    static func stop(
        handle: SidecarHandle,
        runner: any RunCommandRunner,
        environment: [String: String]
    ) async throws {
        let stopArgv = ["container", "stop", handle.containerName]
        let deleteArgv = ["container", "delete", handle.containerName]
        var firstError: (any Error)?

        for argv in [stopArgv, deleteArgv] {
            do {
                _ = try await runner.run(
                    RunRequest(kind: .awaitOnly, argv: argv),
                    onStdout: nil,
                    onStderr: nil
                )
                // Non-zero exit on stop/delete is treated as "not found" /
                // "already-gone" — best-effort teardown, don't propagate.
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if environment["CONTAINER_COMPOSE_KEEP_DNS_STATE"] != "1" {
            try? FileManager.default.removeItem(atPath: handle.configRoot.string)
        }

        if let firstError {
            throw firstError
        }
    }
}

// MARK: - Internal path / argv / IO helpers

extension EmbeddedDNSSidecar {
    static func sidecarContainerName(for projectName: String) -> String {
        "\(projectName)-compose-dns"
    }

    static func configRootPath(for projectName: String) -> FilePath {
        FilePath(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))
            .pushing(FilePath(".container-compose"))
            .pushing(FilePath(projectName))
            .pushing(FilePath("dns"))
            .lexicallyNormalized()
    }

    static func zonesDirectory(within configRoot: FilePath) -> FilePath {
        configRoot.pushing(FilePath("zones")).lexicallyNormalized()
    }

    static func corefilePath(within configRoot: FilePath) -> FilePath {
        configRoot.pushing(FilePath("Corefile")).lexicallyNormalized()
    }

    static func zoneFilePath(within configRoot: FilePath, projectName: String) -> FilePath {
        zonesDirectory(within: configRoot)
            .pushing(FilePath("\(projectName).zone"))
            .lexicallyNormalized()
    }

    /// Build the `container run` argv for the sidecar. Order matters — tests
    /// pin the position of `--name`, the per-network `--network` flags, and
    /// the trailing image + `-conf` arguments.
    static func runArgv(
        containerName: String,
        configRoot: FilePath,
        networks: [String]
    ) -> [String] {
        var argv = [
            "container", "run",
            "--rm",
            "-d",
            "--name", containerName,
        ]
        for network in networks {
            argv.append(contentsOf: ["--network", network])
        }
        argv.append(contentsOf: [
            "--mount",
            "type=bind,source=\(configRoot.string),target=/etc/coredns,readonly",
            image,
            "-conf", "/etc/coredns/Corefile",
        ])
        return argv
    }

    static func waitForRunningSidecar(
        name: String,
        networks: [String],
        clientProvider: any ContainerClientProvider,
        timeout: TimeInterval = 30,
        interval: TimeInterval = 0.5
    ) async throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        let intervalNanos = UInt64(interval * 1_000_000_000)

        while Date() < deadline {
            guard
                let snapshot = try? await clientProvider.get(id: name),
                snapshot.status == .running
            else {
                try await Task.sleep(nanoseconds: intervalNanos)
                continue
            }

            let ips = perNetworkIPs(from: snapshot, expected: networks)
            if networks.allSatisfy({ ips[$0] != nil }) {
                return ips
            }
            try await Task.sleep(nanoseconds: intervalNanos)
        }

        throw EmbeddedDNSSidecarError.timedOut(name: name, networks: networks)
    }

    /// Project a `ContainerSnapshot` onto a network → sidecar-IP map keyed by
    /// the requested network names. Networks the snapshot doesn't know about
    /// are simply absent from the result.
    static func perNetworkIPs(
        from snapshot: ContainerSnapshot,
        expected: [String]
    ) -> [String: String] {
        let expectedSet = Set(expected)
        var result: [String: String] = [:]
        for attachment in snapshot.networks where expectedSet.contains(attachment.network) {
            result[attachment.network] = attachment.ipv4Address.address.description
        }
        return result
    }

    /// CHAOS-1493: decide whether the existing sidecar can be adopted as-is.
    ///
    /// v1 acceptance criteria:
    ///   - container is `.running`
    ///   - container's image reference matches `EmbeddedDNSSidecar.image`
    ///   - container has an IPv4 attachment for every expected network
    ///
    /// On a hit, returns a `SidecarHandle` reconstructed from the snapshot —
    /// caller returns early without writing config files or relaunching, so the
    /// sidecar's IPs stay stable for already-launched services whose
    /// `/etc/resolv.conf` was burned in at create time.
    ///
    /// On a miss (any criterion fails), returns nil and caller falls through to
    /// stop+delete+recreate.
    private static func adoptIfMatching(
        existing: ContainerSnapshot,
        projectName: String,
        containerName: String,
        configRoot: FilePath,
        expectedNetworks: [String]
    ) -> SidecarHandle? {
        guard existing.status == .running else { return nil }
        guard existing.configuration.image.reference == EmbeddedDNSSidecar.image else { return nil }
        let ips = perNetworkIPs(from: existing, expected: expectedNetworks)
        guard expectedNetworks.allSatisfy({ ips[$0] != nil }) else { return nil }
        return SidecarHandle(
            projectName: projectName,
            containerName: containerName,
            configRoot: configRoot,
            perNetworkIPs: ips,
            wasAdopted: true
        )
    }

    /// Atomic write: write to a sibling `.tmp` file, then `rename(2)` on top
    /// of the destination. Matches the durability contract CoreDNS's
    /// `reload 5s` watcher relies on (the watcher polls inode/mtime and may
    /// observe a half-written file otherwise).
    static func writeAtomically(_ contents: String, to path: FilePath) throws {
        let lastComponentName = path.lastComponent?.string ?? "tmp"
        let tmpName = ".\(lastComponentName).\(UUID().uuidString).tmp"
        let tmpPath = path.removingLastComponent()
            .pushing(FilePath(tmpName))
            .lexicallyNormalized()

        try contents.write(toFile: tmpPath.string, atomically: false, encoding: .utf8)

        if rename(tmpPath.string, path.string) != 0 {
            let captured = errno
            try? FileManager.default.removeItem(atPath: tmpPath.string)
            throw EmbeddedDNSSidecarError.atomicWriteFailed(
                path: path.string,
                errno: captured
            )
        }
    }
}

// MARK: - Local helpers

extension Array where Element: Hashable {
    fileprivate func uniquedPreservingOrder() -> [Element] {
        var seen: Set<Element> = []
        var result: [Element] = []
        for element in self where !seen.contains(element) {
            seen.insert(element)
            result.append(element)
        }
        return result
    }
}
