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
        try await Self.expectFilterSemantics(RecordingRuntime(stubbedContainers: Self.sampleContainers))
        try await Self.expectFilterSemantics(MockRuntime(containers: Self.sampleContainers))
    }

    private static func expectFilterSemantics(_ runtime: any Runtime) async throws {
        func ids(_ containers: [RuntimeContainer]) -> [String] {
            containers.map(\.id).sorted()
        }

        let running = try await runtime.list(filters: RuntimeListFilters(status: [.running]))
        #expect(ids(running) == ["demo-web-1", "other-web-1"])

        let demo = try await runtime.list(filters: RuntimeListFilters(namePrefix: "demo-"))
        #expect(ids(demo) == ["demo-db-1", "demo-web-1"])

        let runningDemo = try await runtime.list(filters: RuntimeListFilters(status: [.running], namePrefix: "demo-"))
        #expect(ids(runningDemo) == ["demo-web-1"])

        let emptyStatus = try await runtime.list(filters: RuntimeListFilters(status: [], namePrefix: "demo-"))
        #expect(ids(emptyStatus) == ["demo-db-1", "demo-web-1"])

        let emptyPrefix = try await runtime.list(filters: RuntimeListFilters(status: [.running], namePrefix: ""))
        #expect(ids(emptyPrefix) == ["demo-web-1", "other-web-1"])
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

    // CHAOS-1424 PR4: AppleContainerizationRuntime version + listNetworks
    // smoke tests moved to Container-Compose-NativeRuntimeTests
    // (AppleContainerizationRuntimeProtocolTests). Closes Leak #2 in
    // docs/plans/runtime-abstraction-leaks.md — backend-specific coverage
    // belongs with the live-VM target, not in the backend-neutral suite.

    private static let sampleContainers: [RuntimeContainer] = [
        RuntimeContainer(id: "demo-web-1", imageReference: "nginx:1", status: .running),
        RuntimeContainer(id: "demo-db-1", imageReference: "postgres:16", status: .stopped),
        RuntimeContainer(id: "other-web-1", imageReference: "nginx:1", status: .running)
    ]
}
