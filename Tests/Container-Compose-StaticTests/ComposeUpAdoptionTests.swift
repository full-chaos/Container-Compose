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

import Testing
import Foundation
import Yams
import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
@testable import ContainerComposeCore
import TestHelpers

// MARK: - CHAOS-1492 adoption-by-default tests
//
// Pre-PR behaviour: `compose up` ALWAYS stop+removed every project container
// at the top of `run()` and recreated it from scratch. Post-PR behaviour:
// matching existing containers are ADOPTED (no stop, no delete, no fresh
// `container run`), divergent ones are stop+recreated, and `--force-recreate`
// forces recreation even on a clean match.
//
// Three layers of coverage:
//
// 1. Direct unit tests on `resolveAdoption` / `applyRecreations` /
//    `specDivergenceReason` — narrow assertions on the decision shape and
//    the side-effects of the recreate sweep.
//
// 2. End-to-end `cmd.run()` tests through the recorded provider + recorded
//    runner. These pin argv shape (e.g. `container run` is or isn't
//    emitted) and provider entries (e.g. `.stop` / `.delete` are or aren't
//    recorded for a given id). They use the `cc-test-` project-name prefix
//    convention from AGENTS.md.
//
// 3. Persistence-on-failure: when `cmd.run()` throws mid-flight (image
//    pull failure for one service), no teardown argv is emitted for ANY
//    project container. Verifies absence of a `defer { stopOldStuff(...) }`
//    block.

@Suite("ComposeUp adoption (CHAOS-1492)", .serialized)
struct ComposeUpAdoptionTests {

    // MARK: - Local test helpers

    /// `ContainerClientProvider` wrapper that lets tests stub `get(id:)`
    /// answers per-id while still recording the call. Other methods
    /// delegate to the inner `RecordingContainerClientProvider`.
    ///
    /// `get(id:)` looks up `stubs[id]` first; on hit it returns the stub
    /// AND records a `.get(id:)` entry on the inner recorder. On miss it
    /// delegates to the inner recorder (which records and throws "no
    /// container", mimicking apple/container's not-found shape).
    private actor StubbingContainerProvider: ContainerClientProvider {
        private let inner: RecordingContainerClientProvider
        private var stubs: [String: ContainerSnapshot]

        init(_ inner: RecordingContainerClientProvider, stubs: [String: ContainerSnapshot] = [:]) {
            self.inner = inner
            self.stubs = stubs
        }

        func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> ContainerSnapshot {
            try await inner.create(id: id, configuration: configuration)
        }

        func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] {
            try await inner.list(filters: filters)
        }

        func get(id: String) async throws -> ContainerSnapshot {
            if let snapshot = stubs[id] {
                // Record on the inner so `entriesSnapshot()` reflects that
                // the call happened, then return the stub directly.
                _ = try? await inner.get(id: id)
                return snapshot
            }
            return try await inner.get(id: id)
        }

        func stop(id: String, opts: ContainerStopOptions) async throws {
            try await inner.stop(id: id, opts: opts)
        }

        func delete(id: String, force: Bool) async throws {
            try await inner.delete(id: id, force: force)
        }

        func logs(id: String) async throws -> [FileHandle] {
            try await inner.logs(id: id)
        }

        func logs(id: String, options: ContainerLogOptions) async throws -> [FileHandle] {
            try await inner.logs(id: id, options: options)
        }

        func networkGet(id: String) async throws -> NetworkState {
            try await inner.networkGet(id: id)
        }

        func imageList() async throws -> [ClientImage] {
            try await inner.imageList()
        }

        func events() async throws -> [ContainerEvent] {
            try await inner.events()
        }

        func stats(id: String) async throws -> ContainerStats {
            try await inner.stats(id: id)
        }

        func kill(id: String, signal: Int32) async throws {
            try await inner.kill(id: id, signal: signal)
        }

        func start(id: String) async throws {
            try await inner.start(id: id)
        }

