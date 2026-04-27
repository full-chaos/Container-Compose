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

/// Static argv-shape regression tests for `compose up` (PR-2 of the recorder
/// seam migration; see `docs/plans/PLAN-recorder-seam.md` §8).
///
/// Each test writes a temp compose YAML, parses `ComposeUp`, binds a
/// `RecordingRunner` via `RunnerEnvironment.$current.withValue(...)`, then
/// invokes `cmd.run()` and asserts the recorded `container run` argv.
///
/// The recorder consumes the `streaming` request that PR-2 routed through
/// the seam (replacing the deleted `ComposeUp.streamCommand`); all other
/// shell-out sites (run/create/kill/start/exec/watch) continue to use their
/// own helpers until PR-3..5 land. Build / image-pull / network-create stay
/// in-process per plan §3 / §10 Q1 and are not recorded.
@Suite("Runtime argv recording")
struct RuntimeArgvTests {

    // MARK: - Test scaffolding (per plan §8)

    /// Bind a fresh `RecordingRunner` for the duration of `body` and return it.
    /// Mirrors the template at the end of plan §8 verbatim.
    private func runWithRecorder(
        _ body: () async throws -> Void
    ) async throws -> RecordingRunner {
        let recorder = RecordingRunner()
        try await RunnerEnvironment.$current.withValue(recorder) {
            try await body()
        }
        return recorder
    }

    /// Write `yaml` to a fresh temp directory and return the directory + the
    /// compose file path. Caller is responsible for cleanup via the returned
    /// directory URL (typical pattern: a `defer` in the test body).
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

    /// Parse `ComposeUp` with `-f <composePath>` (post-subcommand form, since
    /// `ComposeUp.parse(...)` bypasses the global-flag normaliser). `--detach`
    /// is appended so `run()` returns instead of blocking on `waitForever()`.
    private func parseComposeUp(composePath: String) throws -> ComposeUp {
        try ComposeUp.parse(["--detach", "-f", composePath])
    }

