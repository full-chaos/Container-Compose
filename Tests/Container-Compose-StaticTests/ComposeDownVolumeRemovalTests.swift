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

/// Regression coverage for CHAOS-1398: `compose down` previously had no way to
/// remove named volumes, leaving them registered in apple/container's volume
/// store across runs. This contradicted user expectation (matching
/// `docker compose down -v`) and combined with the up-side idempotency bug to
/// produce hard failures on re-runs.
///
/// Behavior locked in here:
/// - `down -v` / `down --volumes` parses
/// - Full project `down -v` removes every top-level named volume except externals
/// - `down` without `-v` does NOT touch volumes
/// - Partial `down -v <service>` only removes volumes exclusive to the targeted
///   services; volumes shared with sibling services outside the target are kept
///   (matches the `cleanupConfigsSecretsTempDirIfFullProjectDown` precedent).
/// - `down -v` tolerates volumes already missing from the registry (idempotent)
@Suite("ComposeDown volume removal (CHAOS-1398)")
struct ComposeDownVolumeRemovalTests {

    // MARK: - Parsing

    @Test("ComposeDown parses --volumes long form")
    func parsesVolumesLongForm() throws {
        let cmd = try ComposeDown.parse(["--volumes"])
        #expect(cmd.removeVolumes == true)
    }

    @Test("ComposeDown parses -v short form")
    func parsesVolumesShortForm() throws {
        let cmd = try ComposeDown.parse(["-v"])
        #expect(cmd.removeVolumes == true)
    }

    @Test("ComposeDown defaults removeVolumes to false")
    func removeVolumesDefaultsFalse() throws {
        let cmd = try ComposeDown.parse([])
        #expect(cmd.removeVolumes == false)
    }

    // MARK: - Service.referencedNamedVolumes()

    @Test("Service.referencedNamedVolumes extracts named sources only")
    func referencedNamedVolumesExtractsName() {
        let service = Service(
            image: "alpine",
            volumes: ["data:/var/lib/data", "logs:/var/log:ro"]
        )
        #expect(service.referencedNamedVolumes() == ["data", "logs"])
    }

    @Test("Service.referencedNamedVolumes excludes bind mounts")
    func referencedNamedVolumesExcludesBindMounts() {
        let service = Service(
            image: "alpine",
            volumes: [
                "/host/abs:/container",
                "./relative:/container",
                "../parent:/container",
                "named:/container",
            ]
        )
        #expect(service.referencedNamedVolumes() == ["named"])
    }

    @Test("Service.referencedNamedVolumes returns empty for nil/empty volumes")
    func referencedNamedVolumesEmpty() {
        #expect(Service(image: "alpine").referencedNamedVolumes().isEmpty)
        #expect(Service(image: "alpine", volumes: []).referencedNamedVolumes().isEmpty)
    }

    // MARK: - Full project down -v

    @Test("Full down -v calls removeVolume for each top-level named volume")
    func fullDownRemovesAllNamedVolumes() async throws {
        let projectName = "cc-test-vol-test-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - data:/d
                  - logs:/l
            volumes:
              data:
              logs:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [
            RuntimeVolume(name: "data"),
            RuntimeVolume(name: "logs"),
        ])
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(RecordingRunner()) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "-v"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries.contains(.removeVolume(name: "data")), "expected removeVolume(data); got \(entries)")
        #expect(entries.contains(.removeVolume(name: "logs")), "expected removeVolume(logs); got \(entries)")
    }

    @Test("Full down -v skips external volumes")
    func fullDownSkipsExternals() async throws {
        let projectName = "cc-test-vol-ext-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - shared:/d
                  - data:/x
            volumes:
              shared:
                external: true
              data:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [
            RuntimeVolume(name: "shared"),
            RuntimeVolume(name: "data"),
        ])
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(RecordingRunner()) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "-v"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries.contains(.removeVolume(name: "data")), "expected removeVolume(data); got \(entries)")
        #expect(!entries.contains(.removeVolume(name: "shared")), "must not remove external volume; got \(entries)")
    }

    @Test("Down without -v does NOT call removeVolume")
    func downWithoutFlagSkipsVolumes() async throws {
        let projectName = "cc-test-no-flag-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - data:/d
            volumes:
              data:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [RuntimeVolume(name: "data")])
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(RecordingRunner()) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        let touchedVolumes = entries.contains(where: {
            if case .removeVolume = $0 { return true }
            return false
        })
        #expect(!touchedVolumes, "down without -v must not call removeVolume; got \(entries)")
    }

    // MARK: - Partial project down -v (shared-volume semantics)

    @Test("Partial down -v removes volumes exclusive to targeted services")
    func partialDownRemovesExclusiveVolumes() async throws {
        let projectName = "cc-test-partial-excl-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - api_only:/d
              worker:
                image: alpine
                volumes:
                  - worker_only:/d
            volumes:
              api_only:
              worker_only:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [
            RuntimeVolume(name: "api_only"),
            RuntimeVolume(name: "worker_only"),
        ])
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(RecordingRunner()) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "-v", "api"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries.contains(.removeVolume(name: "api_only")), "expected api_only removed; got \(entries)")
        #expect(!entries.contains(.removeVolume(name: "worker_only")), "must not remove worker_only; got \(entries)")
    }

    @Test("Partial down -v skips volumes shared with services outside the target")
    func partialDownSkipsSharedVolumes() async throws {
        let projectName = "cc-test-partial-shared-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - shared_data:/d
              worker:
                image: alpine
                volumes:
                  - shared_data:/d
            volumes:
              shared_data:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [
            RuntimeVolume(name: "shared_data"),
        ])
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(RecordingRunner()) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "-v", "api"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(!entries.contains(.removeVolume(name: "shared_data")),
                "shared volume must be skipped on partial down; got \(entries)")
    }

    @Test("Down -v tolerates already-removed volumes (notFound)")
    func downToleratesNotFound() async throws {
        let projectName = "cc-test-tolerate-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - gone:/d
            volumes:
              gone:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Stub ZERO volumes so RecordingRuntime.removeVolume throws .notFound
        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [])

        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(RecordingRunner()) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "-v"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries.contains(.removeVolume(name: "gone")),
                "removeVolume(gone) must still be attempted even if registry is empty; got \(entries)")
    }

    // MARK: - Helpers

    private static func makeProject(yaml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "compose-down-vol-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try yaml.write(to: directory.appending(path: "compose.yml"), atomically: true, encoding: .utf8)
        return directory
    }
}
