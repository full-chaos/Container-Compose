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
import ContainerAPIClient
import ContainerResource
import ContainerizationError
@testable import ContainerComposeCore
import TestHelpers

@Suite("BridgeContainerClientRuntime delegates to ContainerClientProvider")
struct BridgeContainerClientRuntimeTests {

    @Test("list() routes through the bound provider")
    func listRoutesThroughProvider() async throws {
        let recorder = RecordingContainerClientProvider()
        let bridge = BridgeContainerClientRuntime()
        try await ContainerClientEnvironment.$current.withValue(recorder) {
            let containers = try await bridge.list(filters: .all)
            #expect(containers.isEmpty)
        }
        let entries = await recorder.entriesSnapshot()
        #expect(entries.contains(.list(filters: String(describing: ContainerListFilters.all))))
    }

    @Test("get() throws notFound when provider has no container")
    func getThrowsNotFound() async throws {
        let recorder = RecordingContainerClientProvider()
        let bridge = BridgeContainerClientRuntime()
        await ContainerClientEnvironment.$current.withValue(recorder) {
            await #expect(throws: RuntimeError.self) {
                _ = try await bridge.get(id: "ghost")
            }
        }
    }

    @Test("create() throws notSupported (Phase 1 contract)")
    func createIsUnsupported() async throws {
        let bridge = BridgeContainerClientRuntime()
        await #expect(throws: RuntimeError.self) {
            _ = try await bridge.create(
                id: "x",
                configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
            )
        }
    }

    @Test("start/kill/wait/statistics throw notSupported")
    func writeAndStreamPathsAreUnsupported() async {
        let bridge = BridgeContainerClientRuntime()
        await #expect(throws: RuntimeError.self) { try await bridge.start(id: "x") }
        await #expect(throws: RuntimeError.self) { try await bridge.kill(id: "x", signal: 9) }
        await #expect(throws: RuntimeError.self) { _ = try await bridge.wait(id: "x", timeoutSeconds: 1) }
    }

    @Test("statistics() maps upstream notFound semantics to RuntimeError.notFound")
    func statisticsMapsNotFound() async throws {
        let upstream = ContainerizationError(.internalError, message: "failed to get statistics", cause: ContainerizationError(.notFound, message: "container ghost not found"))
        let provider = BridgeStatisticsProvider(statsError: upstream)
        let bridge = BridgeContainerClientRuntime()

        await ContainerClientEnvironment.$current.withValue(provider) {
            await #expect(throws: RuntimeError.notFound(id: "ghost")) {
                _ = try await bridge.statistics(for: "ghost")
            }
        }
    }

    @Test("statistics() maps non-notFound upstream failures to RuntimeError.backendFailure")
    func statisticsMapsBackendFailure() async throws {
        let provider = BridgeStatisticsProvider(
            statsError: ContainerizationError(.timeout, message: "daemon request timed out")
        )
        let bridge = BridgeContainerClientRuntime()

        await ContainerClientEnvironment.$current.withValue(provider) {
            await #expect(throws: RuntimeError.backendFailure(message: "stats failed for 'web': daemon request timed out")) {
                _ = try await bridge.statistics(for: "web")
            }
        }
    }

    @Test("logs() routes through provider and emits RuntimeLogFrame lines")
    func logsRouteThroughProvider() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bridge-logs-\(UUID().uuidString).log")
        try Data("one\ntwo\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forReadingFrom: url)
        let recorder = RecordingContainerClientProvider(logHandles: [handle])
        let bridge = BridgeContainerClientRuntime()
        let frames = try await ContainerClientEnvironment.$current.withValue(recorder) {
            let stream = try await bridge.logs(id: "web", options: RuntimeLogOptions(follow: false, tail: 1, since: nil, timestamps: true))
            var result: [RuntimeLogFrame] = []
            for await frame in stream {
                result.append(frame)
            }
            return result
        }

        #expect(frames.map { String(decoding: $0.data, as: UTF8.self) } == ["two"])
        #expect(frames.map(\.source) == [.stdout])
        #expect(await recorder.entriesSnapshot() == [.logs(id: "web")])
    }

    @Test("events() routes through provider and translates ContainerEvent actions")
    func eventsRouteThroughProvider() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_770_000_000)
        let recorder = RecordingContainerClientProvider(containerEvents: [
            ContainerEvent(containerId: "web", action: .start, timestamp: timestamp)
        ])
        let bridge = BridgeContainerClientRuntime()
        let first = try await ContainerClientEnvironment.$current.withValue(recorder) {
            let stream = try await bridge.events()
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        #expect(first == .started(id: "web", at: timestamp))
        #expect(await recorder.entriesSnapshot() == [.events])
    }
}

