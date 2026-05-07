//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
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

import Foundation
import Testing
@testable import ContainerComposeCore
import TestHelpers

/// Regression coverage for CHAOS-1445: `compose down` previously had no way to
/// remove project-declared networks, leaving them registered in apple/container's
/// network store across runs. This contradicted user expectation
/// (matching `docker compose down`) and combined with the existing volume
/// behaviour to leak resources.
///
/// Behaviour locked in here (docker-compose-strict semantic):
/// - Plain `down` (no flags) stops + removes containers AND removes
///   project-declared networks (matches `docker compose down`).
/// - `down -v` does the above plus removes named volumes.
/// - External networks are never removed.
/// - On a partial-project down, a network is removed only when it's
///   exclusive to the targeted services — networks referenced by sibling
///   services outside the target are kept (mirrors the volume scoping
///   established in CHAOS-1398).
/// - `.notFound` on `removeNetwork` is logged but does not abort the down
///   (consistent with how container and volume removal handle errors).
@Suite("ComposeDown network removal (CHAOS-1445)", .serialized)
struct ComposeDownNetworkRemovalTests {

    // MARK: - Full project down

    @Test("Full down removes every top-level project network (no -v needed)")
    func fullDownRemovesAllNetworks() async throws {
        let projectName = "net-test-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                networks: [frontend, backend]
            networks:
              frontend:
              backend:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedNetworks: [
            RuntimeNetwork(id: "frontend", name: "frontend", driver: "bridge"),
            RuntimeNetwork(id: "backend", name: "backend", driver: "bridge"),
        ])
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(Self.containsRemoveNetwork(entries, id: "frontend"),
                "expected removeNetwork(frontend); got \(entries)")
        #expect(Self.containsRemoveNetwork(entries, id: "backend"),
                "expected removeNetwork(backend); got \(entries)")
    }

    @Test("Full down -v removes networks AND named volumes")
    func fullDownWithFlagRemovesNetworksAndVolumes() async throws {
        let projectName = "net-vol-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                networks: [appnet]
                volumes:
                  - data:/d
            networks:
              appnet:
            volumes:
              data:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(
            stubbedNetworks: [RuntimeNetwork(id: "appnet", name: "appnet", driver: "bridge")],
            stubbedVolumes: [RuntimeVolume(name: "data")]
        )
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "-v"])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(Self.containsRemoveNetwork(entries, id: "appnet"),
                "expected removeNetwork(appnet); got \(entries)")
        #expect(entries.contains(.removeVolume(name: "data")),
                "expected removeVolume(data); got \(entries)")
    }

    @Test("Full down skips external networks")
    func fullDownSkipsExternals() async throws {
        let projectName = "net-ext-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                networks: [shared, owned]
            networks:
              shared:
                external: true
              owned:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedNetworks: [
            RuntimeNetwork(id: "shared", name: "shared", driver: "bridge"),
            RuntimeNetwork(id: "owned", name: "owned", driver: "bridge"),
        ])
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(Self.containsRemoveNetwork(entries, id: "owned"),
                "expected removeNetwork(owned); got \(entries)")
        #expect(!Self.containsRemoveNetwork(entries, id: "shared"),
                "must not remove external network; got \(entries)")
    }

    @Test("Full down with no networks declared makes no removeNetwork calls")
    func fullDownWithNoNetworksIsNoOp() async throws {
        let projectName = "no-nets-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime()
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        let touchedNetworks = entries.contains(where: {
            if case .removeNetwork = $0 { return true }
            return false
        })
        #expect(!touchedNetworks, "no top-level networks declared, must not call removeNetwork; got \(entries)")
    }

    // MARK: - Partial project down (shared-network semantics)

    @Test("Partial down removes networks exclusive to targeted services")
    func partialDownRemovesExclusiveNetworks() async throws {
        let projectName = "part-excl-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                networks: [api_only]
              worker:
                image: alpine
                networks: [worker_only]
            networks:
              api_only:
              worker_only:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedNetworks: [
            RuntimeNetwork(id: "api_only", name: "api_only", driver: "bridge"),
            RuntimeNetwork(id: "worker_only", name: "worker_only", driver: "bridge"),
        ])
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "api"])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(Self.containsRemoveNetwork(entries, id: "api_only"),
                "expected api_only removed; got \(entries)")
        #expect(!Self.containsRemoveNetwork(entries, id: "worker_only"),
                "must not remove worker_only; got \(entries)")
    }

    @Test("Partial down skips networks shared with services outside the target")
    func partialDownSkipsSharedNetworks() async throws {
        let projectName = "part-shared-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                networks: [shared_net]
              worker:
                image: alpine
                networks: [shared_net]
            networks:
              shared_net:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedNetworks: [
            RuntimeNetwork(id: "shared_net", name: "shared_net", driver: "bridge"),
        ])
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "api"])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(!Self.containsRemoveNetwork(entries, id: "shared_net"),
                "shared network must be skipped on partial down; got \(entries)")
    }

    // MARK: - Idempotency

    @Test("Down tolerates already-removed networks (notFound)")
    func downToleratesNotFound() async throws {
        let projectName = "tol-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                networks: [gone]
            networks:
              gone:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Stub ZERO networks so RecordingRuntime.removeNetwork throws .notFound
        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedNetworks: [])

        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(Self.containsRemoveNetwork(entries, id: "gone"),
                "removeNetwork(gone) must still be attempted even if registry is empty; got \(entries)")
    }

    // MARK: - BridgeContainerClientRuntime.removeNetwork dispatch

    /// Verifies that `BridgeContainerClientRuntime.removeNetwork` dispatches
    /// through `RunnerEnvironment` via `.swiftAPI(name: "NetworkDelete")` and
    /// no longer throws `.notSupported`. Mirrors the CHAOS-1408
    /// `createNetwork` test in `ComposeUpNetworkCreationTests`.
    @Test("BridgeContainerClientRuntime.removeNetwork dispatches via RunnerEnvironment (not notSupported)")
    func bridgeRemoveNetworkDispatchesViaRunner() async throws {
        let bridge = BridgeContainerClientRuntime()
        let runner = RecordingRunner()

        try await RunnerEnvironment.$current.withValue(runner) {
            try await bridge.removeNetwork(id: "app-net")
        }

        let recorded = await runner.recordedRequests()
        let networkDeleteCalls = recorded.filter { entry in
            if case .swiftAPI(let name) = entry.request.kind { return name == "NetworkDelete" }
            return false
        }
        #expect(!networkDeleteCalls.isEmpty,
                "BridgeContainerClientRuntime.removeNetwork must dispatch to RunnerEnvironment with .swiftAPI(name: \"NetworkDelete\"); got: \(recorded)")
    }

    @Test("BridgeContainerClientRuntime.removeNetwork passes id as first argv")
    func bridgeRemoveNetworkPassesIdInArgv() async throws {
        let bridge = BridgeContainerClientRuntime()
        let runner = RecordingRunner()

        try await RunnerEnvironment.$current.withValue(runner) {
            try await bridge.removeNetwork(id: "my-net")
        }

        let recorded = await runner.recordedRequests()
        let networkDelete = recorded.first { entry in
            if case .swiftAPI(let name) = entry.request.kind { return name == "NetworkDelete" }
            return false
        }
        #expect(networkDelete?.request.argv.first == "my-net",
                "network id must be first argv element; got: \(networkDelete?.request.argv ?? [])")
    }

    // MARK: - Helpers

    /// Pattern-match helper. Avoids `entries.contains(.removeNetwork(id: ...))`
    /// shorthand because the contextual base resolves ambiguously between the
    /// `RecordingRuntime.Entry.removeNetwork(id:)` enum case and the
    /// `Runtime.removeNetwork(id:)` protocol method.
    private static func containsRemoveNetwork(_ entries: [RecordingRuntime.Entry], id expected: String) -> Bool {
        entries.contains { entry in
            if case .removeNetwork(let id) = entry { return id == expected }
            return false
        }
    }

    private static func makeProject(yaml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "compose-down-net-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try yaml.write(to: directory.appending(path: "compose.yml"), atomically: true, encoding: .utf8)
        return directory
    }
}
