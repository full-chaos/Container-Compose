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

import Testing
import Foundation
import ArgumentParser
@testable import ContainerComposeCore
import TestHelpers

// `.serialized` because every test in this suite captures stdout/stderr by
// `dup2`-ing the global FD; running them concurrently would race on the shared
// file descriptor and `readDataToEndOfFile()` would hang. See the note in
// `Makefile` and the `@Suite(.serialized)` precedent in `ComposeUpVolumeIdempotencyTests`.
@Suite("ComposePort Runtime Argv Tests (CHAOS-1440)", .serialized)
struct ComposePortRuntimeArgvTests {

    // MARK: - Fixtures

    private static let baseYaml = """
    name: myproj
    services:
      redis:
        image: redis:7
        ports:
          - "16379:6379"
      web:
        image: nginx:1
        ports:
          - "8080:80"
    """

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

    private func makeRunningContainers() -> [RuntimeContainer] {
        [
            RuntimeContainer(
                id: "myproj-redis",
                imageReference: "redis:7",
                status: .running,
                publishedPorts: [
                    RuntimePublishedPort(
                        hostAddress: "0.0.0.0",
                        hostPort: 16379,
                        containerPort: 6379,
                        proto: .tcp
                    )
                ]
            ),
            RuntimeContainer(
                id: "myproj-web",
                imageReference: "nginx:1",
                status: .running,
                publishedPorts: [
                    RuntimePublishedPort(
                        hostAddress: "0.0.0.0",
                        hostPort: 8080,
                        containerPort: 80,
                        proto: .tcp
                    )
                ]
            ),
        ]
    }

    // MARK: - Listing mode

    @Test("port (no args): prints NAME/PORTS table for every running service")
    func port_noArgs_listsAll() async throws {
        let (dir, compose) = try writeTempCompose(Self.baseYaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runtime = RecordingRuntime(stubbedContainers: makeRunningContainers())
        let captured = try await Self.capturingStdout {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var cmd = try ComposePort.parse(["-f", compose.path])
                try await cmd.run()
            }
        }

        #expect(captured.contains("NAME"))
        #expect(captured.contains("PORTS"))
        #expect(captured.contains("myproj-redis"))
        #expect(captured.contains("0.0.0.0:16379->6379/tcp"))
        #expect(captured.contains("myproj-web"))
        #expect(captured.contains("0.0.0.0:8080->80/tcp"))
    }