// MARK: - Bridge Build (CHAOS-1429)

@Suite("BridgeContainerClientRuntime.build() — CHAOS-1429")
struct BridgeContainerClientRuntimeBuildTests {

    // MARK: - Helpers

    /// YAML for a project with two services that both declare `build:` directives.
    private static let twoBuildServicesYAML = """
    services:
      web:
        build:
          context: ./web
          dockerfile: Dockerfile.web
      worker:
        build: ./worker
    """

    /// YAML for a project with only image-based services (no `build:` directives).
    private static let imageOnlyYAML = """
    services:
      web:
        image: nginx:1.27
      db:
        image: postgres:16
    """

    /// Ingest a project with the given YAML into a fresh registry using
    /// `ProjectOrchestrator.ingest` (which owns YAML decoding), returning the
    /// registry.  The caller binds it as a task-local via
    /// `RuntimeEnvironment.$projectRegistry`.
    private func ingest(yaml: String, as projectName: String) async throws -> ProjectRegistry {
        let reg = ProjectRegistry()
        _ = try await ProjectOrchestrator.ingest(
            projectName: projectName,
            yaml: Data(yaml.utf8),
            registry: reg
        )
        return reg
    }

    // MARK: - Success path

    @Test("build() emits started+completed for each service with a build context in the registry")
    func buildSuccessEmitsStartedCompleted() async throws {
        let registry = try await ingest(yaml: Self.twoBuildServicesYAML, as: "myapp")
        let runner = RecordingRunner()

        let bridge = BridgeContainerClientRuntime()
        let specs = [
            RuntimeBuildSpec(service: "web", projectName: "myapp"),
            RuntimeBuildSpec(service: "worker", projectName: "myapp"),
        ]

        var events: [RuntimeBuildEvent] = []
        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await RunnerEnvironment.$current.withValue(runner) {
                let stream = try await bridge.build(specs: specs)
                for await event in stream { events.append(event) }
            }
        }

        // Expect started+completed for web and worker (order matches specs).
        #expect(events.count == 4)
        #expect(events[0].kind == .started);  #expect(events[0].service == "web")
        #expect(events[1].kind == .completed); #expect(events[1].service == "web")
        #expect(events[2].kind == .started);  #expect(events[2].service == "worker")
        #expect(events[3].kind == .completed); #expect(events[3].service == "worker")

        // Verify BuildCommand was invoked twice with the correct context paths.
        let buildCalls = await runner.swiftAPIArgvs(named: "BuildCommand")
        #expect(buildCalls.count == 2)

        // web: context=./web, dockerfile=Dockerfile.web
        #expect(buildCalls[0].first == "./web")
        #expect(buildCalls[0].contains("Dockerfile.web"))

