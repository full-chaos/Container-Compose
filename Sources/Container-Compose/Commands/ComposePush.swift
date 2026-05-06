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
//  ComposePush.swift
//  Container-Compose
//

import ArgumentParser
import ContainerCommands
import ContainerAPIClient
import ContainerizationExtras
import Foundation

public struct ComposePush: AsyncParsableCommand, ComposeCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "push",
        abstract: "Push service images"
    )

    @Argument(help: "Services to push (pushes all image-based services if omitted)")
    var services: [String] = []

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @Flag(name: [.long], help: "Also push images for dependency services")
    var includeDeps: Bool = false

    @Flag(name: [.long], help: "Do not fail if an image push cannot be done")
    var ignorePushFailures: Bool = false

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Suppress progress output")
    var quiet: Bool = false

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()

        let candidateServices = try selectedServices(in: dockerCompose)

        if !quiet {
            print("Pushing images...")
        }

        var failedPushes: [(name: String, error: Error)] = []

        for (serviceName, service) in candidateServices {
            guard let imageName = service.image else {
                if !quiet {
                    if service.build != nil {
                        print("Skipping build-only service '\(serviceName)' (no image field; no remote registry tag to push)")
                    } else {
                        print("Warning: Skipping service '\(serviceName)' (no image field)")
                    }
                }
                continue
            }

            do {
                try await pushImage(imageName, serviceName: serviceName)
            } catch {
                if ignorePushFailures {
                    if !quiet {
                        print("Warning: Failed to push image '\(imageName)' for service '\(serviceName)': \(error.localizedDescription)")
                    }
                    failedPushes.append((name: serviceName, error: error))
                } else {
                    throw error
                }
            }
        }

        if !quiet {
            if failedPushes.isEmpty {
                print("All images pushed successfully.")
            } else {
                print("Push completed with \(failedPushes.count) failure(s):")
                for failed in failedPushes {
                    print("  - \(failed.name): \(failed.error.localizedDescription)")
                }
            }
        }
    }

    private func selectedServices(in dockerCompose: DockerCompose) throws -> [(serviceName: String, service: Service)] {
        guard !includeDeps else {
            return try filterServices(dockerCompose, profilesArg: profile, servicesArg: services)
        }

        var candidateServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        candidateServices = Service.filterByProfiles(candidateServices, activeProfiles: activeProfiles)
        candidateServices = try Service.topoSortConfiguredServices(candidateServices)

        if !services.isEmpty {
            candidateServices = candidateServices.filter { serviceName, _ in
                services.contains(serviceName)
            }
        }

        return candidateServices
    }

    private func pushImage(_ imageName: String, serviceName: String) async throws {
        let qualifiedImageName = ComposeUp.qualifyImageReference(imageName)

        if !quiet {
            print("Pushing image for service '\(serviceName)': \(qualifiedImageName)")
        }

        if RuntimeExecutionMode.isRemote {
            let result = try await RuntimeEnvironment.current.pushImage(reference: qualifiedImageName)
            for line in result.stdout where !quiet {
                print(line)
            }
            for line in result.stderr {
                fputs("\(line)\n", stderr)
            }
            guard result.exitCode == 0 else {
                throw RuntimeError.backendFailure(message: "remote image push exited with status \(result.exitCode)")
            }
            return
        }

        let pushArgv = ["container", "image", "push", qualifiedImageName] + logging.passThroughCommands()
        let result = try await RunnerEnvironment.current.run(
            RunRequest(kind: .awaitOnly, argv: pushArgv, cwd: cwd),
            onStdout: nil,
            onStderr: nil
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "ComposePush",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "container image push exited with status \(result.exitCode)"]
            )
        }
    }
}