    @Test("port -a: matches port with no args")
    func port_dashA_matchesNoArgs() async throws {
        let (dir, compose) = try writeTempCompose(Self.baseYaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runtime = RecordingRuntime(stubbedContainers: makeRunningContainers())

        let noArgsOutput = try await Self.capturingStdout {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var cmd = try ComposePort.parse(["-f", compose.path])
                try await cmd.run()
            }
        }

        let dashAOutput = try await Self.capturingStdout {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var cmd = try ComposePort.parse(["-f", compose.path, "-a"])
                try await cmd.run()
            }
        }
        #expect(noArgsOutput == dashAOutput)
    }

    @Test("port --all: matches port -a")
    func port_dashAll_matchesDashA() async throws {
        let (dir, compose) = try writeTempCompose(Self.baseYaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runtime = RecordingRuntime(stubbedContainers: makeRunningContainers())

        let dashAOutput = try await Self.capturingStdout {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var cmd = try ComposePort.parse(["-f", compose.path, "-a"])
                try await cmd.run()
            }
        }

        let dashAllOutput = try await Self.capturingStdout {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var cmd = try ComposePort.parse(["-f", compose.path, "--all"])
                try await cmd.run()
            }
        }
        #expect(dashAOutput == dashAllOutput)
    }

    @Test("port <service>: filters output to the named service")
    func port_serviceArg_filtersToOneRow() async throws {
        let (dir, compose) = try writeTempCompose(Self.baseYaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runtime = RecordingRuntime(stubbedContainers: makeRunningContainers())
        let captured = try await Self.capturingStdout {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var cmd = try ComposePort.parse(["-f", compose.path, "redis"])
                try await cmd.run()
            }
        }

        #expect(captured.contains("myproj-redis"))
        #expect(captured.contains("0.0.0.0:16379->6379/tcp"))
        #expect(!captured.contains("myproj-web"))
        #expect(!captured.contains("0.0.0.0:8080->80/tcp"))
    }

    @Test("port <service> not running: stderr error + non-zero exit")
    func port_serviceArg_notRunning_errorsAndExits() async throws {
        let (dir, compose) = try writeTempCompose(Self.baseYaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Only redis is running; user asks for "web".
        let runtime = RecordingRuntime(stubbedContainers: [
            RuntimeContainer(id: "myproj-redis", imageReference: "redis:7", status: .running),
        ])

        let stderr = try await Self.capturingStderr {
            await Self.expectExitFailure {
                try await RuntimeEnvironment.$current.withValue(runtime) {
                    var cmd = try ComposePort.parse(["-f", compose.path, "web"])
                    try await cmd.run()
                }
            }
        }
        #expect(stderr.contains("Error: web is not running"), "stderr should indicate web not running; got: \(stderr)")
    }

    @Test("port: empty project errors with project-empty message + non-zero exit")
    func port_noRunningContainersInProject_errors() async throws {
        let (dir, compose) = try writeTempCompose(Self.baseYaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runtime = RecordingRuntime(stubbedContainers: [])
        let stderr = try await Self.capturingStderr {
            await Self.expectExitFailure {
                try await RuntimeEnvironment.$current.withValue(runtime) {
                    var cmd = try ComposePort.parse(["-f", compose.path])
                    try await cmd.run()
                }
            }
        }
        #expect(stderr.contains("Error: no containers running for project myproj"), "expected project-empty error; got: \(stderr)")
    }

    // MARK: - Resolver mode (regression, must keep working)

    @Test("port <service> <private-port>: prints bare host:port (resolver mode)")
    func port_resolverMode_printsBareHostPort() async throws {
        let (dir, compose) = try writeTempCompose(Self.baseYaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Resolver mode does NOT consult the runtime; the YAML is enough.
        let captured = try await Self.capturingStdout {
            var cmd = try ComposePort.parse(["-f", compose.path, "redis", "6379"])
            try await cmd.run()
        }
        // Trailing newline from `print(...)`.
        #expect(captured.trimmingCharacters(in: .whitespacesAndNewlines) == "0.0.0.0:16379")
    }

    @Test("port -a <service> <private-port>: errors with mutual-exclusion message")
    func port_dashAWithPrivatePort_errors() async throws {
        let (dir, compose) = try writeTempCompose(Self.baseYaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stderr = try await Self.capturingStderr {
            await Self.expectExitFailure {
                var cmd = try ComposePort.parse(["-f", compose.path, "-a", "redis", "6379"])
                try await cmd.run()
            }
        }
        #expect(
            stderr.contains("Error: --all and <private-port> are mutually exclusive"),
            "expected mutex error; got: \(stderr)"
        )
    }

    // MARK: - capture helpers (mirrors patterns from ComposeUpVolumeIdempotencyTests / ComposeUpBlockImageMigrationTests)

    private enum CaptureError: Error { case dupFailed }

    private static func capturingStdout(_ block: () async throws -> Void) async throws -> String {
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        let pipe = Pipe()
        guard original >= 0,
              dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0
        else {
            if original >= 0 { close(original) }
            throw CaptureError.dupFailed
        }
        let reader = Task {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }
        defer {
            _ = dup2(original, STDOUT_FILENO)
            close(original)
        }
        try await block()
        fflush(stdout)
        _ = dup2(original, STDOUT_FILENO)
        pipe.fileHandleForWriting.closeFile()
        let data = await reader.value
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func capturingStderr(_ block: () async throws -> Void) async throws -> String {
        let original = dup(STDERR_FILENO)
        let pipe = Pipe()
        guard original >= 0,
              dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0
        else {
            if original >= 0 { close(original) }
            throw CaptureError.dupFailed
        }
        let reader = Task {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }
        defer {
            _ = dup2(original, STDERR_FILENO)
            close(original)
        }
        try await block()
        _ = dup2(original, STDERR_FILENO)
        pipe.fileHandleForWriting.closeFile()
        let data = await reader.value
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Run `block` expecting it to throw `ExitCode.failure`. Any other thrown
    /// error is rethrown into the test failure path.
    private static func expectExitFailure(_ block: () async throws -> Void) async {
        do {
            try await block()
            Issue.record("expected ExitCode.failure to be thrown but no error was raised")
        } catch let exit as ExitCode {
            #expect(exit == .failure, "expected ExitCode.failure; got \(exit)")
        } catch {
            Issue.record("expected ExitCode.failure but got \(error)")
        }
    }
}
