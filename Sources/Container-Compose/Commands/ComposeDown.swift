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
//  ComposeDown.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/19/25.
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import SystemPackage
import Yams

public struct ComposeDown: AsyncParsableCommand, ComposeCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "down",
        abstract: "Stop containers with compose"
    )

    @Argument(help: "Specify the services to stop")
    var services: [String] = []

    @Flag(
        name: [.customShort("v"), .customLong("volumes")],
        help: "Remove named volumes declared in the compose file. On partial down, only volumes exclusive to the targeted services are removed; volumes shared with sibling services outside the target are kept."
    )
    var removeVolumes: Bool = false

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @Option(name: .customLong("cwd"), help: "Host working directory for locating the Compose file")
    var hostCwd: String?

    @OptionGroup
    var projectFlags: ProjectFlags

    var cwd: String { hostCwd ?? FileManager.default.currentDirectoryPath }

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    private var fileManager: FileManager { FileManager.default }
    private var projectName: String?

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()
        let resolvedName = resolveProjectName(for: dockerCompose)
        projectName = resolvedName
        let services = try Array(filterServices(
            dockerCompose,
            profilesArg: profile,
            servicesArg: services
        ).reversed())

        // CHAOS-1445: match `docker compose down` semantics. Containers and
        // project-declared networks are torn down on every `down` (the
        // ordering matters — `Application.NetworkDelete` refuses to remove a
        // network that still has attached containers). `-v` adds named-volume
        // removal on top.
        try await stopOldStuff(services, remove: true)

        await stopEmbeddedDNSResolverIfFullProjectDown()

        await removeProjectNetworks(
            from: dockerCompose,
            targetedServiceNames: Set(services.map(\.serviceName)),
            isFullProjectDown: self.services.isEmpty
        )

        // CHAOS-1494: clean up the synthesized implicit default network on a
        // full project down. The network is project-scoped and has no other
        // lifecycle owner; leaving it would orphan a `<projectName>-default`
        // entry in apple/container's network registry across `down`/`up`
        // cycles. The delete is idempotent (RuntimeError.notFound caught
        // silently) so we do not need to predict whether the current compose
        // state would have synthesized it — we always try, only on full
        // project down. Partial-down preserves the network because sibling
        // services may still use it.
        await removeImplicitDefaultNetworkIfFullProjectDown()

        if removeVolumes {
            await removeNamedVolumes(
                from: dockerCompose,
                targetedServiceNames: Set(services.map(\.serviceName)),
                isFullProjectDown: self.services.isEmpty
            )
        }

        cleanupConfigsSecretsTempDirIfFullProjectDown()
    }

    /// CHAOS-1398: Removes top-level named volumes declared in the compose
    /// file via `RuntimeEnvironment.current.removeVolume(name:)`. Externals
    /// are always skipped (user-managed). On a partial-project down, a
    /// volume is removed only when it's exclusive to the targeted services —
    /// volumes referenced by sibling services outside the target are kept,
    /// and volumes not referenced by any targeted service are kept too.
    /// Removal errors other than `.notFound` are logged but do not abort
    /// the down (consistent with how container removal handles errors).
    private func removeNamedVolumes(
        from dockerCompose: DockerCompose,
        targetedServiceNames: Set<String>,
        isFullProjectDown: Bool
    ) async {
        guard let volumes = dockerCompose.volumes, !volumes.isEmpty else { return }

        let outsideTargetVolumes: Set<String> = isFullProjectDown
            ? []
            : Self.namedVolumesReferenced(by: dockerCompose, matching: { !targetedServiceNames.contains($0) })
        let insideTargetVolumes: Set<String> = isFullProjectDown
            ? []
            : Self.namedVolumesReferenced(by: dockerCompose, matching: { targetedServiceNames.contains($0) })

        print("\n--- Removing Volumes ---")
        for (volumeName, volumeConfig) in volumes {
            if volumeConfig?.external?.isExternal == true {
                print("Skipping external volume: \(volumeName)")
                continue
            }

            let actualVolumeName = volumeConfig?.name ?? volumeName

            if !isFullProjectDown {
                if outsideTargetVolumes.contains(volumeName) {
                    print("Skipping shared volume '\(actualVolumeName)' (referenced by services outside the partial-down target)")
                    continue
                }
                if !insideTargetVolumes.contains(volumeName) {
                    print("Skipping volume '\(actualVolumeName)' (not referenced by any targeted service)")
                    continue
                }
            }

            do {
                try await RuntimeEnvironment.current.removeVolume(name: actualVolumeName)
                print("Removed volume: \(actualVolumeName)")
            } catch RuntimeError.notFound {
                // Registry says no — but a partial failure during a previous
                // compose up can leave a stranded volume.img on disk. Attempt
                // filesystem-level cleanup so the next compose up doesn't fail
                // with "file with the same name already exists".
                cleanupOrphanedVolumeDirectory(name: actualVolumeName)
            } catch {
                print("Error removing volume '\(actualVolumeName)': \(error)")
            }
        }
        print("--- Volumes Removed ---\n")
    }

    /// Conventional on-disk base for apple/container volumes, derived from the
    /// per-user Application Support directory. Exposed as an internal parameter
    /// so unit tests can redirect to a temporary directory without touching real
    /// data under ~/Library/Application Support.
    internal static func defaultVolumesBaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSString(string: "~/Library/Application Support").expandingTildeInPath, directoryHint: .isDirectory)
        let volumesBasePath = FilePath(appSupport.path(percentEncoded: false))
            .pushing(FilePath("com.apple.container/volumes"))
            .lexicallyNormalized()
            .string
        return URL(filePath: volumesBasePath, directoryHint: .isDirectory)
    }

    /// CHAOS-1413: Cleans up the on-disk volume directory left behind when
    /// apple/container's registry no longer knows about a volume but its
    /// `volume.img` is still present. Only invoked from the `.notFound` catch
    /// path — a successful `removeVolume` call already tears down the directory
    /// via the runtime, so running this on the success path is unnecessary.
    ///
    /// - Parameter name: the actual volume name (after `volumeConfig?.name` override resolution)
    /// - Parameter volumesBaseURL: base directory for apple/container volumes;
    ///   defaults to `~/Library/Application Support/com.apple.container/volumes`.
    ///   Tests pass a temporary directory here to avoid touching real data.
    internal func cleanupOrphanedVolumeDirectory(
        name: String,
        volumesBaseURL: URL = ComposeDown.defaultVolumesBaseURL()
    ) {
        let volumeDirPath = FilePath(volumesBaseURL.path(percentEncoded: false)).appending(name).string
        let volumeImgPath = FilePath(volumeDirPath).appending("volume.img").string

        guard fileManager.fileExists(atPath: volumeImgPath) else {
            // No orphan on disk — truly gone. Silent, idempotent.
            return
        }

        print("Warning: removing orphaned volume directory at \(volumeDirPath) (registry had no record of '\(name)')")
        do {
            try fileManager.removeItem(at: URL(filePath: volumeDirPath, directoryHint: .isDirectory))
            print("Removed orphaned volume directory: \(volumeDirPath)")
        } catch {
            print("Error removing orphaned volume directory '\(volumeDirPath)': \(error)")
        }
    }

    /// Helper for `removeNamedVolumes`: collects all named-volume sources
    /// referenced across services whose name matches `predicate`.
    private static func namedVolumesReferenced(
        by dockerCompose: DockerCompose,
        matching predicate: (String) -> Bool
    ) -> Set<String> {
        var result: Set<String> = []
        for (name, serviceOpt) in dockerCompose.services {
            guard let service = serviceOpt, predicate(name) else { continue }
            result.formUnion(service.referencedNamedVolumes())
        }
        return result
    }

    /// CHAOS-1445: Removes top-level networks declared in the compose file via
    /// `RuntimeEnvironment.current.removeNetwork(id:)`. Externals are always
    /// skipped (user-managed). On a partial-project down, a network is removed
    /// only when it's exclusive to the targeted services — networks referenced
    /// by sibling services outside the target are kept, and networks not
    /// referenced by any targeted service are kept too. Removal errors other
    /// than `.notFound` are logged but do not abort the down (consistent with
    /// the volume and container cleanup paths).
    private func removeProjectNetworks(
        from dockerCompose: DockerCompose,
        targetedServiceNames: Set<String>,
        isFullProjectDown: Bool
    ) async {
        guard let networks = dockerCompose.networks, !networks.isEmpty else { return }

        let outsideTargetNetworks: Set<String> = isFullProjectDown
            ? []
            : Self.networksReferenced(by: dockerCompose, matching: { !targetedServiceNames.contains($0) })
        let insideTargetNetworks: Set<String> = isFullProjectDown
            ? []
            : Self.networksReferenced(by: dockerCompose, matching: { targetedServiceNames.contains($0) })

        print("\n--- Removing Networks ---")
        for (networkName, networkConfig) in networks {
            if networkConfig?.external?.isExternal == true {
                print("Skipping external network: \(networkName)")
                continue
            }

            let actualNetworkName = networkConfig?.name ?? networkName

            if !isFullProjectDown {
                if outsideTargetNetworks.contains(networkName) {
                    print("Skipping shared network '\(actualNetworkName)' (referenced by services outside the partial-down target)")
                    continue
                }
                if !insideTargetNetworks.contains(networkName) {
                    print("Skipping network '\(actualNetworkName)' (not referenced by any targeted service)")
                    continue
                }
            }

            do {
                try await RuntimeEnvironment.current.removeNetwork(id: actualNetworkName)
                print("Removed network: \(actualNetworkName)")
            } catch RuntimeError.notFound {
                // Already gone — idempotent.
            } catch {
                print("Error removing network '\(actualNetworkName)': \(error)")
            }
        }
        print("--- Networks Removed ---\n")
    }

    /// CHAOS-1494: idempotent removal of the synthesized implicit default
    /// network. Mirrors `stopEmbeddedDNSResolverIfFullProjectDown` — fires
    /// only on full project down (when no specific services are targeted)
    /// and silently no-ops when the network is absent. Network name is
    /// deterministic from the project name (`<projectName>-default`), so we
    /// don't need to recompute the synthesis trigger from compose state.
    private func removeImplicitDefaultNetworkIfFullProjectDown() async {
        guard self.services.isEmpty, let projectName else { return }
        let implicitName = "\(projectName)-default"
        do {
            try await RuntimeEnvironment.current.removeNetwork(id: implicitName)
            print("Removed implicit default network: \(implicitName)")
        } catch RuntimeError.notFound {
            // No-op — either the project never synthesized one or it was
            // already torn down by a prior `down`.
        } catch {
            print("Error removing implicit default network '\(implicitName)': \(error)")
        }
    }

    /// Helper for `removeProjectNetworks`: collects all top-level network
    /// names referenced across services whose name matches `predicate`.
    /// Mirrors `namedVolumesReferenced`.
    private static func networksReferenced(
        by dockerCompose: DockerCompose,
        matching predicate: (String) -> Bool
    ) -> Set<String> {
        var result: Set<String> = []
        for (name, serviceOpt) in dockerCompose.services {
            guard let service = serviceOpt, predicate(name) else { continue }
            if let names = service.networks?.names {
                result.formUnion(names)
            }
        }
        return result
    }

    /// Removes content-addressed configs/secrets temp files only for a full-project
    /// down. Partial down (for example, `compose down web`) leaves the directory
    /// intact because sibling services may still mount the same shared files.
    private func cleanupConfigsSecretsTempDirIfFullProjectDown() {
        if self.services.isEmpty, let projectName {
            let composeDir = NSString(string: "~/.containers/Compose").expandingTildeInPath
            let secretsDirPath = FilePath(composeDir)
                .pushing(FilePath(projectName))
                .pushing("configs-secrets")
                .lexicallyNormalized()
                .string
            let secretsDir = URL(filePath: secretsDirPath, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: secretsDir)
        }
    }

    private func stopEmbeddedDNSResolverIfFullProjectDown() async {
        guard self.services.isEmpty, let projectName else { return }
        let handle = SidecarHandle.forCleanup(projectName: projectName)
        guard (try? await ContainerClientEnvironment.current.get(id: handle.containerName)) != nil else {
            return
        }
        do {
            try await EmbeddedDNSSidecar.stop(
                handle: handle,
                runner: RunnerEnvironment.current
            )
            print("Stopped embedded DNS resolver: \(handle.containerName)")
        } catch {
            print("Error stopping embedded DNS resolver: \(error)")
        }
    }

    private func stopOldStuff(_ services: [(serviceName: String, service: Service)], remove: Bool) async throws {
        guard let projectName else { return }

        if RuntimeExecutionMode.isRemote {
            let runtime = RuntimeEnvironment.current

            for (serviceName, service) in services {
                let containerName = effectiveContainerName(
                    projectName: projectName,
                    serviceName: serviceName,
                    explicit: service.container_name
                )

                print("Stopping container: \(containerName)")

                guard let container = try? await runtime.get(id: containerName) else {
                    print("Warning: Container '\(containerName)' not found, skipping.")
                    continue
                }

                do {
                    try await runtime.stop(id: container.id, options: .default)
                    print("Successfully stopped container: \(containerName)")
                } catch {
                    print("Error Stopping Container: \(error)")
                }
                if remove {
                    do {
                        try await runtime.remove(id: container.id, force: false)
                        print("Successfully removed container: \(containerName)")
                    } catch {
                        print("Error Removing Container: \(error)")
                    }
                }
            }
            return
        }

        for (serviceName, service) in services {
            let containerName = effectiveContainerName(
                projectName: projectName,
                serviceName: serviceName,
                explicit: service.container_name
            )

            print("Stopping container: \(containerName)")

            let provider = ContainerClientEnvironment.current

            guard let container = try? await provider.get(id: containerName) else {
                print("Warning: Container '\(containerName)' not found, skipping.")
                continue
            }

            do {
                try await provider.stop(id: container.id, opts: .default)
                print("Successfully stopped container: \(containerName)")
            } catch {
                print("Error Stopping Container: \(error)")
            }
            if remove {
                do {
                    try await provider.delete(id: container.id, force: false)
                    print("Successfully removed container: \(containerName)")
                } catch {
                    print("Error Removing Container: \(error)")
                }
            }
        }
    }
}
