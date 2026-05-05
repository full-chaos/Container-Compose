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

// CHAOS-1424 PR3 — native lifecycle error paths.
// Lives in its own file (not extending AppleContainerizationRuntimeTests) so the
// PR4 test-target migration can move the original suite to the native target
// without a delete/modify merge conflict on these PR3 additions.
@Suite("AppleContainerizationRuntime native lifecycle (CHAOS-1424 PR3)")
struct AppleContainerizationRuntimeLifecycleTests {

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

    @Test("kernelURL pointing to missing file throws kernelUnavailable on create")
    func phase3_missingKernelURL_throwsKernelUnavailable() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        let bogusKernel = URL(fileURLWithPath: "/tmp/nonexistent-vmlinux-\(UUID().uuidString)")
        let runtime = AppleContainerizationRuntime(
            registry: registry,
            kernelURL: bogusKernel
        )

        await #expect(throws: RuntimeError.self) {
            _ = try await runtime.create(
                id: "demo-svc-1",
                configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
            )
        }

        // Compensating rollback: registry should be empty after the failed create.
        let listed = try await runtime.list(filters: .all)
        #expect(listed.isEmpty, "registry must be rolled back after native-create failure")
    }

    @Test("registry-only mode (kernelURL=nil) preserves existing lifecycle behavior")
    func phase3_nilKernelURL_preservesRegistryOnlyMode() async throws {
        let path = Self.temporaryStoragePath()
        defer { Self.cleanup(path) }
        let registry = try await ContainerRegistry(storagePath: path)
        // Default init — kernelURL = nil — registry-only mode.
        let runtime = AppleContainerizationRuntime(registry: registry)

        let id = "demo-svc-1"
        _ = try await runtime.create(
            id: id,
            configuration: RuntimeCreateConfiguration(imageReference: "alpine:3")
        )
        try await runtime.start(id: id)
        try await runtime.stop(id: id, options: .default)

        let stopped = try await runtime.get(id: id)
        #expect(stopped.status == .exited)
        // Lifecycle map stays empty — native path not taken.
        #expect(await runtime._testLifecycleMap(for: id) == false)
    }
}

#endif
