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

/// Regression coverage for CHAOS-1415: `ComposeStart.startServices` and
/// `ComposeStop.stopServices` must honor a service's explicit `container_name:`
/// override and fall back to `<project>-<service>` only when no override is set.
///
/// Both methods route through `effectiveContainerName(...)` (introduced in
/// CHAOS-1396), so these tests pin that the helper is wired in at the start/stop
/// call sites — the same guarantee the ComposeUpContainerNameTests provide for
/// `ComposeUp.stopOldStuff` and `ComposeDown.stopOldStuff`.
@Suite("Container name resolution — start/stop (CHAOS-1415)")
struct ComposeStartStopContainerNameTests {

    // MARK: - ComposeStart

    @Test("ComposeStart.startServices resolves explicit container_name")
    func startUsesExplicitContainerName() async throws {
        let service = Service(image: "alpine:latest", container_name: "my-explicit-start-name")
        var cmd = try ComposeStart.parse([])

        let provider = RecordingContainerClientProvider()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.startServices(
                [(serviceName: "web", service: service)],
                projectName: "test-proj",
                cwd: cmd.cwd
            )
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.get(id: "my-explicit-start-name")),
                "ComposeStart must look up the explicit container_name; recorded: \(entries)")
        #expect(!entries.contains(.get(id: "test-proj-web")),
                "ComposeStart must NOT look up the project-prefix fallback when container_name is set; recorded: \(entries)")
    }

    @Test("ComposeStart.startServices falls back to <project>-<service> when container_name is unset")
    func startFallsBackToProjectPrefix() async throws {
        let service = Service(image: "alpine:latest")  // no container_name
        var cmd = try ComposeStart.parse([])

        let provider = RecordingContainerClientProvider()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.startServices(
                [(serviceName: "web", service: service)],
                projectName: "test-proj",
                cwd: cmd.cwd
            )
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.get(id: "test-proj-web")),
                "ComposeStart must use the project-prefix fallback when container_name is unset; recorded: \(entries)")
    }

    @Test("ComposeStart.startServices treats empty container_name as absent")
    func startTreatsEmptyContainerNameAsAbsent() async throws {
        let service = Service(image: "alpine:latest", container_name: "")
        var cmd = try ComposeStart.parse([])

        let provider = RecordingContainerClientProvider()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.startServices(
                [(serviceName: "web", service: service)],
                projectName: "test-proj",
                cwd: cmd.cwd
            )
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.get(id: "test-proj-web")),
                "ComposeStart must fall back to project-prefix for empty container_name; recorded: \(entries)")
        #expect(!entries.contains(.get(id: "")),
                "ComposeStart must NOT pass an empty string as the container id; recorded: \(entries)")
    }

    // MARK: - ComposeStop

    @Test("ComposeStop.stopServices resolves explicit container_name")
    func stopUsesExplicitContainerName() async throws {
        let service = Service(image: "alpine:latest", container_name: "my-explicit-stop-name")
        var cmd = try ComposeStop.parse([])

        let provider = RecordingContainerClientProvider()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.stopServices(
                [(serviceName: "web", service: service)],
                projectName: "test-proj"
            )
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.get(id: "my-explicit-stop-name")),
                "ComposeStop must look up the explicit container_name; recorded: \(entries)")
        #expect(!entries.contains(.get(id: "test-proj-web")),
                "ComposeStop must NOT look up the project-prefix fallback when container_name is set; recorded: \(entries)")
    }

    @Test("ComposeStop.stopServices falls back to <project>-<service> when container_name is unset")
    func stopFallsBackToProjectPrefix() async throws {
        let service = Service(image: "alpine:latest")  // no container_name
        var cmd = try ComposeStop.parse([])

        let provider = RecordingContainerClientProvider()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.stopServices(
                [(serviceName: "web", service: service)],
                projectName: "test-proj"
            )
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.get(id: "test-proj-web")),
                "ComposeStop must use the project-prefix fallback when container_name is unset; recorded: \(entries)")
    }

    @Test("ComposeStop.stopServices treats empty container_name as absent")
    func stopTreatsEmptyContainerNameAsAbsent() async throws {
        let service = Service(image: "alpine:latest", container_name: "")
        var cmd = try ComposeStop.parse([])

        let provider = RecordingContainerClientProvider()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await cmd.stopServices(
                [(serviceName: "web", service: service)],
                projectName: "test-proj"
            )
        }

        let entries = await provider.entriesSnapshot()
        #expect(entries.contains(.get(id: "test-proj-web")),
                "ComposeStop must fall back to project-prefix for empty container_name; recorded: \(entries)")
        #expect(!entries.contains(.get(id: "")),
                "ComposeStop must NOT pass an empty string as the container id; recorded: \(entries)")
    }
}
