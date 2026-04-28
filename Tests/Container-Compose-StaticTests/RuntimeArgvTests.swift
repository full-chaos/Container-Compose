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
import ArgumentParser
import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
@testable import ContainerComposeCore
import TestHelpers

/// Static argv-shape regression tests for the `RunCommandRunner` seam
/// (PRs-2..5 of the recorder migration; see `docs/plans/PLAN-recorder-seam.md`
/// §8).
///
/// Each test writes a temp compose YAML, parses one of the `Compose*`
/// subcommands, binds a `RecordingRunner` via
/// `RunnerEnvironment.$current.withValue(...)`, then invokes `cmd.run()` and
/// asserts the recorded `container run` argv.
///
/// The recorder consumes the `streaming` requests that PRs-2/3 routed through
/// the seam (replacing `ComposeUp.streamCommand` and `ComposeRun.streamCommand`).
/// Remaining shell-out sites (create/kill/start/exec/watch) continue to use
/// their own helpers until PR-4..5 land. Build / image-pull / network-create
/// stay in-process per plan §3 / §10 Q1 and are not recorded.
@Suite("Runtime argv recording")
struct RuntimeArgvTests {

    // MARK: - Test scaffolding (per plan §8)

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

    /// Detach `cmd.run()` (where `cmd` is whatever the `parse` closure
    /// returns) under a fresh `RecordingRunner` task-local binding, poll the
    /// recorder until the first `container run` argv is captured, then cancel
    /// the run task and return the argv.
    ///
    /// Generalised over the parsing closure so this scaffolding can serve
    /// every `Compose*` subcommand (`up`, `run`, `create`, …) — PR-3 of the
    /// recorder migration extends the helper from PR-2's `ComposeUp`-only
    /// shape. Each call site supplies the concrete `parse([...])` invocation.
    ///
    /// Why detach + cancel: `cmd.run()`'s post-runner work (e.g.
    /// `ComposeUp.waitUntilServiceIsRunning`) polls the live `ContainerClient`
    /// until its 30 s timeout (no real container ever starts under the
    /// recorder). Awaiting `cmd.run()` to completion would pay that on every
    /// test. Spawning it in a detached `Task` and cancelling once the
    /// recorder has the argv keeps the test fast (locally <100 ms;
    /// cancellation propagates through the `Task.sleep` calls inside the
    /// polling loop).
    ///
    /// Why the timeout is 60 s and not 5 s: CI runners do not have Apple
    /// `container` installed, so the `pullImage` path that runs *before* the
    /// runner call (in `ComposeUp.configService` and `ComposeRun.run()`)
    /// calls into `ClientImage.list()` / `Application.ImagePull.parse(...)
    /// .run()` and takes several seconds to flow through before the runner
    /// call is reached. Locally these short-circuit in milliseconds. 60 s is
    /// comfortably above the observed CI path-to-runner latency without
    /// masking real failures.
    private func recordedRunArgv<C: AsyncParsableCommand>(
        timeout: TimeInterval = 60,
        parse: @escaping @Sendable () throws -> C
    ) async throws -> [String] {
        try await recordedFirstArgv(
            timeout: timeout,
            matching: { $0.starts(with: ["container", "run"]) },
            description: "container run",
            parse: parse
        )
    }

    /// Generalised polling variant of `recordedRunArgv`. Polls `recorder.argvs()`
    /// (every recorded request, not just `.streaming` `container run`s) and
    /// returns the first argv satisfying `matching`. PR-4 of the recorder
    /// migration introduced this generalisation so `compose create` tests can
    /// filter for the `["container", "create", ...]` argv that ComposeCreate
    /// emits AFTER its `.probe(["container", "create", "--help"])` call, while
    /// the existing `compose up` / `compose run` tests keep working unchanged
    /// via the `recordedRunArgv` wrapper above.
    private func recordedFirstArgv<C: AsyncParsableCommand>(
        timeout: TimeInterval = 60,
        matching predicate: @escaping @Sendable ([String]) -> Bool,
        description: String,
        parse: @escaping @Sendable () throws -> C
    ) async throws -> [String] {
        let recorder = RecordingRunner()
        let containerProvider = RecordingContainerClientProvider()
        let runTask = Task {
            try? await RunnerEnvironment.$current.withValue(recorder) {
                try await ContainerClientEnvironment.$current.withValue(containerProvider) {
                    var cmd = try parse()
                    try await cmd.run()
                }
            }
        }
        defer { runTask.cancel() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let argvs = await recorder.argvs()
            if let first = argvs.first(where: predicate) {
                runTask.cancel()
                return first
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }

        runTask.cancel()
        let all = await recorder.argvs()
        Issue.record(
            "No `\(description)` argv recorded within \(timeout)s. All recorded argvs: \(all)"
        )
        throw NSError(
            domain: "RuntimeArgvTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no \(description) argv recorded"]
        )
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

        let argv = try await recordedRunArgv {
            try ComposeUp.parse(["--detach", "-f", compose.path])
        }
        let entryIdx = try #require(argv.firstIndex(of: "--entrypoint"))
        let imgIdx = try #require(argv.firstIndex(of: "docker.io/library/alpine:latest"))
        #expect(entryIdx < imgIdx, "--entrypoint must appear before the image")
        #expect(argv[entryIdx + 1] == "/app/entrypoint.sh")
    }

