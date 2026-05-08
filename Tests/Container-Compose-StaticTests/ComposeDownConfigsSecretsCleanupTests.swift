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

import Foundation
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite("Configs+Secrets cleanup")
struct ComposeDownConfigsSecretsCleanupTests {
    private func makeTempComposeProject() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "compose-down-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let compose = """
        services:
          web:
            image: alpine:latest
        """
        try compose.write(to: directory.appending(path: "compose.yml"), atomically: true, encoding: .utf8)
        return directory
    }

    private func configsSecretsDir(projectName: String) -> URL {
        URL(fileURLWithPath: NSString(string: "~/.containers/Compose/\(projectName)/configs-secrets").expandingTildeInPath, isDirectory: true)
    }

    private func makeSentinel(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appending(path: "sentinel")
        try "sentinel".write(to: sentinel, atomically: true, encoding: .utf8)
        return sentinel
    }

    @Test("Full-project down removes configs-secrets temp directory")
    func fullProjectDownRemovesConfigsSecretsDirectory() async throws {
        let projectName = "cc-test-phase3-down-full-\(UUID().uuidString.lowercased())"
        let tempProject = try makeTempComposeProject()
        defer { try? FileManager.default.removeItem(at: tempProject) }
        let secretsDir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: secretsDir)
        _ = try makeSentinel(in: secretsDir)
        defer { try? FileManager.default.removeItem(at: secretsDir) }

        let provider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeDown.parse(["--cwd", tempProject.path, "-p", projectName])
                    try await command.run()
                }
            }
        }

        #expect(!FileManager.default.fileExists(atPath: secretsDir.path))
    }

    @Test("Partial down leaves configs-secrets temp directory intact")
    func partialDownLeavesConfigsSecretsDirectoryIntact() async throws {
        let projectName = "cc-test-phase3-down-partial-\(UUID().uuidString.lowercased())"
        let tempProject = try makeTempComposeProject()
        defer { try? FileManager.default.removeItem(at: tempProject) }
        let secretsDir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: secretsDir)
        let sentinel = try makeSentinel(in: secretsDir)
        defer { try? FileManager.default.removeItem(at: secretsDir) }

        let provider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(provider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeDown.parse(["--cwd", tempProject.path, "-p", projectName, "web"])
                    try await command.run()
                }
            }
        }

        #expect(FileManager.default.fileExists(atPath: secretsDir.path))
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }
}
