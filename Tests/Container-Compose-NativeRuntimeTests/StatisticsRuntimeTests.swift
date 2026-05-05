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

#if os(macOS)

import Foundation
import Testing
@testable import ContainerComposeCore

/// Integration tests for `AppleContainerizationRuntime.statistics(for:)` —
/// the route-facing public API that PR4 wired through the translator. These
/// tests exercise the actor edge without spinning a live VM by relying on
/// the registry-only fallback path: when `liveContainers` is empty the method
/// returns the structurally valid empty snapshot, preserving the pre-PR4
/// behavior. The populated-map branch is covered by the live-VM smoke target
/// (see `LiveLifecycleSmokeTests`); the value-translation logic is unit-tested
/// in `StatisticsTranslationTests`.
@Suite("Statistics runtime integration (CHAOS-1424 PR4)")
struct StatisticsRuntimeTests {

    private static func temporaryStoragePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "container-compose-tests")
            .appending(path: UUID().uuidString)
            .appending(path: "registry.json")
            .path
    }

    private static func cleanup(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("statistics(for:) throws notFound when registry has no record")
    func statistics_throwsNotFound() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        await #expect(throws: RuntimeError.self) {
            _ = try await runtime.statistics(for: "no-such-id")
        }
    }

    @Test("statistics(for:) returns empty snapshot for registry-only container (regression guard)")
    func statistics_emptySnapshotForRegistryOnly() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        let id = "demo-svc-1"
        _ = try await runtime.create(
            id: id,
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )

        let stats = try await runtime.statistics(for: id)

        // Registry-only path: every metric field nil, no networks, id preserved.
        // Mirrors the pre-PR4 placeholder exactly so existing NDJSON consumers
        // are unaffected.
        #expect(stats.id == id)
        #expect(stats.cpuUsageUsec == nil)
        #expect(stats.memoryUsageBytes == nil)
        #expect(stats.memoryLimitBytes == nil)
        #expect(stats.oomKillCount == nil)
        #expect(stats.networks.isEmpty)
    }
}

#endif
