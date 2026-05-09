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

        try await startServices(resolvedServices, projectName: projectName, cwd: cwd)
    }

    // NOTE: ContainerClient does not expose a `start(id:)` method; it only
    // provides `bootstrap(id:stdio:)` which requires complex IO setup.
    // We shell out to `container start --detach <name>` instead, which is
    // the same mechanism the container CLI uses internally.
    //
    // CHAOS-1446 Phase 3: starts run in PARALLEL, gated by the forward
    // `depends_on` DAG via `DependencyCoordinator`. Each service awaits
    // every dependency's `.started` milestone before issuing its own
    // start. After a successful start (or non-throwing skip) the service
    // publishes its own `.started` so dependents may proceed. Per Lead
    // Decision D4, ComposeStart MUST NOT acquire `@unchecked Sendable`;
    // the per-service work is therefore extracted into a `static` helper
    // that captures only Sendable parameters — no `self` capture inside
    // the @Sendable child task closure.
    func startServices(_ services: [(serviceName: String, service: Service)], projectName: String, cwd: String) async throws {
        let coord = DependencyCoordinator()
        let forwardGraph = buildForwardDependencyGraph(services: services)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (serviceName, service) in services {
                group.addTask {
                    // Wait for every selected dependency to publish .started.
                    // Edges to non-selected services are pre-filtered out by
                    // buildForwardDependencyGraph, so this loop only awaits
                    // services that will actually run.
                    for dep in forwardGraph[serviceName] ?? [] {
                        try await coord.awaitMilestone(for: dep, milestone: .started)
                    }

                    // Issue the start. Errors are swallowed and logged (matching
                    // the pre-Phase-3 serial behavior); the .started milestone
                    // is published unconditionally so dependents are not
                    // permanently blocked by a single failure.
                    await Self.performSingleStart(
                        serviceName: serviceName,
                        service: service,
                        projectName: projectName,
                        cwd: cwd
                    )

                    await coord.publishMilestone(.started, for: serviceName)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Per-service start, extracted out of `startServices` so the parallel
    /// child closure does not need to capture `self` (Lead Decision D4 —
    /// ComposeStart must not become @unchecked Sendable). All inputs are
    /// Sendable value types or task-local-bound singletons
    /// (RuntimeEnvironment / RunnerEnvironment / ContainerClientEnvironment).
    private static func performSingleStart(
        serviceName: String,
        service: Service,
        projectName: String,
        cwd: String
    ) async {
        let containerName = effectiveContainerName(
            projectName: projectName,
            serviceName: serviceName,
            explicit: service.container_name
        )

        if RuntimeExecutionMode.isRemote {
            let runtime = RuntimeEnvironment.current

            guard let container = try? await runtime.get(id: containerName) else {
                print("Warning: Container '\(containerName)' not found, skipping.")
                return
            }

            if container.status == .running {
                print("Info: Container '\(containerName)' is already running, skipping.")
                return
            }

            print("Starting container: \(containerName)")
            do {
                try await runtime.start(id: container.id)
                print("Successfully started container: \(containerName)")
            } catch {
                print("Error starting container '\(containerName)': \(error)")
            }
            return
        }

        guard let container = try? await ContainerClientEnvironment.current.get(id: containerName) else {
            print("Warning: Container '\(containerName)' not found, skipping.")
            return
        }

        if container.status == .running {
            print("Info: Container '\(containerName)' is already running, skipping.")
            return
        }

        print("Starting container: \(containerName)")
        do {
            // Route through the RunCommandRunner seam (PR-5 of the recorder
            // migration; see docs/plans/PLAN-recorder-seam.md §7 / §10 Q4).
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

// PR-5 of the recorder migration removed the `private func shellStart(...)`
// helper that previously lived here. The `compose start` await-only shell-out
// now flows through `RunnerEnvironment.current.run(_:onStdout:onStderr:)`
// (see the call site in `startServices` above). `ProductionRunner` in
// `Sources/Container-Compose/Runtime/RunCommandRunner.swift` preserves the
// previous `Process()` semantics — including inherit-stdio for the await-only
// call — byte-for-byte. See `docs/plans/PLAN-recorder-seam.md` §7 / §10 Q4 / §11.