        func entriesSnapshot() async -> [RecordingContainerClientProvider.Entry] {
            await inner.entriesSnapshot()
        }
    }

    /// Build a minimal `ContainerSnapshot` for a stubbed running container.
    /// `id` becomes both the configuration's id and (in callers' stub maps)
    /// the dictionary key, so `provider.stop(id: container.id, ...)` records
    /// a `.stop(id: id)` entry that tests can match by name.
    private static func makeRunningSnapshot(id: String, imageReference: String) -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [String](),
            workingDirectory: "/"
        )
        let config = ContainerConfiguration(
            id: id,
            image: ImageDescription(
                reference: imageReference,
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:\(String(repeating: "0", count: 64))",
                    size: 0
                )
            ),
            process: process
        )
        return ContainerSnapshot(configuration: config, status: .running, networks: [])
    }

    private static func makeProject(yaml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "compose-adopt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try yaml.write(to: directory.appending(path: "compose.yml"), atomically: true, encoding: .utf8)
        return directory
    }

    private static func containsRunArgvFor(_ runner: RecordingRunner, containerName: String) async -> Bool {
        let entries = await runner.recordedRequests()
        for entry in entries {
            let argv = entry.request.argv
            // `container run` argv emitted by `launchService` always begins
            // with `["container", "run"]` and includes `--name <name>` for
            // the target container.
            guard argv.starts(with: ["container", "run"]) else { continue }
            // Look for `--name <name>` pair in the argv.
            for index in argv.indices.dropLast() {
                if argv[index] == "--name" && argv[index + 1] == containerName {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Direct unit tests on resolveAdoption / specDivergenceReason

    @Test("resolveAdoption returns .create when no existing container")
    func resolvesCreateWhenAbsent() async throws {
        let services: [(serviceName: String, service: Service)] = [
            (serviceName: "web", service: Service(image: "alpine:latest"))
        ]
        var cmd = try ComposeUp.parse([])
        cmd.projectName = "cc-test-adopt-create"

        let provider = RecordingContainerClientProvider()
        let decisions = try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.resolveAdoption(services)
        }

        #expect(decisions["web"] == .create)
    }

    @Test("resolveAdoption returns .adopt when existing container matches image")
    func resolvesAdoptWhenMatching() async throws {
        let projectName = "cc-test-adopt-match"
        let containerName = "\(projectName)-web"
        let services: [(serviceName: String, service: Service)] = [
            (serviceName: "web", service: Service(image: "alpine:latest"))
        ]
        var cmd = try ComposeUp.parse([])
        cmd.projectName = projectName

        let inner = RecordingContainerClientProvider()
        let provider = StubbingContainerProvider(inner, stubs: [
            containerName: Self.makeRunningSnapshot(
                id: containerName,
                imageReference: "docker.io/library/alpine:latest"
            )
        ])

        let decisions = try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.resolveAdoption(services)
        }

        let webDecision = decisions["web"]
        #expect(webDecision == .adopt, "expected .adopt; got \(String(describing: webDecision))")
    }

    @Test("resolveAdoption returns .recreate when existing container has different image")
    func resolvesRecreateWhenImageDivergent() async throws {
        let projectName = "cc-test-adopt-drift"
        let containerName = "\(projectName)-web"
        let services: [(serviceName: String, service: Service)] = [
            (serviceName: "web", service: Service(image: "alpine:latest"))
        ]
        var cmd = try ComposeUp.parse([])
        cmd.projectName = projectName

        let inner = RecordingContainerClientProvider()
        let provider = StubbingContainerProvider(inner, stubs: [
            containerName: Self.makeRunningSnapshot(
                id: containerName,
                imageReference: "docker.io/library/redis:latest"
            )
        ])

        let decisions = try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.resolveAdoption(services)
        }

        guard case .recreate(let reason) = decisions["web"] else {
            Issue.record("expected .recreate; got \(String(describing: decisions["web"]))")
            return
        }
        #expect(reason.contains("image changed"), "reason should mention image change; got '\(reason)'")
        #expect(reason.contains("redis"), "reason should mention old image; got '\(reason)'")
        #expect(reason.contains("alpine"), "reason should mention new image; got '\(reason)'")
    }

    @Test("resolveAdoption returns .recreate(--force-recreate) when forceRecreate is set even with match")
    func resolvesRecreateOnForceFlag() async throws {
        let projectName = "cc-test-adopt-force"
        let containerName = "\(projectName)-web"
        let services: [(serviceName: String, service: Service)] = [
            (serviceName: "web", service: Service(image: "alpine:latest"))
        ]
        var cmd = try ComposeUp.parse(["--force-recreate"])
        cmd.projectName = projectName

        let inner = RecordingContainerClientProvider()
        let provider = StubbingContainerProvider(inner, stubs: [
            containerName: Self.makeRunningSnapshot(
                id: containerName,
                imageReference: "docker.io/library/alpine:latest"
            )
        ])

        let decisions = try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.resolveAdoption(services)
        }

        guard case .recreate(let reason) = decisions["web"] else {
            Issue.record("expected .recreate; got \(String(describing: decisions["web"]))")
            return
        }
        #expect(reason == "--force-recreate", "reason should pin to flag; got '\(reason)'")
    }

    @Test("specDivergenceReason returns nil for build-only services (no image field)")
    func divergenceNilForBuildOnly() async throws {
        // Build-only service: no `image:`. Drift detection skips because the
        // effective image reference comes from the build pipeline, not the
        // compose file. Tracking that drift is out of scope for v1.
        // We use `image: nil` directly since `Build` has no public
        // memberwise initializer (only `init(from:)` for YAML decoding) —
        // the helper short-circuits on `expected.image == nil` regardless
        // of whether `build` is present.
        let imagelessService = Service(image: nil)
        let snapshot = Self.makeRunningSnapshot(
            id: "x",
            imageReference: "docker.io/library/anything:latest"
        )
        #expect(ComposeUp.specDivergenceReason(existing: snapshot, expected: imagelessService) == nil)
    }

    @Test("specDivergenceReason returns nil when images match in qualified form")
    func divergenceNilOnMatch() async throws {
        let service = Service(image: "alpine:latest")
        // qualifyImageReference("alpine:latest") -> "docker.io/library/alpine:latest"
        let snapshot = Self.makeRunningSnapshot(
            id: "x",
            imageReference: "docker.io/library/alpine:latest"
        )
        #expect(ComposeUp.specDivergenceReason(existing: snapshot, expected: service) == nil)
    }

    @Test("applyRecreations stops+deletes only services flagged .recreate")
    func applyRecreationsTouchesOnlyDivergent() async throws {
        let projectName = "cc-test-adopt-apply"
        let services: [(serviceName: String, service: Service)] = [
            (serviceName: "keep", service: Service(image: "alpine:latest")),
            (serviceName: "drop", service: Service(image: "alpine:latest")),
            (serviceName: "fresh", service: Service(image: "alpine:latest"))
        ]
        var cmd = try ComposeUp.parse([])
        cmd.projectName = projectName

        let inner = RecordingContainerClientProvider()
        let provider = StubbingContainerProvider(inner, stubs: [
            "\(projectName)-keep": Self.makeRunningSnapshot(
                id: "\(projectName)-keep",
                imageReference: "docker.io/library/alpine:latest"
            ),
            "\(projectName)-drop": Self.makeRunningSnapshot(
                id: "\(projectName)-drop",
                imageReference: "docker.io/library/redis:latest"
            )
        ])

        let decisions: [String: AdoptionDecision] = [
            "keep": .adopt,
            "drop": .recreate(reason: "image changed: ... -> ..."),
            "fresh": .create
        ]

        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.applyRecreations(services, decisions: decisions)
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.stop(id: "\(projectName)-drop")),
                "must stop divergent container; got \(entries)")
        #expect(entries.contains(.delete(id: "\(projectName)-drop", force: false)),
                "must delete divergent container; got \(entries)")

        // `keep` and `fresh` must NOT be touched.
        #expect(!entries.contains(.stop(id: "\(projectName)-keep")),
                "must NOT stop adopted container; got \(entries)")
        #expect(!entries.contains(.delete(id: "\(projectName)-keep", force: false)),
                "must NOT delete adopted container; got \(entries)")
        #expect(!entries.contains(.stop(id: "\(projectName)-fresh")),
                "must NOT stop fresh-create container; got \(entries)")
        #expect(!entries.contains(.delete(id: "\(projectName)-fresh", force: false)),
                "must NOT delete fresh-create container; got \(entries)")
    }

    // MARK: - End-to-end cmd.run() tests

    @Test("cmd.run() adopts existing matching container — no stop, no delete, no run argv")
    func endToEndAdoption() async throws {
        let projectName = "cc-test-adopt-e2e-match-\(UUID().uuidString.lowercased())"
        let containerName = "\(projectName)-web"
        let directory = try Self.makeProject(yaml: """
            services:
              web:
                image: alpine:latest
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inner = RecordingContainerClientProvider()
        let provider = StubbingContainerProvider(inner, stubs: [
            containerName: Self.makeRunningSnapshot(
                id: containerName,
                imageReference: "docker.io/library/alpine:latest"
            )
        ])
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()

        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d"])
                    try await command.run()
                }
            }
        }

        let entries = await provider.entriesSnapshot()
        // The probe must happen.
        #expect(entries.contains(.get(id: containerName)),
                "adoption probe must call .get for the effective name; got \(entries)")
        // Adoption forbids stop/delete on a matching container.
        #expect(!entries.contains(.stop(id: containerName)),
                "adopted container must NOT be stopped; got \(entries)")
        #expect(!entries.contains(.delete(id: containerName, force: false)),
                "adopted container must NOT be deleted; got \(entries)")

        // No `container run` argv for the adopted container.
        let didRun = await Self.containsRunArgvFor(runner, containerName: containerName)
        let runArgvs = await runner.argvs()
        #expect(!didRun, "adopted container must NOT trigger `container run`; runner argvs: \(runArgvs)")
    }

    @Test("cmd.run() recreates when existing image differs from compose spec")
    func endToEndRecreateOnDivergence() async throws {
        let projectName = "cc-test-adopt-e2e-drift-\(UUID().uuidString.lowercased())"
        let containerName = "\(projectName)-web"
        let directory = try Self.makeProject(yaml: """
            services:
              web:
                image: alpine:latest
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inner = RecordingContainerClientProvider()
        let provider = StubbingContainerProvider(inner, stubs: [
            containerName: Self.makeRunningSnapshot(
                id: containerName,
                imageReference: "docker.io/library/redis:latest"
            )
        ])
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()

        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d"])
                    try await command.run()
                }
            }
        }

        let entries = await provider.entriesSnapshot()
        // Probe + stop + delete on the diverging container.
        #expect(entries.contains(.get(id: containerName)),
                "expected probe; got \(entries)")
        #expect(entries.contains(.stop(id: containerName)),
                "divergent container must be stopped; got \(entries)")
        #expect(entries.contains(.delete(id: containerName, force: false)),
                "divergent container must be deleted; got \(entries)")

        // Stop must precede delete (sanity check on order).
        let stopIndex = entries.firstIndex(of: .stop(id: containerName))
        let deleteIndex = entries.firstIndex(of: .delete(id: containerName, force: false))
        if let stopIndex, let deleteIndex {
            #expect(stopIndex < deleteIndex, "stop must precede delete; got stop at \(stopIndex), delete at \(deleteIndex)")
        }

        // A new `container run` must fire for the fresh container.
        let didRun = await Self.containsRunArgvFor(runner, containerName: containerName)
        let runArgvs = await runner.argvs()
        #expect(didRun, "recreated container must trigger `container run`; runner argvs: \(runArgvs)")
    }

    @Test("cmd.run() with --force-recreate stops+deletes+runs even when spec matches")
    func endToEndForceRecreate() async throws {
        let projectName = "cc-test-adopt-e2e-force-\(UUID().uuidString.lowercased())"
        let containerName = "\(projectName)-web"
        let directory = try Self.makeProject(yaml: """
            services:
              web:
                image: alpine:latest
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inner = RecordingContainerClientProvider()
        let provider = StubbingContainerProvider(inner, stubs: [
            containerName: Self.makeRunningSnapshot(
                id: containerName,
                imageReference: "docker.io/library/alpine:latest"
            )
        ])
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()

        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d", "--force-recreate"])
                    try await command.run()
                }
            }
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.stop(id: containerName)),
                "force-recreate must stop matching container; got \(entries)")
        #expect(entries.contains(.delete(id: containerName, force: false)),
                "force-recreate must delete matching container; got \(entries)")

        let didRun = await Self.containsRunArgvFor(runner, containerName: containerName)
        let runArgvs = await runner.argvs()
        #expect(didRun, "force-recreate must trigger `container run`; runner argvs: \(runArgvs)")
    }

    @Test("cmd.run() failure mid-flight does NOT tear down predecessor containers")
    func endToEndFailureLeavesPredecessorsRunning() async throws {
        // Two services, no existing containers. Inject a pull failure via
        // the runner's swiftAPI throw stub. `cmd.run()` propagates that
        // error out. Post-throw, NO `.stop` or `.delete` argv may have been
        // emitted for either service — proving there is no
        // `defer { stopOldStuff(...) }` block tearing down predecessors.
        let projectName = "cc-test-adopt-e2e-fail-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              alpha:
                image: alpine:latest
              beta:
                image: redis:latest
                depends_on:
                  - alpha
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inner = RecordingContainerClientProvider()
        let provider = StubbingContainerProvider(inner, stubs: [:])
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()
        await runner.stubThrow(
            swiftAPIName: "ImagePull",
            error: NSError(
                domain: "TestImagePullFailure",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "synthetic pull failure for CHAOS-1492 persistence test"]
            )
        )

        var didThrow = false
        do {
            try await ContainerClientEnvironment.$current.withValue(provider) {
                try await RuntimeEnvironment.$current.withValue(runtime) {
                    try await RunnerEnvironment.$current.withValue(runner) {
                        var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d"])
                        try await command.run()
                    }
                }
            }
        } catch {
            didThrow = true
        }

        #expect(didThrow, "cmd.run() must propagate the pull failure")

        let entries = await provider.entriesSnapshot()
        let stopEntries = entries.filter { entry in
            if case .stop = entry { return true }
            return false
        }
        let deleteEntries = entries.filter { entry in
            if case .delete = entry { return true }
            return false
        }
        #expect(stopEntries.isEmpty,
                "mid-flight failure must NOT trigger ANY stop; got \(stopEntries)")
        #expect(deleteEntries.isEmpty,
                "mid-flight failure must NOT trigger ANY delete; got \(deleteEntries)")
    }
}
