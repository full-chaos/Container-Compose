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
//  ComposeRestart.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import Yams

public struct ComposeRestart: AsyncParsableCommand, ComposeCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "restart",
        abstract: "Restart running containers without re-creating them"
    )

    @Argument(help: "Specify the services to restart")
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

        // CHAOS-1446 Phase 3: full-stop barrier before any start (UltraBrain
        // HIGH #8). The `try await` between Phase 1 and Phase 2 IS the barrier
        // — Phase 2 cannot begin until Phase 1's TaskGroup has fully drained,
        // so no service is being restarted while another's dependency is
        // still down. Forward-order input is preserved on both phases; the
        // reverse-DAG for stop is computed inside ComposeStop.stopServices().

        // Phase 1: stop ALL services in reverse-DAG order (parallel within
        // dependency constraints). Returns only after every stop completes.
        print("--- Stopping services ---")
        // ComposeStop is bare-init'd here (its serial helpers don't read
        // from `self`), so we don't pay ArgumentParser's parsed-properties tax.
        let composeStop = ComposeStop()
        try await composeStop.stopServices(resolvedServices, projectName: projectName)

        // Phase 2: start ALL services in forward-DAG order (parallel within
        // dependency constraints). ComposeStart is bare-init'd, so we MUST
        // pass `cwd` explicitly — ComposeStart's `self.cwd` would crash on
        // the unparsed @OptionGroup `process` access. Use ComposeRestart's
        // own `cwd`, which IS parsed.
        print("--- Starting services ---")
        let composeStart = ComposeStart()
        try await composeStart.startServices(resolvedServices, projectName: projectName, cwd: cwd)

        print("--- Restart complete ---")
    }
}