        // worker: context=./worker, dockerfile=Dockerfile (default)
        #expect(buildCalls[1].first == "./worker")
        #expect(buildCalls[1].contains("Dockerfile"))
    }

    @Test("build() passes --no-cache when spec.noCache is true")
    func buildPassesNoCacheFlag() async throws {
        let registry = try await ingest(yaml: Self.twoBuildServicesYAML, as: "myapp")
        let runner = RecordingRunner()
        let bridge = BridgeContainerClientRuntime()

        let specs = [RuntimeBuildSpec(service: "web", noCache: true, projectName: "myapp")]

        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await RunnerEnvironment.$current.withValue(runner) {
                let stream = try await bridge.build(specs: specs)
                for await _ in stream {}
            }
        }

        let buildCalls = await runner.swiftAPIArgvs(named: "BuildCommand")
        #expect(buildCalls.first?.contains("--no-cache") == true)
    }

    // MARK: - No build context

    @Test("build() emits notSupported when project has no build: directives")
    func buildEmitsNotSupportedForImageOnlyProject() async throws {
        let registry = try await ingest(yaml: Self.imageOnlyYAML, as: "imageonly")
        let runner = RecordingRunner()
        let bridge = BridgeContainerClientRuntime()

        let specs = [
            RuntimeBuildSpec(service: "web", projectName: "imageonly"),
            RuntimeBuildSpec(service: "db", projectName: "imageonly"),
        ]

        var events: [RuntimeBuildEvent] = []
        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await RunnerEnvironment.$current.withValue(runner) {
                let stream = try await bridge.build(specs: specs)
                for await event in stream { events.append(event) }
            }
        }

        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.kind == .notSupported })
        // No BuildCommand calls should be made.
        let buildCalls = await runner.swiftAPIArgvs(named: "BuildCommand")
        #expect(buildCalls.isEmpty)
    }

    @Test("build() emits notSupported when projectName is nil and contextPath is nil")
    func buildEmitsNotSupportedWhenNoContextAvailable() async throws {
        let runner = RecordingRunner()
        let bridge = BridgeContainerClientRuntime()

        // Spec with neither projectName nor contextPath.
        let specs = [RuntimeBuildSpec(service: "web")]

        var events: [RuntimeBuildEvent] = []
        try await RunnerEnvironment.$current.withValue(runner) {
            let stream = try await bridge.build(specs: specs)
            for await event in stream { events.append(event) }
        }

        #expect(events.count == 1)
        #expect(events[0].kind == .notSupported)
        #expect(events[0].service == "web")
    }

    @Test("build() emits notSupported when project is not registered")
    func buildEmitsNotSupportedForUnknownProject() async throws {
        let registry = ProjectRegistry() // empty registry — project never ingested
        let runner = RecordingRunner()
        let bridge = BridgeContainerClientRuntime()

        let specs = [RuntimeBuildSpec(service: "web", projectName: "ghost")]

        var events: [RuntimeBuildEvent] = []
        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await RunnerEnvironment.$current.withValue(runner) {
                let stream = try await bridge.build(specs: specs)
                for await event in stream { events.append(event) }
            }
        }

        #expect(events.count == 1)
        #expect(events[0].kind == .notSupported)
    }

    // MARK: - Spec with explicit contextPath (no registry needed)

    @Test("build() uses spec.contextPath directly when set, bypassing registry")
    func buildUsesExplicitContextPath() async throws {
        let runner = RecordingRunner()
        let bridge = BridgeContainerClientRuntime()

        let specs = [
            RuntimeBuildSpec(
                service: "api",
                contextPath: "/absolute/path/to/api",
                dockerfile: "Dockerfile.api"
            )
        ]

        var events: [RuntimeBuildEvent] = []
        try await RunnerEnvironment.$current.withValue(runner) {
            let stream = try await bridge.build(specs: specs)
            for await event in stream { events.append(event) }
        }

        #expect(events.map(\.kind) == [.started, .completed])

        let buildCalls = await runner.swiftAPIArgvs(named: "BuildCommand")
        #expect(buildCalls.count == 1)
        #expect(buildCalls[0].first == "/absolute/path/to/api")
        #expect(buildCalls[0].contains("Dockerfile.api"))
    }
}

// MARK: - Build target resolution (CHAOS-1429 review)

/// Closes Codex review finding #1: `buildStream` must consult `ProjectRegistry`
/// when no explicit `services` are given and no containers exist yet —
/// otherwise the canonical "ingest then build" daemon-API flow always reports
/// "No services to build" because a freshly ingested project has zero
/// containers running.
@Suite("ProjectOrchestrator.buildStream service-name resolution — CHAOS-1429 review")
struct BuildStreamServiceResolutionTests {

    private static let twoBuildServicesYAML = """
    services:
      web:
        build: ./web
      db:
        build: ./db
    """

