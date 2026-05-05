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

/// Resolver tests for `BinaryResolver` (CHAOS-1421;
/// `docs/reviews/path-execution-audit-2026-05-05.md`). Exercises the
/// env-var override contract and the PATH-walk fallback.
@Suite("RunCommandRunner resolver")
struct RunCommandRunnerResolutionTests {

    /// Write a tiny chmod-700 shell script to a temp file and return its path.
    /// Caller is responsible for cleanup.
    private func makeExecutableTempScript() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("stub-binary")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        return script
    }

    @Test("env-var override pointing to an executable is honored")
    func envVarOverrideHonored() throws {
        let script = try makeExecutableTempScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let envName = "CHAOS_TEST_RESOLVER_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(envName, script.path, 1)
        defer { unsetenv(envName) }

        let resolved = try BinaryResolver.resolve("anything-goes", envOverride: envName)
        #expect(resolved?.path == script.path)
    }

    @Test("env-var override pointing to a non-executable path throws binaryOverrideInvalid")
    func envVarOverrideInvalidThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nonExec = dir.appendingPathComponent("not-executable")
        try "plain text".write(to: nonExec, atomically: true, encoding: .utf8)
        // Default mode 0o644 — readable but not executable.

        let envName = "CHAOS_TEST_RESOLVER_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(envName, nonExec.path, 1)
        defer { unsetenv(envName) }

        #expect(throws: RuntimeError.binaryOverrideInvalid(envVar: envName, path: nonExec.path)) {
            _ = try BinaryResolver.resolve("anything", envOverride: envName)
        }
    }

    @Test("env-var override empty string falls through to PATH walk")
    func envVarOverrideEmptyFallsThrough() throws {
        let envName = "CHAOS_TEST_RESOLVER_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(envName, "", 1)
        defer { unsetenv(envName) }

        // `sh` is in /bin which is in resolutionPath — should be found via PATH walk.
        let resolved = try BinaryResolver.resolve("sh", envOverride: envName)
        #expect(resolved != nil)
        #expect(resolved?.path.hasSuffix("/sh") == true)
    }

    @Test("PATH walk returns nil when binary does not exist")
    func pathWalkReturnsNilForMissing() throws {
        let envName = "CHAOS_TEST_RESOLVER_DOES_NOT_EXIST_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        // Env var is unset by default.

        let resolved = try BinaryResolver.resolve(
            "definitely-not-a-real-binary-cge2026-\(UUID().uuidString)",
            envOverride: envName
        )
        #expect(resolved == nil)
    }

    @Test("cachedResolve materializes nil PATH-walk into cliBinaryNotFound failure")
    func cachedResolveWrapsNilAsCliBinaryNotFound() {
        let envName = "CHAOS_TEST_RESOLVER_NOENV_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

        let result = BinaryResolver.cachedResolve(
            "definitely-not-a-real-binary-cge2026-\(UUID().uuidString)",
            envOverride: envName
        )

        switch result {
        case .success(let url):
            Issue.record("Expected failure, got success: \(url)")
        case .failure(let err):
            if case .cliBinaryNotFound(_, let searchPath) = err {
                #expect(searchPath == BinaryResolver.resolutionPath)
            } else {
                Issue.record("Expected .cliBinaryNotFound, got \(err)")
            }
        }
    }

    @Test("cachedResolve materializes invalid override into binaryOverrideInvalid failure")
    func cachedResolveWrapsInvalidOverride() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nonExec = dir.appendingPathComponent("not-executable")
        try "plain text".write(to: nonExec, atomically: true, encoding: .utf8)

        let envName = "CHAOS_TEST_RESOLVER_BAD_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(envName, nonExec.path, 1)
        defer { unsetenv(envName) }

        let result = BinaryResolver.cachedResolve("anything", envOverride: envName)
        switch result {
        case .success(let url):
            Issue.record("Expected failure, got success: \(url)")
        case .failure(let err):
            #expect(err == .binaryOverrideInvalid(envVar: envName, path: nonExec.path))
        }
    }
}
