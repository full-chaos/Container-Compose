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

@Suite("Environment Merge Tests")
struct EnvironmentMergeTests {

    @Test("empty inputs return baseline unchanged")
    func emptyInputsReturnBaselineUnchanged() {
        let baseline = ["FOO": "from-baseline", "BAR": "from-baseline"]

        let result = mergeServiceEnvironment(
            baseline: baseline,
            serviceEnvFile: nil,
            serviceEnvironment: nil,
            projectDirectory: FileManager.default.temporaryDirectory.path
        )

        #expect(result == baseline)
    }

    @Test("env_file does NOT override baseline key")
    func envFileDoesNotOverrideBaselineKey() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeEnvFile("FOO=from-file\n", named: "service.env", in: tempDir)

        let result = mergeServiceEnvironment(
            baseline: ["FOO": "from-baseline"],
            serviceEnvFile: [EnvFileEntry(path: "service.env")],
            serviceEnvironment: nil,
            projectDirectory: tempDir.path
        )

        #expect(result["FOO"] == "from-baseline")
    }

    @Test("earlier env_file beats later env_file on conflict")
    func earlierEnvFileBeatsLaterEnvFileOnConflict() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeEnvFile("BAR=from-first\n", named: "first.env", in: tempDir)
        try writeEnvFile("BAR=from-second\n", named: "second.env", in: tempDir)

        let result = mergeServiceEnvironment(
            baseline: [:],
            serviceEnvFile: [
                EnvFileEntry(path: "first.env"),
                EnvFileEntry(path: "second.env")
            ],
            serviceEnvironment: nil,
            projectDirectory: tempDir.path
        )

        #expect(result["BAR"] == "from-first")
    }

    @Test("service.environment with literal value overrides existing key")
    func serviceEnvironmentWithLiteralValueOverridesExistingKey() {
        let result = mergeServiceEnvironment(
            baseline: ["X": "old"],
            serviceEnvFile: nil,
            serviceEnvironment: ["X": "new-literal"],
            projectDirectory: FileManager.default.temporaryDirectory.path
        )

        #expect(result["X"] == "new-literal")
    }

    @Test("service.environment with ${VAR} keeps existing key")
    func serviceEnvironmentWithVariableKeepsExistingKey() {
        let result = mergeServiceEnvironment(
            baseline: ["Y": "kept"],
            serviceEnvFile: nil,
            serviceEnvironment: ["Y": "${SOMEVAR}"],
            projectDirectory: FileManager.default.temporaryDirectory.path
        )

        #expect(result["Y"] == "kept")
    }

    @Test("missing env_file with required=false is silent-skipped")
    func missingEnvFileWithRequiredFalseIsSilentSkipped() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeEnvFile("FROM_FILE=loaded\n", named: "present.env", in: tempDir)

        let baseline = ["BASE": "kept"]
        let result = mergeServiceEnvironment(
            baseline: baseline,
            serviceEnvFile: [
                EnvFileEntry(path: "missing.env", required: false),
                EnvFileEntry(path: "present.env")
            ],
            serviceEnvironment: nil,
            projectDirectory: tempDir.path
        )

        #expect(result["BASE"] == "kept")
        #expect(result["FROM_FILE"] == "loaded")
        #expect(result.count == 2)
    }

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("environment-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: false)
        return tempDir
    }

    private func writeEnvFile(_ content: String, named name: String, in directory: URL) throws {
        let fileURL = directory.appendingPathComponent(name)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