    private func ingest(yaml: String, as projectName: String) async throws -> ProjectRegistry {
        let reg = ProjectRegistry()
        _ = try await ProjectOrchestrator.ingest(
            projectName: projectName,
            yaml: Data(yaml.utf8),
            registry: reg
        )
        return reg
    }

    @Test("buildStream falls back to ProjectRegistry when no explicit services and no containers")
    func registryFallbackUsedWhenContainersAbsent() async throws {
        let registry = try await ingest(yaml: Self.twoBuildServicesYAML, as: "myapp")
        let runtime = MockRuntime()  // empty container list
        await runtime.injectBuildOutcome(service: "web", outcome: .successful)
        await runtime.injectBuildOutcome(service: "db", outcome: .successful)

        var seenServices: Set<String> = []
        var sawErrorFrame = false
        await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            let stream = ProjectOrchestrator.buildStream(
                project: "myapp",
                services: nil,
                noCache: false,
                pull: false,
                runtime: runtime
            )
            for await frame in stream {
                seenServices.insert(frame.service)
                if frame.type == "error" && frame.line.contains("No services to build") {
                    sawErrorFrame = true
                }
            }
        }

        #expect(!sawErrorFrame, "registry fallback must avoid 'No services to build' for ingested projects")
        #expect(seenServices.contains("web"), "web should be derived from registry entry")
        #expect(seenServices.contains("db"), "db should be derived from registry entry")
    }

    @Test("buildStream prefers explicit services over registry")
    func explicitServicesWinOverRegistry() async throws {
        let registry = try await ingest(yaml: Self.twoBuildServicesYAML, as: "myapp")
        let runtime = MockRuntime()
        await runtime.injectBuildOutcome(service: "web", outcome: .successful)

        var seenServices: Set<String> = []
        await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            let stream = ProjectOrchestrator.buildStream(
                project: "myapp",
                services: ["web"],
                noCache: false,
                pull: false,
                runtime: runtime
            )
            for await frame in stream {
                seenServices.insert(frame.service)
            }
        }

        // Explicit `services: ["web"]` must win — db should NOT be built even
        // though the registry has it.
        #expect(seenServices.contains("web"))
        #expect(!seenServices.contains("db"), "db must not be built when services=[\"web\"]")
    }

    @Test("buildStream still emits 'No services to build' when registry is empty AND no containers")
    func emptyRegistryAndContainersStillEmits() async throws {
        let registry = ProjectRegistry()  // empty registry — project never ingested
        let runtime = MockRuntime()       // no containers

        var sawErrorFrame = false
        await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            let stream = ProjectOrchestrator.buildStream(
                project: "ghost",
                services: nil,
                noCache: false,
                pull: false,
                runtime: runtime
            )
            for await frame in stream {
                if frame.type == "error" && frame.line.contains("No services to build") {
                    sawErrorFrame = true
                }
            }
        }

        #expect(sawErrorFrame, "fallback should still report 'No services to build' when both sources are empty")
    }
}

private actor BridgeStatisticsProvider: ContainerClientProvider {
    let statsError: ContainerizationError

    init(statsError: ContainerizationError) {
        self.statsError = statsError
    }

    func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] { [] }
    func get(id: String) async throws -> ContainerSnapshot {
        throw ContainerizationError(.notFound, message: "container \(id) not found")
    }
    func stop(id: String, opts: ContainerStopOptions) async throws {}
    func delete(id: String, force: Bool) async throws {}
    func logs(id: String) async throws -> [FileHandle] { [] }
    func logs(id: String, options: ContainerLogOptions) async throws -> [FileHandle] { [] }
    func networkGet(id: String) async throws -> NetworkState {
        throw ContainerizationError(.notFound, message: "network \(id) not found")
    }
    func events() async throws -> [ContainerEvent] { [] }
    func imageList() async throws -> [ClientImage] { [] }
    func stats(id: String) async throws -> ContainerStats {
        throw statsError
    }
    func kill(id: String, signal: Int32) async throws {}
    func start(id: String) async throws {}
}
