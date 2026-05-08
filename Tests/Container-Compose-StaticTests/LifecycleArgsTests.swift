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
@testable import Yams
@testable import ContainerComposeCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Tests for Phase 2E: LifecycleArgs.build and the parseGoDuration helper.
@Suite("LifecycleArgs Tests", .serialized)
struct LifecycleArgsTests {

    /// Reset the process-wide warn-once dedup set before each test so the
    /// warn-content assertions (`captured.output.contains("Note: ...")`)
    /// don't flake based on which other suite ran first. Sibling suites
    /// like `LabelsArgsTests` and `LoggingArgsTests` also invoke
    /// `LifecycleArgs.build` with `stop_signal`/`stop_grace_period`,
    /// which would otherwise consume the one-shot warning.
    init() {
        resetUnsupportedRuntimeFieldWarningsForTesting()
    }

    // MARK: - Helpers

    private func makeDockerCompose() -> DockerCompose {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        return try! YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    /// Build a minimal ArgsContext for LifecycleArgs.build calls.
    private func makeContext(
        service: Service,
        detach: Bool = false,
        supportsHealthcheckFlags: Bool = true,
        supportsRestartFlag: Bool = false
    ) -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "proj",
            containerName: "proj-svc",
            detach: detach,
            environmentVariables: [:],
            dockerCompose: makeDockerCompose(),
            composeFilename: nil,
            supportsHealthcheckFlags: supportsHealthcheckFlags,
            supportsRestartFlag: supportsRestartFlag
        )
    }

    private func capturedArgs(
        _ service: Service,
        supportsHealthcheckFlags: Bool = true,
        supportsRestartFlag: Bool = false
    ) throws -> (output: String, args: [String]) {
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        let pipe = Pipe()
        guard original >= 0, dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            if original >= 0 { close(original) }
            throw CaptureError.dupFailed
        }

        let result = ComposeUp.LifecycleArgs.build(makeContext(
            service: service,
            supportsHealthcheckFlags: supportsHealthcheckFlags,
            supportsRestartFlag: supportsRestartFlag
        ))
        fflush(stdout)
        restoreStandardOutput(original: original, pipe: pipe)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", result)
    }

    private func restoreStandardOutput(original: Int32, pipe: Pipe) {
        _ = dup2(original, STDOUT_FILENO)
        close(original)
        pipe.fileHandleForWriting.closeFile()
    }

    private enum CaptureError: Error {
        case dupFailed
    }

    // MARK: - init_ flag

    @Test("init_ true emits --init flag")
    func initTrueEmitsFlag() {
        let svc = Service(image: "alpine", init_: true)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("--init"))
    }

    @Test("init_ nil does not emit --init flag")
    func initNilAbsent() {
        let svc = Service(image: "alpine", init_: nil)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--init"))
    }

    @Test("init_ false does not emit --init flag")
    func initFalseAbsent() {
        let svc = Service(image: "alpine", init_: false)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--init"))
    }

    // MARK: - stop_signal

    @Test("stop_signal warns and emits no unsupported --stop-signal flag")
    func stopSignalWarnsAndEmitsNoUnsupportedFlag() throws {
        let svc = Service(image: "alpine", stop_signal: "SIGUSR1")
        let captured = try capturedArgs(svc)
        #expect(!captured.args.contains("--stop-signal"))
        #expect(!captured.args.contains("SIGUSR1"))
        #expect(captured.output.contains("Note: 'service.stop_signal' is parsed but not supported by Apple container; ignored."))
    }

    @Test("stop_signal nil means --stop-signal absent")
    func stopSignalNilAbsent() {
        let svc = Service(image: "alpine", stop_signal: nil)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--stop-signal"))
    }

    // MARK: - stop_grace_period / parseGoDuration

    @Test("parseGoDuration: 30s → 30")
    func parseDuration30s() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("30s") == 30)
    }

    @Test("parseGoDuration: 1m → 60")
    func parseDuration1m() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("1m") == 60)
    }

    @Test("parseGoDuration: 1m30s → 90")
    func parseDuration1m30s() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("1m30s") == 90)
    }

    @Test("parseGoDuration: raw integer 5 → 5")
    func parseDurationRawInt() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("5") == 5)
    }

    @Test("parseGoDuration: unparseable 'abc' → nil")
    func parseDurationInvalidNil() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("abc") == nil)
    }

    @Test("parseGoDuration: 2h → 7200")
    func parseDuration2h() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("2h") == 7200)
    }

    @Test("parseGoDuration: 1h2m3s → 3723")
    func parseDurationFull() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("1h2m3s") == 3723)
    }

    @Test("stop_grace_period warns and emits no unsupported --stop-timeout flag")
    func stopGracePeriodWarnsAndEmitsNoUnsupportedFlag() throws {
        let svc = Service(image: "alpine", stop_grace_period: "30s")
        let captured = try capturedArgs(svc)
        #expect(!captured.args.contains("--stop-timeout"))
        #expect(!captured.args.contains("30"))
        #expect(captured.output.contains("Note: 'service.stop_grace_period' is parsed but not supported by Apple container; ignored."))
    }

    @Test("stop_grace_period 1m30s emits no unsupported --stop-timeout flag")
    func stopGracePeriod1m30sAbsent() {
        let svc = Service(image: "alpine", stop_grace_period: "1m30s")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--stop-timeout"))
        #expect(!args.contains("90"))
    }

    @Test("stop_grace_period unparseable means --stop-timeout absent")
    func stopGracePeriodBadValueAbsent() {
        let svc = Service(image: "alpine", stop_grace_period: "abc")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--stop-timeout"))
    }

    @Test("stop_grace_period raw integer emits no unsupported --stop-timeout flag")
    func stopGracePeriodRawIntAbsent() {
        let svc = Service(image: "alpine", stop_grace_period: "5")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--stop-timeout"))
        #expect(!args.contains("5"))
    }

    // MARK: - runtime

    @Test("runtime emits --runtime with value")
    func runtimeEmits() {
        let svc = Service(image: "alpine", runtime: "nvidia")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("--runtime"))
        let idx = args.firstIndex(of: "--runtime")
        #expect(idx != nil)
        if let i = idx {
            #expect(args[args.index(after: i)] == "nvidia")
        }
    }

    @Test("runtime nil means --runtime absent")
    func runtimeNilAbsent() {
        let svc = Service(image: "alpine", runtime: nil)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--runtime"))
    }

    // MARK: - restart: --restart flag emitted

    @Test("restart present emits --restart flag with value")
    func restartEmitsFlag() {
        let svc = Service(image: "alpine", restart: "always")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc, supportsRestartFlag: true))
        #expect(args.contains("--restart"))
        if let idx = args.firstIndex(of: "--restart") {
            #expect(args[args.index(after: idx)] == "always")
        }
    }

    @Test("restart on-failure emits correct value")
    func restartOnFailure() {
        let svc = Service(image: "alpine", restart: "on-failure")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc, supportsRestartFlag: true))
        if let idx = args.firstIndex(of: "--restart") {
            #expect(args[args.index(after: idx)] == "on-failure")
        } else {
            Issue.record("--restart flag not found")
        }
    }

    @Test("restart absent does not emit --restart flag")
    func restartAbsentNoFlag() {
        let svc = Service(image: "alpine")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc, supportsRestartFlag: true))
        #expect(!args.contains("--restart"))
    }

    // MARK: - restart: supportsRestartFlag gate

    @Test("restart unless-stopped emits --restart when gate is open")
    func restartUnlessStopped_whenSupported() {
        let svc = Service(image: "alpine", restart: "unless-stopped")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc, supportsRestartFlag: true))
        #expect(args.contains("--restart"))
        if let idx = args.firstIndex(of: "--restart") {
            #expect(args[args.index(after: idx)] == "unless-stopped")
        } else {
            Issue.record("--restart flag not found")
        }
    }

    @Test("restart gated off when supportsRestartFlag is false: no --restart, warn emitted")
    func restartGatedWhenFlagUnsupported() throws {
        let svc = Service(image: "alpine", restart: "unless-stopped")
        let captured = try capturedArgs(svc, supportsRestartFlag: false)
        #expect(!captured.args.contains("--restart"))
        #expect(captured.output.contains("Note: 'restart' is parsed but not supported by Apple container; ignored. (CHAOS-1321 tracks upstream support.)"))
    }

    // MARK: - healthcheck

    @Test("healthcheck CMD-SHELL emits fork health flags")
    func healthcheckCmdShellEmitsFlags() {
        let healthcheck = Healthcheck(
            test: ["CMD-SHELL", "redis-cli ping"],
            start_period: "40s",
            interval: "5s",
            retries: 3,
            timeout: "2s",
            start_interval: "1s"
        )
        let svc = Service(image: "redis:7-alpine", healthcheck: healthcheck)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))

        #expect(args.contains("--health-cmd"))
        if let idx = args.firstIndex(of: "--health-cmd") {
            #expect(args[args.index(after: idx)] == "redis-cli ping")
        }
        #expect(args.contains("--health-interval"))
        if let idx = args.firstIndex(of: "--health-interval") {
            #expect(args[args.index(after: idx)] == "5")
        }
        #expect(args.contains("--health-timeout"))
        if let idx = args.firstIndex(of: "--health-timeout") {
            #expect(args[args.index(after: idx)] == "2")
        }
        #expect(args.contains("--health-retries"))
        if let idx = args.firstIndex(of: "--health-retries") {
            #expect(args[args.index(after: idx)] == "3")
        }
        #expect(args.contains("--health-start-period"))
        if let idx = args.firstIndex(of: "--health-start-period") {
            #expect(args[args.index(after: idx)] == "40")
        }
        #expect(args.contains("--health-start-interval"))
        if let idx = args.firstIndex(of: "--health-start-interval") {
            #expect(args[args.index(after: idx)] == "1")
        }
    }

    @Test("healthcheck CMD form is converted to a shell command for the fork CLI")
    func healthcheckCmdFormShellQuotesArguments() {
        let healthcheck = Healthcheck(test: ["CMD", "test", "-f", "/tmp/ready file"])
        let svc = Service(image: "alpine", healthcheck: healthcheck)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))

        if let idx = args.firstIndex(of: "--health-cmd") {
            #expect(args[args.index(after: idx)] == "test -f '/tmp/ready file'")
        } else {
            Issue.record("--health-cmd flag not found")
        }
    }

    @Test("healthcheck disable emits --no-healthcheck")
    func healthcheckDisableEmitsNoHealthcheck() {
        let healthcheck = Healthcheck(test: ["CMD-SHELL", "redis-cli ping"], disable: true)
        let svc = Service(image: "redis:7-alpine", healthcheck: healthcheck)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))

        #expect(args == ["--name", "proj-svc", "--no-healthcheck"])
    }

    @Test("healthcheck NONE emits --no-healthcheck")
    func healthcheckNoneEmitsNoHealthcheck() {
        let healthcheck = Healthcheck(test: ["NONE"])
        let svc = Service(image: "alpine", healthcheck: healthcheck)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))

        #expect(args == ["--name", "proj-svc", "--no-healthcheck"])
    }

    @Test("healthcheck timing without test warns instead of emitting orphan runtime flags")
    func healthcheckTimingWithoutTestWarns() throws {
        let healthcheck = Healthcheck(interval: "5s", retries: 2)
        let svc = Service(image: "alpine", healthcheck: healthcheck)
        let captured = try capturedArgs(svc)

        #expect(!captured.args.contains("--health-interval"))
        #expect(!captured.args.contains("--health-retries"))
        #expect(captured.output.contains("Note: healthcheck timing fields require 'healthcheck.test' before they can be passed to the runtime; ignored."))
    }

    @Test("healthcheck is warn-skipped when runtime flags are unavailable")
    func healthcheckWarnSkippedWhenRuntimeUnsupported() throws {
        let healthcheck = Healthcheck(test: ["CMD-SHELL", "redis-cli ping"])
        let svc = Service(image: "redis:7-alpine", healthcheck: healthcheck)
        let captured = try capturedArgs(svc, supportsHealthcheckFlags: false)

        #expect(!captured.args.contains("--health-cmd"))
        #expect(!captured.args.contains("--no-healthcheck"))
        #expect(captured.output.contains("Note: 'service.healthcheck' is parsed but the installed container runtime does not support --health-cmd / --health-* flags yet; ignored."))
    }

    // MARK: - Regression: existing flags still emitted

    @Test("platform still emits --platform")
    func platformRegression() {
        let svc = Service(image: "alpine", platform: "linux/amd64")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("--platform"))
        let idx = args.firstIndex(of: "--platform")
        if let i = idx {
            #expect(args[args.index(after: i)] == "linux/amd64")
        }
    }

    @Test("detach still emits -d")
    func detachRegression() {
        let svc = Service(image: "alpine")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc, detach: true))
        #expect(args.contains("-d"))
    }

    @Test("name still emits --name with containerName")
    func nameRegression() {
        let svc = Service(image: "alpine")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("--name"))
        let idx = args.firstIndex(of: "--name")
        if let i = idx {
            #expect(args[args.index(after: i)] == "proj-svc")
        }
    }

    @Test("stdin_open still emits -i")
    func stdinRegression() {
        let svc = Service(image: "alpine", stdin_open: true)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("-i"))
    }

    @Test("tty still emits -t")
    func ttyRegression() {
        let svc = Service(image: "alpine", tty: true)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("-t"))
    }
}
