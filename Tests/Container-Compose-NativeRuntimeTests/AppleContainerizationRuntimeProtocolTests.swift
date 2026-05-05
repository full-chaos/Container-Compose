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

/// Backend-specific smoke tests for `AppleContainerizationRuntime`'s
/// `Runtime`-protocol conformance (version + Phase 3 placeholders).
/// Migrated from
/// `Tests/Container-Compose-StaticTests/RuntimeProtocolExtensionsTests.swift`
/// in CHAOS-1424 PR4 to close Leak #2 in `docs/plans/runtime-abstraction-leaks.md`.
/// The portable filter-semantics tests in that file cover the backend-neutral
/// surface against `MockRuntime` and stay in `Container-Compose-StaticTests`.
@Suite("AppleContainerizationRuntime protocol surface (native)")
struct AppleContainerizationRuntimeProtocolTests {

    @Test("AppleContainerizationRuntime version reports apple-containerization backend")
    func appleRuntimeVersion() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        let version = try await runtime.version()
        #expect(version.apiVersion == "v1")
        #expect(version.daemonVersion == Main.version)
        #expect(version.serverName == "container-compose")
        #expect(version.backendDescription == "apple-containerization 0.31.0")
        #expect(!version.arch.isEmpty)
    }

    @Test("AppleContainerizationRuntime listNetworks returns empty Phase 3 placeholder")
    func appleRuntimeListNetworksEmpty() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let runtime = AppleContainerizationRuntime(registry: registry)

        let networks = try await runtime.listNetworks()
        #expect(networks.isEmpty)
    }

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
}

#endif
