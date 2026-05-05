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

@Suite("RuntimeError Tests")
struct RuntimeErrorTests {
    @Test func imageNotFound_errorDescription_includesReference() {
        let err = RuntimeError.imageNotFound(reference: "alpine:3")
        #expect(err.errorDescription == "Runtime: image 'alpine:3' not found")
    }

    @Test func imageNotFound_equality_byReference() {
        let a = RuntimeError.imageNotFound(reference: "alpine:3")
        let b = RuntimeError.imageNotFound(reference: "alpine:3")
        let c = RuntimeError.imageNotFound(reference: "redis:7")

        #expect(a == b)
        #expect(a != c)
    }

    @Test func imagePullDispatch_mapsNotFoundErrorToRuntimeError() throws {
        let upstream = UpstreamImagePullError(message: "404: image not found")
        let mapped = try #require(ProductionRunner.imagePullNotFoundError(
            from: upstream,
            argv: ["docker.io/library/alpine:3", "--platform", "linux/arm64", "--debug"]
        ))

        #expect(mapped == .imageNotFound(reference: "docker.io/library/alpine:3"))
    }

    @Test func imagePullDispatch_doesNotMapOtherErrors() {
        let upstream = UpstreamImagePullError(message: "permission denied")

        #expect(ProductionRunner.imagePullNotFoundError(
            from: upstream,
            argv: ["docker.io/library/alpine:3"]
        ) == nil)
    }

    @Test func imagePullDispatch_doesNotMapUnrelated404Substring() {
        let upstream = UpstreamImagePullError(message: "failed to connect to registry.example.com:4040")

        #expect(ProductionRunner.imagePullNotFoundError(
            from: upstream,
            argv: ["docker.io/library/alpine:3"]
        ) == nil)
    }

    // MARK: - CHAOS-1424 Phase 2 lifecycle errors

    @Test func requiresMacOS26_errorDescription_namesOperation() {
        let err = RuntimeError.requiresMacOS26(operation: "create")
        #expect(err.errorDescription?.contains("'create'") == true)
        #expect(err.errorDescription?.contains("macOS 26") == true)
    }

    @Test func requiresMacOS26_equality_byOperation() {
        let a = RuntimeError.requiresMacOS26(operation: "create")
        let b = RuntimeError.requiresMacOS26(operation: "create")
        let c = RuntimeError.requiresMacOS26(operation: "start")

        #expect(a == b)
        #expect(a != c)
    }

    @Test func kernelUnavailable_errorDescription_includesReason() {
        let err = RuntimeError.kernelUnavailable(reason: "vmlinux missing at /tmp/k")
        #expect(err.errorDescription?.contains("vmlinux missing at /tmp/k") == true)
        #expect(err.errorDescription?.contains("kernel") == true)
    }

    @Test func kernelUnavailable_equality_byReason() {
        let a = RuntimeError.kernelUnavailable(reason: "missing")
        let b = RuntimeError.kernelUnavailable(reason: "missing")
        let c = RuntimeError.kernelUnavailable(reason: "checksum mismatch")

        #expect(a == b)
        #expect(a != c)
    }
}

private struct UpstreamImagePullError: LocalizedError, CustomStringConvertible {
    let message: String

    var errorDescription: String? { message }
    var description: String { message }
}
