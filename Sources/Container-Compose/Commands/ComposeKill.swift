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
//  ComposeKill.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import Yams

public struct ComposeKill: AsyncParsableCommand, ComposeCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "kill",
        abstract: "Force-stop project containers"
    )

    @Argument(help: "Specify the services to kill")
    var services: [String] = []

    @Option(
        name: [.customShort("s"), .customLong("signal")],
        help: "Signal to send to the container (default SIGKILL)"
    )
    var signal: String = "SIGKILL"

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

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()
        let projectName = resolveProjectName(for: dockerCompose)
        let resolvedServices = try filterServices(
            dockerCompose,
            profilesArg: profile,
            servicesArg: services
        )

        // Kill in REVERSE topo-sort order: dependents before dependencies.
        try await killServices(resolvedServices.reversed(), projectName: projectName)
    }

    func killServices(_ services: some Sequence<(serviceName: String, service: Service)>, projectName: String) async throws {
        if RuntimeExecutionMode.isRemote {
            let runtime = RuntimeEnvironment.current
            let parsedSignal = parseSignal(signal)

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

                print("Killing container: \(containerName) (signal: \(signal))")
                do {
                    try await runtime.kill(id: container.id, signal: parsedSignal)
                    print("Successfully killed container: \(containerName)")
                } catch {
                    print("Error killing container '\(containerName)': \(error)")
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

            print("Killing container: \(containerName) (signal: \(signal))")
            do {
                // ContainerClient does not expose a kill(id:signal:) method;
                // route through the RunCommandRunner seam (PR-5 of the
                // recorder migration; see docs/plans/PLAN-recorder-seam.md
                // §7 / §9 PR-5 / §10 Q4). The previous `shellKill` helper was
                // deleted; `ProductionRunner` preserves the same `Process()`
                // semantics byte-for-byte, and caller-side error translation
                // keeps the original `NSError(domain: "ComposeKill", ...)`
                // shape.
                let request = RunRequest(
                    kind: .awaitOnly,
                    argv: ["container", "kill", "--signal", signal, container.id],
                    cwd: cwd
                )
                let result = try await RunnerEnvironment.current.run(
                    request,
                    onStdout: nil,
                    onStderr: nil
                )
                guard result.exitCode == 0 else {
                    throw NSError(
                        domain: "ComposeKill",
                        code: Int(result.exitCode),
                        userInfo: [NSLocalizedDescriptionKey: "container kill exited with status \(result.exitCode)"]
                    )
                }
                print("Successfully killed container: \(containerName)")
            } catch {
                print("Error killing container '\(containerName)': \(error)")
            }
        }
    }

    private func parseSignal(_ value: String) -> Int32 {
        if let direct = Int32(value) {
            return direct
        }
        switch value.uppercased() {
        case "SIGTERM": return 15
        case "SIGKILL": return 9
        case "SIGINT": return 2
        default: return 9
        }
    }
}

// PR-5 of the recorder migration removed the `private func shellKill(...)`
// helper that previously lived here. The `compose kill` await-only shell-out
// now flows through `RunnerEnvironment.current.run(_:onStdout:onStderr:)`
// (see the call site in `killServices` above). `ProductionRunner` in
// `Sources/Container-Compose/Runtime/RunCommandRunner.swift` preserves the
// previous `Process()` semantics — including inherit-stdio for the await-only
// call — byte-for-byte. See `docs/plans/PLAN-recorder-seam.md` §7 / §10 Q4 / §11.
