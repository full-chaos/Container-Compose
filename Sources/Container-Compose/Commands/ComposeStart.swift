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
//  ComposeStart.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import Yams

public struct ComposeStart: AsyncParsableCommand, ComposeCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "start",
        abstract: "Start existing stopped containers (without re-creating them)"
    )

    @Argument(help: "Specify the services to start")
    var services: [String] = []

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    private var fileManager: FileManager { FileManager.default }

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()
        let projectName = resolveProjectName(for: dockerCompose)
        let resolvedServices = try filterServices(
            dockerCompose,
            profilesArg: profile,
            servicesArg: services
        )

        try await startServices(resolvedServices, projectName: projectName)
    }

    // NOTE: ContainerClient does not expose a `start(id:)` method; it only
    // provides `bootstrap(id:stdio:)` which requires complex IO setup.
    // We shell out to `container start --detach <name>` instead, which is
    // the same mechanism the container CLI uses internally.
    func startServices(_ services: [(serviceName: String, service: Service)], projectName: String) async throws {
        if RuntimeExecutionMode.isRemote {
            let runtime = RuntimeEnvironment.current
            for (serviceName, service) in services {
                let containerName = effectiveContainerName(
                    projectName: projectName,
                    serviceName: serviceName,
                    explicit: service.container_name
                )

                guard let container = try? await runtime.get(id: containerName) else {
                    print("Warning: Container '\(containerName)' not found, skipping.")
                    continue
                }

                if container.status == .running {
                    print("Info: Container '\(containerName)' is already running, skipping.")
                    continue
                }

                print("Starting container: \(containerName)")
                do {
                    try await runtime.start(id: container.id)
                    print("Successfully started container: \(containerName)")
                } catch {
                    print("Error starting container '\(containerName)': \(error)")
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

            guard let container = try? await ContainerClientEnvironment.current.get(id: containerName) else {
                print("Warning: Container '\(containerName)' not found, skipping.")
                continue
            }

            if container.status == .running {
                print("Info: Container '\(containerName)' is already running, skipping.")
                continue
            }

            print("Starting container: \(containerName)")
            do {
                // Route through the RunCommandRunner seam (PR-5 of the
                // recorder migration; see docs/plans/PLAN-recorder-seam.md
                // §7 / §9 PR-5 / §10 Q4). The previous `shellStart` helper
                // was deleted; `ProductionRunner` preserves the same
                // `Process()` semantics byte-for-byte, and caller-side error
                // translation keeps the original `NSError(domain: "ComposeStart", ...)`
                // shape.
                let request = RunRequest(
                    kind: .awaitOnly,
                    argv: ["container", "start", "--detach", containerName],
                    cwd: cwd
                )
                let result = try await RunnerEnvironment.current.run(
                    request,
                    onStdout: nil,
                    onStderr: nil
                )
                guard result.exitCode == 0 else {
                    throw NSError(
                        domain: "ComposeStart",
                        code: Int(result.exitCode),
                        userInfo: [NSLocalizedDescriptionKey: "container start exited with status \(result.exitCode)"]
                    )
                }
                print("Successfully started container: \(containerName)")
            } catch {
                print("Error starting container '\(containerName)': \(error)")
            }
        }
    }
}

// PR-5 of the recorder migration removed the `private func shellStart(...)`
// helper that previously lived here. The `compose start` await-only shell-out
// now flows through `RunnerEnvironment.current.run(_:onStdout:onStderr:)`
// (see the call site in `startServices` above). `ProductionRunner` in
// `Sources/Container-Compose/Runtime/RunCommandRunner.swift` preserves the
// previous `Process()` semantics — including inherit-stdio for the await-only
// call — byte-for-byte. See `docs/plans/PLAN-recorder-seam.md` §7 / §10 Q4 / §11.
