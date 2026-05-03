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
import Yams

public struct ComposeDown: AsyncParsableCommand {
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

    private var cwd: String { hostCwd ?? FileManager.default.currentDirectoryPath }

    /// Project root for outside-container relative-path resolution. Honors
    /// `--project-directory`, falls back to the compose file's directory.
    private var effectiveProjectDirectory: String {
        resolveProjectDirectory(
            cliOverride: projectFlags.projectDirectory,
            composeFilePath: composePath,
            cwd: cwd
        )
    }

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    private static let supportedComposeFilenames = [
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    ]

    private var cwdURL: URL {
        URL(fileURLWithPath: cwd)
    }

    private var composePath: String {
        if let composeFilename {
            return resolvedPath(for: composeFilename, relativeTo: cwdURL)
        }

        for filename in Self.supportedComposeFilenames {
            let candidate = cwdURL.appending(path: filename).path
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return cwdURL.appending(path: Self.supportedComposeFilenames[0]).path
    }

    private var fileManager: FileManager { FileManager.default }
    private var projectName: String?

    public mutating func run() async throws {

        // Decode (and recursively merge includes) into the DockerCompose struct.
        let dockerCompose = try DockerCompose.loadAndMerge(mainPath: composePath)

        // Determine project name for container naming.
        // Precedence: --project-name CLI flag > compose file `name:` > directory basename.
        let resolvedName = resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )
        projectName = resolvedName
        if let cliName = projectFlags.projectName, !cliName.isEmpty {
            print("Info: Using project name from --project-name flag: \(cliName)")
        } else if let name = dockerCompose.name {
            print("Info: Docker Compose project name parsed as: \(name)")
            print(
                "Note: The 'name' field currently only affects container naming (e.g., '\(name)-serviceName'). Full project-level isolation for other resources (networks, implicit volumes) is not implemented by this tool."
            )
        } else {
            print("Info: No 'name' field found in docker-compose.yml. Using directory name as project name: \(resolvedName)")
        }

        var services: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap({ serviceName, service in
            guard let service else { return nil }
            return (serviceName, service)
        })

        // Filter by active profiles before topo-sort.
        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        services = Service.filterByProfiles(services, activeProfiles: activeProfiles)

        services = try Service.topoSortConfiguredServices(services)

        // Filter for specified services
        if !self.services.isEmpty {
            services = services.filter({ serviceName, service in
                self.services.contains(where: { $0 == serviceName }) || self.services.contains(where: { service.dependedBy.contains($0) })
            })
        }

        // When `-v` is passed, also remove containers — apple/container blocks
        // volume removal while a container (even stopped) still references the
        // volume, so we must delete the container before the volume cleanup.
        // Without `-v`, preserve the historical "stop only" behavior.
        try await stopOldStuff(services, remove: removeVolumes)

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
                // Already gone — idempotent.
            } catch {
                print("Error removing volume '\(actualVolumeName)': \(error)")
            }
        }
        print("--- Volumes Removed ---\n")
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

    /// Removes content-addressed configs/secrets temp files only for a full-project
    /// down. Partial down (for example, `compose down web`) leaves the directory
    /// intact because sibling services may still mount the same shared files.
    private func cleanupConfigsSecretsTempDirIfFullProjectDown() {
        if self.services.isEmpty, let projectName {
            let secretsDir = URL(fileURLWithPath: NSString(string: "~/.containers/Compose/\(projectName)/configs-secrets").expandingTildeInPath)
            try? FileManager.default.removeItem(at: secretsDir)
        }
    }

    private func stopOldStuff(_ services: [(serviceName: String, service: Service)], remove: Bool) async throws {
        guard let projectName else { return }

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
