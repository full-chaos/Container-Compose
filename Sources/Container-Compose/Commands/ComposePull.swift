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

public struct ComposePull: AsyncParsableCommand, ComposeCommand, @unchecked Sendable {
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

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwdURL)
    }

    // MARK: - run

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()

        if RuntimeExecutionMode.isRemote {
            let projectName = resolveProjectName(for: dockerCompose)
            try await remotePull(projectName: projectName)
            return
        }

        let allServices = try selectedServices(in: dockerCompose)

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
                try await pullImage(
                    image: imageName,
                    policy: effectivePolicy,
                    platform: service.platform,
                    loggingArguments: logging.passThroughCommands()
                )
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

    private func selectedServices(in dockerCompose: DockerCompose) throws -> [(serviceName: String, service: Service)] {
        guard !includeDeps else {
            return try filterServices(dockerCompose, profilesArg: profile, servicesArg: services)
        }

        // Gather all services
        var allServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        // Filter by active profiles
        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        allServices = Service.filterByProfiles(allServices, activeProfiles: activeProfiles)
        allServices = try Service.topoSortConfiguredServices(allServices)

        // Filter by requested service names
        if !services.isEmpty {
            allServices = allServices.filter { serviceName, _ in
                services.contains(serviceName)
            }
        }

        return allServices
    }

    private func remotePull(projectName: String) async throws {
        guard policy == nil || policy == "always" || policy == "missing" else {
            throw RuntimeError.notSupported(operation: "compose pull --policy \(policy ?? "")", conformer: "RemoteRuntime")
        }
        guard let remoteRuntime = RuntimeEnvironment.current as? RemoteRuntime else {
            throw RuntimeError.notSupported(operation: "compose pull", conformer: "RemoteRuntime")
        }

        let stream = try await remoteRuntime.pullProject(
            name: projectName,
            services: services,
            ignoreFailures: ignorePullFailures
        )

        var errors: [String] = []
        for await frame in stream {
            let detail = frame.message ?? frame.type
            print("[\(frame.service)] \(frame.image): \(detail)")
            if frame.type == "error" {
                errors.append(detail)
            }
        }

        if let first = errors.first, !ignorePullFailures {
            throw RuntimeError.backendFailure(message: first)
        }
    }

}
