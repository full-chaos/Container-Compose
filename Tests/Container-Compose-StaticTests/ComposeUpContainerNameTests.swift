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

import Testing
import Foundation
@testable import ContainerComposeCore
import TestHelpers

/// Regression coverage for CHAOS-1396: `ComposeUp.stopOldStuff` previously
/// ignored `service.container_name` and always used `<project>-<service>`,
/// so `compose up` could not stop a previous container that was created with
/// an explicit name. `ComposeDown.stopOldStuff` already honored the override,
/// which made the divergence silent until users hit a name collision on the
/// second `up`.
///
/// These tests pin the `provider.get(id:)` call shape on both the explicit
/// and fallback paths so the bug cannot regress, and lock in ComposeDown's
/// existing correct behavior.
@Suite("Container name resolution (CHAOS-1396)")
struct ComposeUpContainerNameTests {

    @Test("ComposeUp.stopOldStuff resolves explicit container_name")
    func upUsesExplicitContainerName() async throws {
        let service = Service(image: "alpine:latest", container_name: "my-explicit-name")
        var cmd = try ComposeUp.parse([])
        cmd.projectName = "test-proj"

        let provider = RecordingContainerClientProvider()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.stopOldStuff([(serviceName: "web", service: service)], remove: true)
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.get(id: "my-explicit-name")),
                "ComposeUp must look up the explicit container_name; recorded: \(entries)")
        #expect(!entries.contains(.get(id: "test-proj-web")),
                "ComposeUp must NOT look up the project-prefix fallback when container_name is set; recorded: \(entries)")
    }

    @Test("ComposeUp.stopOldStuff falls back to <project>-<service> when container_name is unset")
    func upFallsBackToProjectPrefix() async throws {
        let service = Service(image: "alpine:latest")  // no container_name
        var cmd = try ComposeUp.parse([])
        cmd.projectName = "test-proj"

        let provider = RecordingContainerClientProvider()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.stopOldStuff([(serviceName: "web", service: service)], remove: true)
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.get(id: "test-proj-web")),
                "ComposeUp must use the project-prefix fallback when container_name is unset; recorded: \(entries)")
    }

    @Test("ComposeDown.stopOldStuff resolves explicit container_name (lock-in regression)")
    func downUsesExplicitContainerName() async throws {
        let projectName = "lock-in-down-\(UUID().uuidString.lowercased())"
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "compose-down-name-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let yaml = """
        services:
          web:
            image: alpine:latest
            container_name: my-explicit-down-name
        """
        try yaml.write(to: directory.appending(path: "compose.yml"), atomically: true, encoding: .utf8)

        let provider = RecordingContainerClientProvider()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName])
            try await command.run()
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.get(id: "my-explicit-down-name")),
                "ComposeDown must look up the explicit container_name; recorded: \(entries)")
        #expect(!entries.contains(.get(id: "\(projectName)-web")),
                "ComposeDown must NOT look up the project-prefix fallback when container_name is set; recorded: \(entries)")
    }
}