    /// `cmd.run()` spawns an unstructured `Task { … }` to call the runner and
    /// then proceeds to `waitUntilServiceIsRunning`, which polls the runtime
    /// (independent of the seam). When run under a recorder, the runtime
    /// poll never observes a started container and may throw / time out;
    /// what we care about is that the unstructured Task reached the runner.
    /// Poll the recorder briefly until at least one `container run` argv
    /// has been captured (or fail with a clear message).
    private func awaitRecordedRunArgv(
        _ recorder: RecordingRunner,
        timeout: TimeInterval = 5
    ) async throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let argvs = await recorder.runArgvs()
            if let first = argvs.first { return first }
            try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        let all = await recorder.argvs()
        Issue.record(
            "No `container run` argv recorded within \(timeout)s. All recorded argvs: \(all)"
        )
        throw NSError(
            domain: "RuntimeArgvTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no run argv recorded"]
        )
    }

    /// Drive `cmd.run()` from inside the recorder binding. The call may
    /// throw because side helpers (image pull / network setup / runtime
    /// polling) reach out to Apple `container` directly; we only care
    /// about what the recorder captured up to that point.
    @discardableResult
    private func driveRun(_ cmd: inout ComposeUp) async -> Error? {
        do {
            try await cmd.run()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Plan §8 #1 — entrypoint placement (head-only)

    @Test("up: --entrypoint precedes image (single-element entrypoint)")
    func up_emits_entrypoint_before_image() async throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            entrypoint: ["/app/entrypoint.sh"]
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = try await runWithRecorder {
            var cmd = try parseComposeUp(composePath: compose.path)
            _ = await driveRun(&cmd)
        }

        let argv = try await awaitRecordedRunArgv(recorder)
        let entryIdx = try #require(argv.firstIndex(of: "--entrypoint"))
        let imgIdx = try #require(argv.firstIndex(of: "alpine:latest"))
        #expect(entryIdx < imgIdx, "--entrypoint must appear before the image")
        #expect(argv[entryIdx + 1] == "/app/entrypoint.sh")
    }

    // MARK: - Plan §8 #4 — entrypoint head + tail + command

    @Test("up: multi-token entrypoint splits around image; command appended")
    func up_entrypoint_with_command_appends_command_to_positional_args() async throws {
        let yaml = """
        services:
          worker:
            image: alpine:latest
            entrypoint: ["/sbin/tini", "--"]
            command: ["my-binary", "--flag"]
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = try await runWithRecorder {
            var cmd = try parseComposeUp(composePath: compose.path)
            _ = await driveRun(&cmd)
        }

        let argv = try await awaitRecordedRunArgv(recorder)

        // Locate landmarks.
        let entryIdx = try #require(argv.firstIndex(of: "--entrypoint"))
        let imgIdx = try #require(argv.firstIndex(of: "alpine:latest"))
        #expect(entryIdx < imgIdx, "--entrypoint must precede the image")
        // Head element of compose `entrypoint` lands as the --entrypoint value.
        #expect(argv[entryIdx + 1] == "/sbin/tini")

        // Remaining entrypoint tokens + command are positional, appearing in
        // order after the image.
        let tail = Array(argv.dropFirst(imgIdx + 1))
        // Find first "--" after the image — it's the second entrypoint token.
        let dashDashIdx = try #require(tail.firstIndex(of: "--"))
        #expect(dashDashIdx == 0, "remaining entrypoint tokens must immediately follow the image")
        // Then `command` tokens appear in order after the entrypoint tail.
        let myBinIdx = try #require(tail.firstIndex(of: "my-binary"))
        let flagIdx = try #require(tail.firstIndex(of: "--flag"))
        #expect(dashDashIdx < myBinIdx, "command must follow the entrypoint tail")
        #expect(myBinIdx < flagIdx, "command tokens must preserve compose ordering")
    }

    // MARK: - Plan §8 #5 — explicit-IP / protocol port mapping

    @Test("up: -p emits explicit IP and protocol mappings via composePortToRunArg")
    func up_emits_explicit_ip_port_mapping() async throws {
        let yaml = """
        services:
          web:
            image: nginx:alpine
            ports:
              - "127.0.0.1:18081:80"
              - "8080:80/udp"
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = try await runWithRecorder {
            var cmd = try parseComposeUp(composePath: compose.path)
            _ = await driveRun(&cmd)
        }

        let argv = try await awaitRecordedRunArgv(recorder)

        // Expected -p value pairs (per `composePortToRunArg` semantics in
        // `Helper Functions.swift`): explicit-IP form preserved, no-IP form
        // gets `0.0.0.0` prefix; protocol suffix preserved as-is.
        let expectedPairs: [(String, String)] = [
            ("-p", "127.0.0.1:18081:80"),
            ("-p", "0.0.0.0:8080:80/udp"),
        ]
        for (flag, value) in expectedPairs {
            let pairIdxs = argv.indices.filter { idx in
                argv[idx] == flag &&
                idx + 1 < argv.count &&
                argv[idx + 1] == value
            }
            #expect(
                !pairIdxs.isEmpty,
                "expected \(flag) \(value) in argv: \(argv)"
            )
        }
    }

    // MARK: - Plan §8 #6 — env_file + environment merging + ${BASE} substitution

    @Test("up: inline environment overrides env_file values; ${VAR} resolves from env_file")
    func up_merges_env_file_and_environment() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        // Synthetic env file: KEY (will be overridden by inline) and BASE
        // (will be referenced via ${BASE} from inline `environment`).
        let envFile = dir.appendingPathComponent("test.env")
        let envContent = """
        KEY=from_file
        BASE=resolved_base_value
        """
        try envContent.write(to: envFile, atomically: true, encoding: .utf8)

        // Compose YAML points at the absolute env_file path so `effectiveProjectDirectory`
        // resolution is unambiguous; inline `environment` overrides KEY and
        // references BASE via interpolation.
        let yaml = """
        services:
          app:
            image: alpine:latest
            env_file:
              - \(envFile.path)
            environment:
              KEY: from_inline
              OTHER: ${BASE}
        """
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)

        let recorder = try await runWithRecorder {
            var cmd = try parseComposeUp(composePath: compose.path)
            _ = await driveRun(&cmd)
        }

        let argv = try await awaitRecordedRunArgv(recorder)

        // Collect every `-e <K=V>` pair.
        var envPairs: [String] = []
        var idx = 0
        while idx < argv.count {
            if argv[idx] == "-e", idx + 1 < argv.count {
                envPairs.append(argv[idx + 1])
                idx += 2
            } else {
                idx += 1
            }
        }

        // Inline value wins (KEY=from_inline present, KEY=from_file absent).
        #expect(
            envPairs.contains("KEY=from_inline"),
            "inline `environment` must override env_file value (got: \(envPairs))"
        )
        #expect(
            !envPairs.contains("KEY=from_file"),
            "env_file value must NOT survive an inline override (got: \(envPairs))"
        )

        // ${BASE} substituted from env_file.
        #expect(
            envPairs.contains("OTHER=resolved_base_value"),
            "${BASE} must resolve via env_file (got: \(envPairs))"
        )
        #expect(
            !envPairs.contains("OTHER=${BASE}"),
            "unresolved ${BASE} must not survive (got: \(envPairs))"
        )
    }
}
