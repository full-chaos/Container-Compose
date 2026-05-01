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

@Suite("Runtime protocol Phase 2 extensions")
struct RuntimeProtocolExtensionsTests {

    @Test("RuntimeListFilters constructs all status prefix and combined filters")
    func runtimeListFiltersConstruction() {
        let all = RuntimeListFilters.all
        #expect(all.status == nil)
        #expect(all.namePrefix == nil)

        let byStatus = RuntimeListFilters(status: [.running])
        #expect(byStatus.status == [.running])
        #expect(byStatus.namePrefix == nil)

        let byPrefix = RuntimeListFilters(namePrefix: "demo-")
        #expect(byPrefix.status == nil)
        #expect(byPrefix.namePrefix == "demo-")

        let combined = RuntimeListFilters(status: [.running, .stopped], namePrefix: "demo-web")
        #expect(combined.status == [.running, .stopped])
        #expect(combined.namePrefix == "demo-web")
    }

    @Test("RuntimeListFilters apply status namePrefix AND semantics")
    func runtimeListFiltersApply() async throws {
        let runtime = RecordingRuntime(stubbedContainers: Self.sampleContainers)

        let running = try await runtime.list(filters: RuntimeListFilters(status: [.running]))
        #expect(running.map(\.id) == ["demo-web-1", "other-web-1"])

        let demo = try await runtime.list(filters: RuntimeListFilters(namePrefix: "demo-"))
        #expect(demo.map(\.id) == ["demo-web-1", "demo-db-1"])

        let runningDemo = try await runtime.list(filters: RuntimeListFilters(status: [.running], namePrefix: "demo-"))
        #expect(runningDemo.map(\.id) == ["demo-web-1"])

        let emptyStatus = try await runtime.list(filters: RuntimeListFilters(status: [], namePrefix: "demo-"))
        #expect(emptyStatus.map(\.id) == ["demo-web-1", "demo-db-1"])

        let emptyPrefix = try await runtime.list(filters: RuntimeListFilters(status: [.running], namePrefix: ""))
        #expect(emptyPrefix.map(\.id) == ["demo-web-1", "other-web-1"])
    }

    @Test("BridgeContainerClientRuntime version returns API daemon backend and arch")
    func bridgeRuntimeVersion() async throws {
        let version = try await BridgeContainerClientRuntime().version()
        #expect(version.apiVersion == "v1")
        #expect(!version.daemonVersion.isEmpty)
        #expect(version.daemonVersion == Main.version)
        #expect(version.serverName == "container-compose")
        #expect(version.backendDescription.hasPrefix("bridge (apple/container CLI)"))
        #expect(!version.arch.isEmpty)
    }

    #if os(macOS)
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
    #endif

    private static let sampleContainers: [RuntimeContainer] = [
        RuntimeContainer(id: "demo-web-1", imageReference: "nginx:1", status: .running),
        RuntimeContainer(id: "demo-db-1", imageReference: "postgres:16", status: .stopped),
        RuntimeContainer(id: "other-web-1", imageReference: "nginx:1", status: .running)
    ]

    #if os(macOS)
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
    #endif
}