    // MARK: - Plan §8 #2 — `compose run` entrypoint placement (PR-3 regression)

    @Test("run: --entrypoint precedes image (regression for ComposeRun §1 bug)")
    func run_emits_entrypoint_before_image() async throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            entrypoint: ["/app/entrypoint.sh"]
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        // `ComposeRun.parse(["-f", composePath, "app"])`: -f is an @Option
        // (parsed before the @Argument), "app" is the @Argument serviceName,
        // and no trailing tokens means the captureForPassthrough `command`
        // remains empty so the service-level `entrypoint` is honored.
        let argv = try await recordedRunArgv {
            try ComposeRun.parse(["-f", compose.path, "app"])
        }
        let entryIdx = try #require(argv.firstIndex(of: "--entrypoint"))
        let imgIdx = try #require(argv.firstIndex(of: "docker.io/library/alpine:latest"))
        #expect(entryIdx < imgIdx, "--entrypoint must appear before the image")
        #expect(argv[entryIdx + 1] == "/app/entrypoint.sh")
    }

    // MARK: - Plan §8 #3 — `compose create` entrypoint placement (PR-4 regression)

    @Test("create: --entrypoint precedes image (regression for ComposeCreate §1 bug)")
    func create_emits_entrypoint_before_image() async throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            entrypoint: ["/app/entrypoint.sh"]
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        // ComposeCreate emits a `.probe(["container", "create", "--help"])`
        // request first to test capability, then the actual
        // `.awaitOnly(["container", "create", "--name", ..., ...])` request.
        // Filter past the probe to the create call itself.
        let argv = try await recordedFirstArgv(
            matching: { argv in
                argv.starts(with: ["container", "create", "--name"])
            },
            description: "container create"
        ) {
            try ComposeCreate.parse(["-f", compose.path])
        }

        let entryIdx = try #require(argv.firstIndex(of: "--entrypoint"))
        let imgIdx = try #require(argv.firstIndex(of: "docker.io/library/alpine:latest"))
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

        let argv = try await recordedRunArgv {
            try ComposeUp.parse(["--detach", "-f", compose.path])
        }

        // Locate landmarks.
        let entryIdx = try #require(argv.firstIndex(of: "--entrypoint"))
        let imgIdx = try #require(argv.firstIndex(of: "docker.io/library/alpine:latest"))
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

        let argv = try await recordedRunArgv {
            try ComposeUp.parse(["--detach", "-f", compose.path])
        }

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

        let argv = try await recordedRunArgv {
            try ComposeUp.parse(["--detach", "-f", compose.path])
        }

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

    @Test("up: env_file mapping form produces same -e flags as string form")
    func up_env_file_mapping_form_produces_same_args() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let envFile = dir.appendingPathComponent("api.env")
        try "TOKEN=abc123\nREGION=us-west\n".write(to: envFile, atomically: true, encoding: .utf8)

        // Mapping form with required: false should decode and produce the same
        // -e pairs as the equivalent scalar form.
        let yaml = """
        services:
          api:
            image: alpine:latest
            env_file:
              - path: \(envFile.path)
                required: false
        """
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)

        let argv = try await recordedRunArgv {
            try ComposeUp.parse(["--detach", "-f", compose.path])
        }

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

        #expect(envPairs.contains("TOKEN=abc123"), "mapping-form env_file must contribute its keys (got: \(envPairs))")
        #expect(envPairs.contains("REGION=us-west"), "mapping-form env_file must contribute its keys (got: \(envPairs))")
    }

    // MARK: - PR-6 — full pipeline coverage (swiftAPI + streaming run)

    /// Proof that PR-6 routes the in-process `Application.*` calls through
    /// the seam: when running under a `RecordingRunner`, the recorder must
    /// capture BOTH the `swiftAPI(name: "ImagePull")` request AND the
    /// `streaming` `container run` request — without ever reaching Apple
    /// `container`. Previously the path-to-runner went through
    /// `pullImage`'s direct call into `Application.ImagePull.parse(...).run()`,
    /// which on CI (no runtime installed) failed before the streaming runner
    /// call was reached.
    @Test("up: recorder captures swiftAPI(ImagePull) AND streaming(container run)")
    func up_recorder_captures_full_pipeline() async throws {
        // `pull_policy: always` forces `pullImage` past its `imageExists`
        // short-circuit even when the image is already cached locally
        // (which is the typical local-developer state). Under a
        // `RecordingRunner`, this guarantees the swiftAPI(ImagePull) call
        // fires and is recorded — the central regression target of PR-6.
        let yaml = """
        services:
          app:
            image: alpine:latest
            pull_policy: always
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = RecordingRunner()
        let containerProvider = RecordingContainerClientProvider()
        let runTask = Task {
            try? await RunnerEnvironment.$current.withValue(recorder) {
                try await ContainerClientEnvironment.$current.withValue(containerProvider) {
                    var cmd = try ComposeUp.parse(["--detach", "-f", compose.path])
                    try await cmd.run()
                }
            }
        }
        defer { runTask.cancel() }

        // Wait until BOTH the swiftAPI ImagePull AND the streaming `container
        // run` calls have been recorded. Prior to PR-6, on a host without
        // Apple `container` installed, the recorder would only ever see the
        // streaming run if pullImage's call somehow short-circuited; with
        // PR-6 the swiftAPI call is recorded directly.
        let deadline = Date().addingTimeInterval(60)
        var observedPullArgv: [String]? = nil
        var observedRunArgv: [String]? = nil
        while Date() < deadline {
            let pulls = await recorder.swiftAPIArgvs(named: "ImagePull")
            let runs = await recorder.runArgvs()
            if let firstPull = pulls.first, let firstRun = runs.first {
                observedPullArgv = firstPull
                observedRunArgv = firstRun
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        runTask.cancel()

        let pull = try #require(observedPullArgv, "expected a recorded swiftAPI(ImagePull) within 60s")
        let run = try #require(observedRunArgv, "expected a recorded streaming(container run) within 60s")

        // ImagePull's argv begins with the image name (positional), per
        // pullImage's `var commands = [imageName]` construction.
        #expect(
            pull.first == "docker.io/library/alpine:latest",
            "ImagePull argv[0] should be the image name (got: \(pull))"
        )
        // Streaming run argv must start with ["container", "run", ...].
        #expect(
            run.starts(with: ["container", "run"]),
            "streaming run argv must start with [container, run] (got: \(run))"
        )
        #expect(
            run.contains("docker.io/library/alpine:latest"),
            "streaming run argv must include the image name (got: \(run))"
        )
    }

    // MARK: - Plan §8 #7 — build emits labels and cache_from (enabled by PR-6)

    /// Plan §8 test 7: the `Application.BuildCommand.parse(...)` argv carries
    /// `--label key=value` and `--cache-from refX` flags as built by
    /// `ComposeBuild.buildService`. Was disabled in earlier PRs because the
    /// build path did not flow through the seam; PR-6 enables it.
    @Test("build: BuildCommand argv carries --label and --cache-from")
    func build_emits_labels_and_cache_from() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a stub Dockerfile so resolution doesn't fail upstream.
        let dockerfile = dir.appendingPathComponent("Dockerfile")
        try "FROM alpine:latest\n".write(to: dockerfile, atomically: true, encoding: .utf8)

        let yaml = """
        services:
          api:
            build:
              context: .
              dockerfile: Dockerfile
              labels:
                org.opencontainers.image.title: api
                org.opencontainers.image.version: "1.0"
              cache_from:
                - registry.example.com/api:cache
                - registry.example.com/api:base
        """
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)

        let recorder = RecordingRunner()
        let containerProvider = RecordingContainerClientProvider()
        try await RunnerEnvironment.$current.withValue(recorder) {
            try await ContainerClientEnvironment.$current.withValue(containerProvider) {
                var cmd = try ComposeBuild.parse(["-f", compose.path])
                try await cmd.run()
            }
        }

        let buildArgvs = await recorder.swiftAPIArgvs(named: "BuildCommand")
        let argv = try #require(buildArgvs.first, "expected a swiftAPI(BuildCommand) call to be recorded")

        // Helper: collect every `[flag, value]` pair from the argv.
        func valuesFor(flag: String) -> [String] {
            var values: [String] = []
            var idx = 0
            while idx < argv.count {
                if argv[idx] == flag, idx + 1 < argv.count {
                    values.append(argv[idx + 1])
                    idx += 2
                } else {
                    idx += 1
                }
            }
            return values
        }

        let labels = valuesFor(flag: "--label")
        #expect(
            labels.contains("org.opencontainers.image.title=api"),
            "expected --label org.opencontainers.image.title=api (got labels: \(labels), full argv: \(argv))"
        )
        #expect(
            labels.contains("org.opencontainers.image.version=1.0"),
            "expected --label org.opencontainers.image.version=1.0 (got labels: \(labels), full argv: \(argv))"
        )

        let cacheFroms = valuesFor(flag: "--cache-from")
        #expect(
            cacheFroms.contains("registry.example.com/api:cache"),
            "expected --cache-from registry.example.com/api:cache (got cache-froms: \(cacheFroms), full argv: \(argv))"
        )
        #expect(
            cacheFroms.contains("registry.example.com/api:base"),
            "expected --cache-from registry.example.com/api:base (got cache-froms: \(cacheFroms), full argv: \(argv))"
        )
    }

    // MARK: - Plan §8 #8 — kill emits --signal in argv (PR-5 regression)

    /// Plan §8 #8: every recorded `container kill` argv carries
    /// `--signal SIGUSR1` and the project's container id. `ComposeKill` first
    /// calls `ContainerClientEnvironment.current.get(id:)` to verify the
    /// container exists; only then does it shell out to `container kill`.
    /// `RecordingContainerClientProvider.get(id:)` throws "not found", which
    /// would short-circuit the loop before reaching the seam — so this test
    /// substitutes `KillTestContainerProvider` (defined below) which returns
    /// a synthetic snapshot from `get(id:)` so the kill code path proceeds
    /// to the runner. `imageList` / `networkGet` retain the not-found
    /// semantics of the recording provider.
    @Test("kill: argv carries --signal and applies to project containers")
    func kill_emits_signal_in_argv() async throws {
        let yaml = """
        services:
          web:
            image: nginx:alpine
          worker:
            image: alpine:latest
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = RecordingRunner()
        let containerProvider = KillTestContainerProvider()
        try await RunnerEnvironment.$current.withValue(recorder) {
            try await ContainerClientEnvironment.$current.withValue(containerProvider) {
                var cmd = try ComposeKill.parse(["--signal", "SIGUSR1", "-f", compose.path])
                try await cmd.run()
            }
        }

        // Every recorded argv must be a `container kill --signal SIGUSR1 …`
        // call, one per project service (per plan §8 #8: "Order matches
        // reverse topo-sort"). Two services in the YAML ⇒ two kill argvs.
        let argvs = await recorder.argvs()
        let killArgvs = argvs.filter { $0.starts(with: ["container", "kill"]) }
        #expect(
            killArgvs.count == 2,
            "expected one `container kill` per service (got \(killArgvs.count): \(killArgvs))"
        )

        for argv in killArgvs {
            #expect(argv[0] == "container")
            #expect(argv[1] == "kill")
            #expect(
                argv.contains("--signal"),
                "argv must include --signal (got: \(argv))"
            )
            let signalIdx = try #require(argv.firstIndex(of: "--signal"))
            #expect(
                argv[signalIdx + 1] == "SIGUSR1",
                "--signal value must be SIGUSR1 (got: \(argv))"
            )
            // The trailing positional argument is the container id, derived
            // from the synthetic snapshot KillTestContainerProvider returns.
            #expect(
                argv.last?.hasSuffix("-web") == true || argv.last?.hasSuffix("-worker") == true,
                "argv last token must be a project container id (got: \(argv))"
            )
        }
    }
}

