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
//  ComposePull.swift
//  Container-Compose
//

import ArgumentParser
import ContainerCommands
import ContainerAPIClient
import ContainerizationExtras
import Foundation
import Yams

public struct ComposePull: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "pull",
        abstract: "Pull service images"
    )

    @Argument(help: "Services to pull (pulls all image-based services if omitted)")
    var services: [String] = []

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @Flag(name: [.long], help: "Also pull images for dependency services")
    var includeDeps: Bool = false

    @Flag(name: [.long], help: "Do not fail if a pull cannot be done")
    var ignorePullFailures: Bool = false

    @Option(name: [.long], help: "Override pull policy: always | missing | never")
    var policy: String?

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    // MARK: - Computed paths

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    /// Project root for outside-container relative-path resolution. Honors
    /// `--project-directory`, falls back to the compose file's directory.
    private var effectiveProjectDirectory: String {
        resolveProjectDirectory(
            cliOverride: projectFlags.projectDirectory,
            composeFilePath: composePath,
            cwd: cwd
        )
    }

    private var cwdURL: URL { URL(fileURLWithPath: cwd) }

    private static let supportedComposeFilenames = [
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    ]

    private var composePath: String {
        if let composeFilename {
            return resolvedPath(for: composeFilename, relativeTo: cwdURL)
        }
        for filename in Self.supportedComposeFilenames {
            let candidate = cwdURL.appending(path: filename).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return cwdURL.appending(path: Self.supportedComposeFilenames[0]).path
    }

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwdURL)
    }

    // MARK: - run

    public mutating func run() async throws {
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        // Gather all services
        var allServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        // Filter by active profiles
        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        allServices = Service.filterByProfiles(allServices, activeProfiles: activeProfiles)

        // Filter by requested service names
        if !services.isEmpty {
            allServices = allServices.filter { serviceName, service in
                if services.contains(serviceName) { return true }
                if includeDeps && services.contains(where: { service.dependedBy.contains($0) }) {
                    return true
                }
                return false
            }
        }

        print("Pulling images...")
        var failedPulls: [(name: String, error: Error)] = []

        for (serviceName, service) in allServices {
            // Skip build-only services (no image field) unless --include-deps is set.
            // If the service has a build config but no image field, skip it.
            guard let imageName = service.image else {
                if service.build != nil {
                    print("Skipping build-only service '\(serviceName)' (no image field)")
                }
                continue
            }

            // Determine effective pull policy:
            // --policy flag > service.pull_policy > "missing"
            let effectivePolicy = policy ?? service.pull_policy ?? "missing"

            do {
                try await pullImage(imageName, platform: service.platform, policy: effectivePolicy)
            } catch {
                if ignorePullFailures {
                    print("Warning: Failed to pull image '\(imageName)' for service '\(serviceName)': \(error.localizedDescription)")
                    failedPulls.append((name: serviceName, error: error))
                } else {
                    throw error
                }
            }
        }

        if failedPulls.isEmpty {
            print("All images pulled successfully.")
        } else {
            print("Pull completed with \(failedPulls.count) failure(s):")
            for failed in failedPulls {
                print("  - \(failed.name): \(failed.error.localizedDescription)")
            }
        }
    }

    // MARK: - Pull image helper (copied from ComposeUp.pullImage)

    private func pullImage(_ imageName: String, platform: String?, policy: String? = nil) async throws {
        // Normalise policy: nil and "if_not_present" are aliases for "missing".
        let effectivePolicy: String
        switch policy?.lowercased() {
        case nil, "missing", "if_not_present":
            effectivePolicy = "missing"
        case "always":
            effectivePolicy = "always"
        case "never":
            effectivePolicy = "never"
        case "build":
            effectivePolicy = "build"
        default:
            effectivePolicy = "missing"
        }

        let imageList = try await ClientImage.list()
        let imageExists = imageList.contains(where: {
            $0.description.reference.components(separatedBy: "/").last == imageName
        })

        switch effectivePolicy {
        case "never", "build":
            // Image must already be present; pull is forbidden.
            guard imageExists else {
                throw ComposeError.imageNotFound(imageName)
            }
            return

        case "always":
            // Always pull, regardless of whether the image is cached locally.
            break

        default:
            // "missing": short-circuit if image already exists.
            guard !imageExists else { return }
        }

        print("Pulling Image \(imageName)...")

        var commands = [imageName]

        if let platform {
            commands.append(contentsOf: ["--platform", platform])
        }

        let imagePullArgv = commands + logging.passThroughCommands()
        _ = try await RunnerEnvironment.current.run(
            RunRequest(kind: .swiftAPI(name: "ImagePull"), argv: imagePullArgv, cwd: nil),
            onStdout: nil,
            onStderr: nil
        )
    }
}
