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

@Suite("ComposePush Runtime Argv Tests")
struct ComposePushRuntimeArgvTests {

    private func writeTempCompose(_ yaml: String) throws -> (dir: URL, compose: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)
        return (dir, compose)
    }

    @Test("push: image services emit container image push argv")
    func pushImageServicesEmitContainerImagePushArgv() async throws {
        let yaml = """
        services:
          web:
            image: registry.example.com/web:latest
          api:
            image: registry.example.com/api:latest
            build:
              context: .
          builder:
            build:
              context: .
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = RecordingRunner()
        try await RunnerEnvironment.$current.withValue(recorder) {
            var cmd = try ComposePush.parse(["--quiet", "-f", compose.path])
            try await cmd.run()
        }

        let pushArgvs = await recorder.argvs()
        // Set: spec only requires each image-bearing service is pushed exactly once.
        #expect(Set(pushArgvs) == Set([
            ["container", "image", "push", "registry.example.com/web:latest"],
            ["container", "image", "push", "registry.example.com/api:latest"],
        ]))
    }

    @Test("push: services without image produce no argv entry")
    func pushServicesWithoutImageProduceNoArgvEntry() async throws {
        let yaml = """
        services:
          builder:
            build:
              context: .
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = RecordingRunner()
        try await RunnerEnvironment.$current.withValue(recorder) {
            var cmd = try ComposePush.parse(["--quiet", "-f", compose.path])
            try await cmd.run()
        }

        let pushArgvs = await recorder.argvs()
        #expect(pushArgvs.isEmpty)
    }

    @Test("push: --ignore-push-failures continues after runner error")
    func pushIgnoreFailuresContinuesAfterRunnerError() async throws {
        let yaml = """
        services:
          web:
            image: registry.example.com/web:latest
          api:
            image: registry.example.com/api:latest
          builder:
            build:
              context: .
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = ThrowingFirstPushRunner()
        try await RunnerEnvironment.$current.withValue(runner) {
            var cmd = try ComposePush.parse(["--ignore-push-failures", "--quiet", "-f", compose.path])
            try await cmd.run()
        }

        let pushArgvs = await runner.argvs()
        // Set: --ignore-push-failures must push both regardless of iteration order.
        #expect(Set(pushArgvs) == Set([
            ["container", "image", "push", "registry.example.com/web:latest"],
            ["container", "image", "push", "registry.example.com/api:latest"],
        ]))
    }
}

private actor ThrowingFirstPushRunner: RunCommandRunner {
    private var recordedArgvs: [[String]] = []
    private var shouldThrow = true

    func run(
        _ request: RunRequest,
        onStdout: (@Sendable (String) -> Void)?,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> RunResult {
        recordedArgvs.append(request.argv)
        if shouldThrow {
            shouldThrow = false
            throw NSError(
                domain: "ThrowingFirstPushRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "simulated push failure"]
            )
        }
        return RunResult(exitCode: 0, probeAvailable: false)
    }

    func argvs() -> [[String]] { recordedArgvs }
}