// MARK: - Test-only ContainerClientProvider for kill_emits_signal_in_argv

/// `ComposeKill.killServices` calls `ContainerClientEnvironment.current.get(id:)`
/// before each shell-out to verify the container exists. Returning a real
/// `ContainerSnapshot` here forces the kill loop to proceed to the
/// `RunCommandRunner` seam; the existing `RecordingContainerClientProvider`
/// throws on `get(id:)` to mimic "not found" (its design contract per plan
/// §10 Q2), which makes it unusable for kill argv recording.
///
/// Defined inline (rather than added to `Tests/TestHelpers/`) per the PR-5
/// constraint that keeps `Tests/TestHelpers/RecordingContainerClientProvider.swift`
/// untouched.
private actor KillTestContainerProvider: ContainerClientProvider {
    func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] { [] }

    func get(id: String) async throws -> ContainerSnapshot {
        // Construct a minimal-but-valid snapshot whose `id` matches the
        // requested name. `ComposeKill` uses `container.id` as the trailing
        // argv positional, so the recorded argv tail must be exactly `id`.
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            size: 0
        )
        let image = ImageDescription(reference: id, descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "true"],
            environment: []
        )
        let configuration = ContainerConfiguration(id: id, image: image, process: process)
        return ContainerSnapshot(
            configuration: configuration,
            status: .running,
            networks: []
        )
    }

    func stop(id: String, opts: ContainerStopOptions) async throws {}
    func delete(id: String, force: Bool) async throws {}
    func logs(id: String) async throws -> [FileHandle] { [] }

    func networkGet(id: String) async throws -> NetworkState {
        throw NSError(
            domain: "KillTestContainerProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no network '\(id)'"]
        )
    }

    func imageList() async throws -> [ClientImage] { [] }
}
