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
        return resolvedPath(for: envFile, relativeTo: cwd)
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

        // Pre-filter: skip build-only services (no `image:` field). Doing this
        // BEFORE the parallel fan-out keeps the per-service Sendable closure
        // body small (no need to thread `service.build != nil` checks
        // through the worker) and surfaces all skip messages up-front in a
        // deterministic order — critical when subsequent per-service output
        // interleaves under the parallel scheduler.
        var pullables: [(serviceName: String, image: String, platform: String?, pullPolicy: String?)] = []
        for (serviceName, service) in allServices {
            guard let imageName = service.image else {
                if service.build != nil {
                    print("Skipping build-only service '\(serviceName)' (no image field)")
                }
                continue
            }
            pullables.append((serviceName: serviceName, image: imageName, platform: service.platform, pullPolicy: service.pull_policy))
        }

        if pullables.isEmpty {
            print("No services with images to pull.")
            return
        }

        // Resolve the parallel concurrency cap from CLI > env > default.
        // CHAOS-1446 Phase 2 + Lead Decision D1: --parallel lives on
        // ProjectFlags; the resolver throws ValidationError on invalid
        // values so misconfiguration surfaces here, not silently mid-pull.
        let parallelLimit = try ParallelLimitResolver.resolved(cli: projectFlags.parallel)

        // Snapshot non-Sendable instance state into local lets so the parallel
        // body closures don't capture `self`. The per-call values (image,
        // platform, pullPolicy) ride on the fan-out helper's per-item value.
        let policyOverride = self.policy
        let loggingArgs = self.logging.passThroughCommands()

        print("Pulling images...")

        // Fan-out items: keyed by service name so error tagging from
        // ServiceTaggedError preserves the offending service.
        let items = pullables.map { tup -> (key: String, value: (image: String, platform: String?, pullPolicy: String?)) in
            (key: tup.serviceName, value: (image: tup.image, platform: tup.platform, pullPolicy: tup.pullPolicy))
        }

        if ignorePullFailures {
            // Collecting variant: every body runs to completion, failures are
            // captured into the result map, NO sibling cancellation. Matches
            // the pre-existing serial behavior of — print warning per
            // failure, continue, and report a summary at the end.
            let results = await runBoundedCollectingFanOut(items: items, limit: parallelLimit) { serviceName, params in
                do {
                    let effectivePolicy = policyOverride ?? params.pullPolicy ?? "missing"
                    try await pullImage(
                        image: params.image,
                        policy: effectivePolicy,
                        platform: params.platform,
                        loggingArguments: loggingArgs
                    )
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }

            // Walk items in input order so failure messages print in a stable,
            // user-visible sequence (the dictionary itself is unordered).
            var failedPulls: [(name: String, error: Error)] = []
            for item in items {
                guard case .failure(let err) = results[item.key] else { continue }
                let displayImage = item.value.image
                print("Warning: Failed to pull image '\(displayImage)' for service '\(item.key)': \(err.localizedDescription)")
                failedPulls.append((name: item.key, error: err))
            }

            if failedPulls.isEmpty {
                print("All images pulled successfully.")
            } else {
                print("Pull completed with \(failedPulls.count) failure(s):")
                for failed in failedPulls {
                    print("  - \(failed.name): \(failed.error.localizedDescription)")
                }
            }
        } else {
            // Throwing variant: first failure cancels in-flight siblings via
            // withThrowingTaskGroup's automatic cancellation. The thrown
            // ServiceTaggedError preserves the offending service name so the
            // user sees WHICH image failed (the bare error message would lose
            // the service context under fan-out).
            _ = try await runBoundedThrowingFanOut(items: items, limit: parallelLimit) { _, params in
                let effectivePolicy = policyOverride ?? params.pullPolicy ?? "missing"
                try await pullImage(
                    image: params.image,
                    policy: effectivePolicy,
                    platform: params.platform,
                    loggingArguments: loggingArgs
                )
            }
            print("All images pulled successfully.")
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
