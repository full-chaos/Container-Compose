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

    @Test("create() routes through the bound provider and returns created snapshot")
    func createRoutesThroughProvider() async throws {
        let recorder = RecordingContainerClientProvider()
        let bridge = BridgeContainerClientRuntime()
        let container = try await ContainerClientEnvironment.$current.withValue(recorder) {
            try await bridge.create(
                id: "web",
                configuration: RuntimeCreateConfiguration(
                    imageReference: "alpine:3",
                    command: ["/bin/echo", "hi"],
                    publishedPorts: [
                        RuntimePublishedPort(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, proto: .tcp)
                    ]
                )
            )
        }
        #expect(container.id == "web")
        #expect(container.imageReference == "alpine:3")
        #expect(container.status == .stopped)
        #expect(container.publishedPorts == [
            RuntimePublishedPort(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80, proto: .tcp)
        ])
        #expect(await recorder.entriesSnapshot() == [.create(id: "web", imageReference: "alpine:3")])
    }

    @Test("start/kill route through provider; wait remains notSupported")
    func lifecycleWritesRouteThroughProvider() async throws {
        let recorder = RecordingContainerClientProvider()
        let bridge = BridgeContainerClientRuntime()
        try await ContainerClientEnvironment.$current.withValue(recorder) {
            try await bridge.start(id: "x")
            try await bridge.kill(id: "x", signal: 9)
        }
        #expect(await recorder.entriesSnapshot() == [.start(id: "x"), .kill(id: "x", signal: 9)])
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

// MARK: - makeBuildArgv field-by-field (CHAOS-1429 review)

/// Closes Codex review finding #2: bridge build argv must mirror
/// `ComposeBuild.buildService` field-by-field, not just emit context +
/// dockerfile + tag + no-cache. Direct unit tests against the pure
/// `makeBuildArgv` helper so each compose `build:` directive has explicit
/// coverage.
@Suite("BridgeContainerClientRuntime.makeBuildArgv — CHAOS-1429 review")
struct MakeBuildArgvTests {

    private static let bareSpec = RuntimeBuildSpec(service: "web")
    private static let bareContext = BuildContext(contextPath: "./web", dockerfile: nil)

    // MARK: - Baseline

    @Test("baseline: context, default dockerfile, qualified tag, default platform/cpus/memory")
    func baselineEmission() throws {
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(
            spec: Self.bareSpec,
            context: Self.bareContext
        )
        let argv = plan.argv

        #expect(argv.first == "./web", "context path is positional first arg")
        #expect(argv.contains("Dockerfile"), "default dockerfile when none specified")
        #expect(argv.contains("--os"))
        #expect(argv.contains("linux"))
        #expect(argv.contains("--arch"))
        #expect(argv.contains("arm64"))
        #expect(argv.contains("--cpus"))
        #expect(argv.contains("2"))
        #expect(argv.contains("--memory"))
        #expect(argv.contains("2048MB"))
        #expect(plan.inlineTempPath == nil, "no tempfile for non-inline path")
    }

    // MARK: - Single-field expansions

    @Test("--build-arg emitted per (key, value) pair, verbatim (no env resolution)")
    func buildArgsEmitted() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            args: ["FOO": "bar", "BAZ": "${UNRESOLVED}"]
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(
            spec: Self.bareSpec,
            context: context
        )

        // --build-arg key=value occurs for each entry; iteration order varies.
        #expect(plan.argv.contains("--build-arg"))
        #expect(plan.argv.contains("FOO=bar"))
        // Verbatim — bridge does NOT resolve `${UNRESOLVED}`. CLI does this
        // via resolveVariable; bridge defers it.
        #expect(plan.argv.contains("BAZ=${UNRESOLVED}"))
    }

    @Test("--target emitted when build.target is set")
    func targetEmitted() throws {
        let context = BuildContext(contextPath: "./web", dockerfile: nil, target: "production")
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)
        let pairs = zip(plan.argv, plan.argv.dropFirst())
        #expect(pairs.contains(where: { $0.0 == "--target" && $0.1 == "production" }))
    }

    @Test("--label emitted per entry")
    func labelsEmitted() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            labels: ["maintainer": "alice@example.com", "version": "1.0"]
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)
        #expect(plan.argv.filter { $0 == "--label" }.count == 2)
        #expect(plan.argv.contains("maintainer=alice@example.com"))
        #expect(plan.argv.contains("version=1.0"))
    }

    @Test("--secret id=<id> emitted per entry")
    func secretsEmitted() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            secrets: ["db-password", "api-key"]
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)
        #expect(plan.argv.filter { $0 == "--secret" }.count == 2)
        #expect(plan.argv.contains("id=db-password"))
        #expect(plan.argv.contains("id=api-key"))
    }

    // MARK: - Platform resolution

    @Test("build.platforms[0] is preferred over service.platform")
    func buildPlatformsWinsOverServicePlatform() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            platforms: ["linux/amd64"],
            servicePlatform: "linux/arm64"
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)
        let pairs = zip(plan.argv, plan.argv.dropFirst())
        #expect(pairs.contains(where: { $0.0 == "--os" && $0.1 == "linux" }))
        #expect(pairs.contains(where: { $0.0 == "--arch" && $0.1 == "amd64" }))
    }

    @Test("first build.platforms entry wins when multiple are declared")
    func firstBuildPlatformWinsOverRest() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            platforms: ["linux/amd64", "linux/arm64"]
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)
        let pairs = zip(plan.argv, plan.argv.dropFirst())
        #expect(pairs.contains(where: { $0.0 == "--arch" && $0.1 == "amd64" }))
        // Second entry must NOT leak into argv as another --arch.
        #expect(plan.argv.filter { $0 == "--arch" }.count == 1)
    }

    @Test("service.platform fallback when build.platforms empty/nil")
    func servicePlatformFallback() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            servicePlatform: "linux/amd64"
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)
        let pairs = zip(plan.argv, plan.argv.dropFirst())
        #expect(pairs.contains(where: { $0.0 == "--arch" && $0.1 == "amd64" }))
    }

    // MARK: - Resource limits

    @Test("custom cpus/memory override defaults")
    func cpusMemoryOverride() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            cpus: "4",
            memory: "4096MB"
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)
        let pairs = zip(plan.argv, plan.argv.dropFirst())
        #expect(pairs.contains(where: { $0.0 == "--cpus" && $0.1 == "4" }))
        #expect(pairs.contains(where: { $0.0 == "--memory" && $0.1 == "4096MB" }))
    }

    @Test("invalid cpus string falls back to default 2 (matches CLI)")
    func cpusInvalidFallback() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            cpus: "not-a-number"
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)
        let pairs = zip(plan.argv, plan.argv.dropFirst())
        #expect(pairs.contains(where: { $0.0 == "--cpus" && $0.1 == "2" }))
    }

    // MARK: - dockerfile_inline

    @Test("dockerfile_inline writes to tempfile and uses --file <tempfile>")
    func dockerfileInlineWritesTempfile() throws {
        let inlineContent = "FROM alpine:3\nRUN echo hello\n"
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            dockerfileInline: inlineContent
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)

        guard let tempPath = plan.inlineTempPath else {
            Issue.record("expected non-nil inlineTempPath for dockerfile_inline path")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        // The argv contains --file <tempPath>, NOT a literal "Dockerfile".
        let pairs = zip(plan.argv, plan.argv.dropFirst())
        #expect(pairs.contains(where: { $0.0 == "--file" && $0.1 == tempPath }))

        // Tempfile contents match.
        let written = try String(contentsOf: URL(filePath: tempPath), encoding: .utf8)
        #expect(written == inlineContent)
    }

    @Test("dockerfile_inline wins over dockerfile when both are set")
    func dockerfileInlinePrecedence() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: "Dockerfile.dev",
            dockerfileInline: "FROM alpine:3\n"
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)
        defer { plan.inlineTempPath.flatMap { try? FileManager.default.removeItem(atPath: $0) } }

        // Dockerfile.dev should NOT appear — inline path wins.
        #expect(!plan.argv.contains("Dockerfile.dev"))
        #expect(plan.inlineTempPath != nil)
    }

    // MARK: - Image tag resolution

    @Test("imageTag pinned in spec bypasses serviceImage and qualifyImageReference")
    func pinnedImageTagBypassesQualification() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            serviceImage: "alpine:custom"
        )
        let spec = RuntimeBuildSpec(service: "web", imageTag: "registry.example.com/web:explicit")
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: spec, context: context)

        let pairs = zip(plan.argv, plan.argv.dropFirst())
        #expect(pairs.contains(where: { $0.0 == "--tag" && $0.1 == "registry.example.com/web:explicit" }))
    }

    @Test("serviceImage preferred over <service>:latest default when imageTag nil")
    func serviceImagePreferredOverDefault() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: nil,
            serviceImage: "myorg/myimage:v2"
        )
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: Self.bareSpec, context: context)
        // The qualified form goes through ComposeUp.qualifyImageReference; we
        // only assert that the source string was "myorg/myimage:v2", not the
        // qualified result, since qualification is opaque to this layer.
        let tagIndex = plan.argv.firstIndex(of: "--tag")!
        let tagValue = plan.argv[plan.argv.index(after: tagIndex)]
        #expect(tagValue.contains("myorg/myimage") || tagValue.contains("myimage:v2"))
    }

    // MARK: - Combined sanity check

    @Test("all directives populated emits every expected flag")
    func fullyPopulatedDirective() throws {
        let context = BuildContext(
            contextPath: "./web",
            dockerfile: "Dockerfile.prod",
            args: ["VERSION": "1.0"],
            target: "runtime",
            labels: ["app": "web"],
            secrets: ["db-pass"],
            platforms: ["linux/amd64"],
            servicePlatform: nil,
            cpus: "4",
            memory: "8192MB",
            serviceImage: nil
        )
        let spec = RuntimeBuildSpec(service: "web", noCache: true)
        let plan = try BridgeContainerClientRuntime.makeBuildArgv(spec: spec, context: context)

        let argv = plan.argv
        #expect(argv.first == "./web")
        #expect(argv.contains("--build-arg"))
        #expect(argv.contains("VERSION=1.0"))
        #expect(argv.contains("Dockerfile.prod"))
        #expect(argv.contains("--no-cache"))
        #expect(argv.contains("--target"))
        #expect(argv.contains("runtime"))
        #expect(argv.contains("--label"))
        #expect(argv.contains("app=web"))
        #expect(argv.contains("--secret"))
        #expect(argv.contains("id=db-pass"))
        #expect(argv.contains("amd64"))
        #expect(argv.contains("--cpus"))
        #expect(argv.contains("4"))
        #expect(argv.contains("8192MB"))
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

// MARK: - Bridge Failure Paths (CHAOS-1433)

/// Drives the `.failed` event arm of `BridgeContainerClientRuntime.pull` and
/// `.build` via `RecordingRunner.stubThrow`. Before CHAOS-1433 these arms
/// were structurally unreachable from tests because the previous stub API
/// returned non-zero exits (which production never produces for `.swiftAPI`).
@Suite(".swiftAPI failure event arms — CHAOS-1433")
struct BridgeContainerClientRuntimeFailureTests {

    /// Sendable error used to drive the throwing branch of `RecordingRunner`.
    /// `localizedDescription` falls back to `String(describing:)` for `Error`
    /// types without explicit `LocalizedError` conformance, so the message
    /// surfaces in `RuntimeBuildEvent.message` / `RuntimePullEvent.message`.
    private struct StubError: Error, CustomStringConvertible {
        let description: String
    }

    private func ingestSingleBuildProject(name: String) async throws -> ProjectRegistry {
        let yaml = """
        services:
          web:
            build: ./web
        """
        let reg = ProjectRegistry()
        _ = try await ProjectOrchestrator.ingest(
            projectName: name,
            yaml: Data(yaml.utf8),
            registry: reg
        )
        return reg
    }

    @Test("build() emits .failed when BuildCommand throws")
    func buildEmitsFailedWhenBuildCommandThrows() async throws {
        let registry = try await ingestSingleBuildProject(name: "myapp")
        let runner = RecordingRunner()
        await runner.stubThrow(
            swiftAPIName: "BuildCommand",
            error: StubError(description: "build kaboom")
        )

        let bridge = BridgeContainerClientRuntime()
        let specs = [RuntimeBuildSpec(service: "web", projectName: "myapp")]

        var events: [RuntimeBuildEvent] = []
        try await RuntimeEnvironment.$projectRegistry.withValue(registry) {
            try await RunnerEnvironment.$current.withValue(runner) {
                let stream = try await bridge.build(specs: specs)
                for await event in stream { events.append(event) }
            }
        }

        #expect(events.map(\.kind) == [.started, .failed])
        #expect(events.last?.service == "web")
        #expect(events.last?.message != nil, "expected non-nil failure message")
    }

    @Test("pull() emits .failed when ImagePull throws")
    func pullEmitsFailedWhenImagePullThrows() async throws {
        let runner = RecordingRunner()
        await runner.stubThrow(
            swiftAPIName: "ImagePull",
            error: StubError(description: "pull kaboom")
        )

        let bridge = BridgeContainerClientRuntime()
        let specs = [RuntimePullSpec(service: "web", imageReference: "missing:latest")]

        var events: [RuntimePullEvent] = []
        try await RunnerEnvironment.$current.withValue(runner) {
            let stream = try await bridge.pull(specs: specs, ignoreFailures: false)
            for await event in stream { events.append(event) }
        }

        #expect(events.map(\.kind) == [.started, .failed])
        #expect(events.last?.service == "web")
        #expect(events.last?.message != nil)
    }

    @Test("pull() with ignoreFailures=true continues past .failed across multiple specs")
    func pullContinuesPastFailureWhenIgnoreFailuresTrue() async throws {
        let runner = RecordingRunner()
        await runner.stubThrow(
            swiftAPIName: "ImagePull",
            error: StubError(description: "broken")
        )

        let bridge = BridgeContainerClientRuntime()
        let specs = [
            RuntimePullSpec(service: "web", imageReference: "broken-a:latest"),
            RuntimePullSpec(service: "db", imageReference: "broken-b:latest"),
        ]

        var events: [RuntimePullEvent] = []
        try await RunnerEnvironment.$current.withValue(runner) {
            let stream = try await bridge.pull(specs: specs, ignoreFailures: true)
            for await event in stream { events.append(event) }
        }

        // Both services attempted: started + failed for each.
        #expect(events.count == 4)
        #expect(events.filter { $0.kind == .started }.count == 2)
        #expect(events.filter { $0.kind == .failed }.count == 2)
    }

    @Test("pull() with ignoreFailures=false stops after first .failed")
    func pullStopsAfterFirstFailureWhenIgnoreFailuresFalse() async throws {
        let runner = RecordingRunner()
        await runner.stubThrow(
            swiftAPIName: "ImagePull",
            error: StubError(description: "broken")
        )

        let bridge = BridgeContainerClientRuntime()
        let specs = [
            RuntimePullSpec(service: "first", imageReference: "broken-a:latest"),
            RuntimePullSpec(service: "second", imageReference: "broken-b:latest"),
        ]

        var events: [RuntimePullEvent] = []
        try await RunnerEnvironment.$current.withValue(runner) {
            let stream = try await bridge.pull(specs: specs, ignoreFailures: false)
            for await event in stream { events.append(event) }
        }

        // Only the first spec gets started + failed; loop breaks before "second".
        #expect(events.count == 2)
        #expect(events[0].service == "first")
        #expect(events[1].service == "first")
        #expect(events[1].kind == .failed)
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
