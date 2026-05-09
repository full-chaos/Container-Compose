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
//  ComposeStop.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import Yams

public struct ComposeStop: AsyncParsableCommand, ComposeCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "stop",
        abstract: "Stop running containers without removing them"
    )

    @Argument(help: "Specify the services to stop")
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

        // CHAOS-1446 Phase 3: stop runs in PARALLEL, gated by the REVERSE
        // dependency DAG. Forward-order input is preserved — the reverse-DAG
        // adjacency is computed inside stopServices(). Pre-Phase-3 callers
        // passed `.reversed()` here; that's now redundant.
        try await stopServices(resolvedServices, projectName: projectName)
    }

    // CHAOS-1446 Phase 3: stops run in PARALLEL, gated by the REVERSE
    // dependency DAG via `DependencyCoordinator`. Each service awaits
    // every DEPENDENT (services that depend on it) to publish `.stopped`
    // before issuing its own stop — leaves stop first, roots stop last.
    // The reverse adjacency is built from each service's
    // `dependsOn.serviceNames` (NOT from `Service.dependedBy`, which
    // UltraBrain MEDIUM #2 flagged as unreliable). Per Lead Decision D4,
    // ComposeStop MUST NOT acquire `@unchecked Sendable`; per-service work
    // is therefore extracted into a `static` helper that captures only
    // Sendable parameters — no `self` capture inside the @Sendable child
    // task closure.
    func stopServices(_ services: [(serviceName: String, service: Service)], projectName: String) async throws {
        let coord = DependencyCoordinator()
        let reverseGraph = buildReverseDependencyGraph(services: services)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (serviceName, service) in services {
                group.addTask {
                    // Wait for every selected DEPENDENT to publish .stopped
                    // before this service stops. Leaves (no dependents) clear
                    // this loop immediately.
                    for dependent in reverseGraph[serviceName] ?? [] {
                        try await coord.awaitMilestone(for: dependent, milestone: .stopped)
                    }

                    // Issue the stop. Errors are swallowed and logged (matching
                    // the pre-Phase-3 serial behavior); the .stopped milestone
                    // is published unconditionally so dependencies are not
                    // permanently blocked by a single failure.
                    await Self.performSingleStop(
                        serviceName: serviceName,
                        service: service,
                        projectName: projectName
                    )

                    await coord.publishMilestone(.stopped, for: serviceName)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Per-service stop, extracted out of `stopServices` so the parallel
    /// child closure does not need to capture `self` (Lead Decision D4 —
    /// ComposeStop must not become @unchecked Sendable). All inputs are
    /// Sendable value types or task-local-bound singletons
    /// (RuntimeEnvironment / ContainerClientEnvironment).
    private static func performSingleStop(
        serviceName: String,
        service: Service,
        projectName: String
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
            print("Stopping container: \(containerName)")
            do {
                try await runtime.stop(id: container.id, options: .default)
                print("Successfully stopped container: \(containerName)")
            } catch {
                print("Error stopping container '\(containerName)': \(error)")
            }
            return
        }

        let provider = ContainerClientEnvironment.current
        guard let container = try? await provider.get(id: containerName) else {
            print("Warning: Container '\(containerName)' not found, skipping.")
            return
        }

        print("Stopping container: \(containerName)")
        do {
            try await provider.stop(id: container.id, opts: .default)
            print("Successfully stopped container: \(containerName)")
        } catch {
            print("Error stopping container '\(containerName)': \(error)")
        }
    }
}
