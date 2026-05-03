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

@Suite("Resource Args Tests", .serialized)
struct ResourceArgsTests {

    // MARK: - Helpers

    /// Decode a minimal DockerCompose from trivial YAML — used only to satisfy ArgsContext.
    private func minimalDockerCompose() throws -> DockerCompose {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        return try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    /// Build a minimal ArgsContext for the given service.
    private func ctx(_ service: Service) throws -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "test",
            containerName: "test-svc",
            detach: true,
            environmentVariables: [:],
            dockerCompose: try minimalDockerCompose(),
            composeFilename: nil
        )
    }

    /// Build argv for the given service via ResourceArgs.
    private func args(_ service: Service) throws -> [String] {
        ComposeUp.ResourceArgs.build(try ctx(service))
    }

    private func capturedArgs(_ service: Service) throws -> (output: String, args: [String]) {
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        let pipe = Pipe()
        guard original >= 0, dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            if original >= 0 { close(original) }
            throw CaptureError.dupFailed
        }

        do {
            let result = try args(service)
            fflush(stdout)
            restoreStandardOutput(original: original, pipe: pipe)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", result)
        } catch {
            fflush(stdout)
            restoreStandardOutput(original: original, pipe: pipe)
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            throw error
        }
    }

    private func restoreStandardOutput(original: Int32, pipe: Pipe) {
        _ = dup2(original, STDOUT_FILENO)
        close(original)
        pipe.fileHandleForWriting.closeFile()
    }

    private enum CaptureError: Error {
        case dupFailed
    }

    private func expectWarnSkipped(_ service: Service, flag: String, field: String) throws {
        let captured = try capturedArgs(service)
        #expect(!captured.args.contains(flag))
        #expect(captured.output.contains("Note: '\(field)' is parsed but not supported by Apple container; ignored."))
    }

    /// Decode a service directly from YAML to pick up deploy sub-fields.
    private func decodeService(_ serviceYaml: String) throws -> Service {
        let yaml = """
        services:
          svc:
        \(serviceYaml.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }.joined(separator: "\n"))
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        return try #require(compose.services["svc"] as? Service)
    }

    // MARK: - Individual flags

    @Test("cpus_top emits --cpus")
    func cpusTopFlag() throws {
        let svc = Service(image: "alpine", cpus_top: 2.5)
        let result = try args(svc)
        #expect(result.contains("--cpus"))
        let idx = try #require(result.firstIndex(of: "--cpus"))
        #expect(result[idx + 1] == "2.5")
    }

    @Test("mem_limit emits --memory")
    func memLimitFlag() throws {
        let svc = Service(image: "alpine", mem_limit: "512m")
        let result = try args(svc)
        #expect(result.contains("--memory"))
        let idx = try #require(result.firstIndex(of: "--memory"))
        #expect(result[idx + 1] == "512m")
    }

    @Test("Compose memory parser accepts supported suffixes", arguments: [
        ("0", UInt64(0)),
        ("1024", UInt64(1024)),
        ("256m", UInt64(268_435_456)),
        ("1g", UInt64(1_073_741_824)),
        ("1Gi", UInt64(1_073_741_824)),
        ("2Ki", UInt64(2_048)),
        ("1KB", UInt64(1_000)),
        ("1MB", UInt64(1_000_000))
    ])
    func composeMemoryParserAcceptsSupportedSuffixes(input: String, expected: UInt64) throws {
        #expect(try parseComposeMemoryBytes(input) == expected)
    }

    @Test("Compose memory parser rejects invalid input", arguments: ["", "abc", "1xb", "-1m"])
    func composeMemoryParserRejectsInvalidInput(input: String) {
        #expect(throws: (any Error).self) {
            try parseComposeMemoryBytes(input)
        }
    }

    // MARK: - Reservation-as-degraded-fallback (CHAOS-1336)
    //
    // Apple container does not implement Docker-style soft reservation semantics
    // (VM-per-container model — there is no inter-container contention inside a
    // dedicated VM). When a compose service declares a reservation but no limit,
    // Container-Compose maps the reservation onto the corresponding hard-limit
    // flag (--cpus / --memory) and warns the user about the degraded semantics.
    // When both a limit and a reservation are present, the limit wins (current
    // behavior preserved) and a warning notes that the reservation is ignored.
    //
    // Each warning key fires once per process (see warnUnsupportedRuntimeFieldOnce).
    // To stay deterministic under that dedupe, tests that ASSERT a warning text
    // are declared BEFORE any other test that triggers the same key. The suite is
    // .serialized so declaration order is execution order.

    @Test("mem_reservation maps to --memory as degraded fallback when no mem_limit")
    func memReservationFallsBackToMemory() throws {
        let svc = Service(image: "alpine", mem_reservation: "256m")
        let captured = try capturedArgs(svc)
        #expect(captured.args.contains("--memory"))
        let idx = try #require(captured.args.firstIndex(of: "--memory"))
        #expect(captured.args[idx + 1] == "256m")
        #expect(captured.output.contains("'service.mem_reservation' is mapped to '--memory'"))
        #expect(captured.output.contains("does not implement soft reservation semantics"))
    }

    @Test("deploy.resources.reservations.memory maps to --memory as degraded fallback when no limit")
    func deployReservationMemoryFallsBackToMemory() throws {
        let svc = try decodeService("""
          image: alpine
          deploy:
            resources:
              reservations:
                memory: "256m"
        """)
        let captured = try capturedArgs(svc)
        #expect(captured.args.contains("--memory"))
        let idx = try #require(captured.args.firstIndex(of: "--memory"))
        #expect(captured.args[idx + 1] == "256m")
        #expect(captured.output.contains("'service.deploy.resources.reservations.memory' is mapped to '--memory'"))
    }

    @Test("deploy.resources.reservations.cpus maps to --cpus as degraded fallback when no limit")
    func deployReservationCpusFallsBackToCpus() throws {
        let svc = try decodeService("""
          image: alpine
          deploy:
            resources:
              reservations:
                cpus: "0.5"
        """)
        let captured = try capturedArgs(svc)
        #expect(captured.args.contains("--cpus"))
        let idx = try #require(captured.args.firstIndex(of: "--cpus"))
        #expect(captured.args[idx + 1] == "0.5")
        #expect(captured.output.contains("'service.deploy.resources.reservations.cpus' is mapped to '--cpus'"))
    }

    // MARK: - Limit-with-reservation (CHAOS-1336): limit wins, ignored-reservation warning
    //
    // The warning-asserting tests run FIRST for each shared key
    // (service.memory.reservation-exceeds-limit, service.cpu.reservation-exceeds-limit,
    // service.memory.reservation-with-limit, service.cpu.reservation-with-limit).
    // The argv-only follow-up tests verify precedence without re-asserting on warning state.

    @Test("mem_limit + mem_reservation: reservation greater than limit warns as invalid input")
    func memLimitWithReservationExceedsLimitWarnsInvalid() throws {
        let svc = Service(image: "alpine", mem_limit: "256m", mem_reservation: "512m")
        let captured = try capturedArgs(svc)
        #expect(captured.args.contains("--memory"))
        let idx = try #require(captured.args.firstIndex(of: "--memory"))
        #expect(captured.args[idx + 1] == "256m")
        #expect(!captured.args.contains("512m"))
        #expect(captured.output.contains("reservation (512m) exceeds limit (256m); reservation will be ignored"))
        #expect(captured.output.contains("invalid compose input"))
        #expect(!captured.output.contains("memory reservation is ignored because a memory limit is set"))
    }

    @Test("cpus_top + deploy.reservations.cpus: reservation greater than limit warns as invalid input")
    func cpusTopWithReservationExceedsLimitWarnsInvalid() throws {
        let svc = try decodeService("""
          image: alpine
          cpus: 1.0
          deploy:
            resources:
              reservations:
                cpus: "2.0"
        """)
        let captured = try capturedArgs(svc)
        #expect(captured.args.contains("--cpus"))
        let idx = try #require(captured.args.firstIndex(of: "--cpus"))
        #expect(captured.args[idx + 1] == "1.0")
        #expect(!captured.args.contains("2.0"))
        #expect(captured.output.contains("reservation (2.0) exceeds limit (1.0); reservation will be ignored"))
        #expect(captured.output.contains("invalid compose input"))
        #expect(!captured.output.contains("CPU reservation is ignored because a CPU limit is set"))
    }

    @Test("deploy.limits.memory + deploy.reservations.memory: reservation greater than limit still uses limit")
    func deployLimitMemoryWithReservationExceedsLimitUsesLimit() throws {
        let svc = try decodeService("""
          image: alpine
          deploy:
            resources:
              limits:
                memory: "256m"
              reservations:
                memory: "512m"
        """)
        let captured = try capturedArgs(svc)
        #expect(captured.args.contains("--memory"))
        let idx = try #require(captured.args.firstIndex(of: "--memory"))
        #expect(captured.args[idx + 1] == "256m")
        #expect(!captured.args.contains("512m"))
        #expect(!captured.output.contains("memory reservation is ignored because a memory limit is set"))
    }

    @Test("deploy.limits.cpus + deploy.reservations.cpus: reservation greater than limit still uses limit")
    func deployLimitCpusWithReservationExceedsLimitUsesLimit() throws {
        let svc = try decodeService("""
          image: alpine
          deploy:
            resources:
              limits:
                cpus: "1.0"
              reservations:
                cpus: "2.0"
        """)
        let captured = try capturedArgs(svc)
        #expect(captured.args.contains("--cpus"))
        let idx = try #require(captured.args.firstIndex(of: "--cpus"))
        #expect(captured.args[idx + 1] == "1.0")
        #expect(!captured.args.contains("2.0"))
        #expect(!captured.output.contains("CPU reservation is ignored because a CPU limit is set"))
    }

    @Test("mem_limit + mem_reservation: --memory limit wins, ignored-reservation warning fires")
    func memLimitWithReservationWarnsIgnored() throws {
        let svc = Service(image: "alpine", mem_limit: "1g", mem_reservation: "256m")
        let captured = try capturedArgs(svc)
        #expect(captured.args.contains("--memory"))
        let idx = try #require(captured.args.firstIndex(of: "--memory"))
        #expect(captured.args[idx + 1] == "1g")
        #expect(!captured.args.contains("256m"))
        let memCount = captured.args.filter { $0 == "--memory" }.count
        #expect(memCount == 1)
        #expect(captured.output.contains("memory reservation is ignored because a memory limit is set"))
    }

    @Test("deploy.limits.memory + deploy.reservations.memory: --memory limit wins, only one flag emitted")
    func deployLimitMemoryWithReservationOnlyEmitsLimit() throws {
        let svc = try decodeService("""
          image: alpine
          deploy:
            resources:
              limits:
                memory: "1g"
              reservations:
                memory: "256m"
        """)
        let result = try args(svc)
        #expect(result.contains("--memory"))
        let memCount = result.filter { $0 == "--memory" }.count
        #expect(memCount == 1)
        let idx = try #require(result.firstIndex(of: "--memory"))
        #expect(result[idx + 1] == "1g")
        #expect(!result.contains("256m"))
    }

    @Test("cpus_top + deploy.reservations.cpus: --cpus limit wins, ignored-reservation warning fires")
    func cpusTopWithReservationWarnsIgnored() throws {
        let svc = try decodeService("""
          image: alpine
          cpus: 2.0
          deploy:
            resources:
              reservations:
                cpus: "0.5"
        """)
        let captured = try capturedArgs(svc)
        #expect(captured.args.contains("--cpus"))
        let idx = try #require(captured.args.firstIndex(of: "--cpus"))
        #expect(captured.args[idx + 1] == "2.0")
        #expect(!captured.args.contains("0.5"))
        let cpuCount = captured.args.filter { $0 == "--cpus" }.count
        #expect(cpuCount == 1)
        #expect(captured.output.contains("CPU reservation is ignored because a CPU limit is set"))
    }

    @Test("deploy.limits.cpus + deploy.reservations.cpus: --cpus limit wins, only one flag emitted")
    func deployLimitCpusWithReservationOnlyEmitsLimit() throws {
        let svc = try decodeService("""
          image: alpine
          deploy:
            resources:
              limits:
                cpus: "2.0"
              reservations:
                cpus: "0.5"
        """)
        let result = try args(svc)
        #expect(result.contains("--cpus"))
        let cpuCount = result.filter { $0 == "--cpus" }.count
        #expect(cpuCount == 1)
        let idx = try #require(result.firstIndex(of: "--cpus"))
        #expect(result[idx + 1] == "2.0")
        #expect(!result.contains("0.5"))
    }

    @Test("mem_swappiness warn-skips --memory-swappiness")
    func memSwappinessFlag() throws {
        let svc = Service(image: "alpine", mem_swappiness: 60)
        try expectWarnSkipped(svc, flag: "--memory-swappiness", field: "mem_swappiness")
    }

    @Test("memswap_limit warn-skips --memory-swap")
    func memswapLimitFlag() throws {
        let svc = Service(image: "alpine", memswap_limit: "1g")
        try expectWarnSkipped(svc, flag: "--memory-swap", field: "memswap_limit")
    }

    @Test("pids_limit warn-skips --pids-limit")
    func pidsLimitFlag() throws {
        let svc = Service(image: "alpine", pids_limit: 200)
        try expectWarnSkipped(svc, flag: "--pids-limit", field: "pids_limit")
    }

    @Test("shm_size emits --shm-size")
    func shmSizeFlag() throws {
        let svc = Service(image: "alpine", shm_size: "128m")
        let result = try args(svc)
        #expect(result.contains("--shm-size"))
        let idx = try #require(result.firstIndex(of: "--shm-size"))
        #expect(result[idx + 1] == "128m")
    }

    @Test("oom_kill_disable true warn-skips --oom-kill-disable flag")
    func oomKillDisableTrue() throws {
        let svc = Service(image: "alpine", oom_kill_disable: true)
        try expectWarnSkipped(svc, flag: "--oom-kill-disable", field: "oom_kill_disable")
    }

    @Test("oom_kill_disable false does not emit --oom-kill-disable flag")
    func oomKillDisableFalse() throws {
        let svc = Service(image: "alpine", oom_kill_disable: false)
        let result = try args(svc)
        #expect(!result.contains("--oom-kill-disable"))
    }

    @Test("oom_score_adj warn-skips --oom-score-adj")
    func oomScoreAdjFlag() throws {
        let svc = Service(image: "alpine", oom_score_adj: 300)
        try expectWarnSkipped(svc, flag: "--oom-score-adj", field: "oom_score_adj")
    }

    @Test("cpu_shares warn-skips --cpu-shares")
    func cpuSharesFlag() throws {
        let svc = Service(image: "alpine", cpu_shares: 512)
        try expectWarnSkipped(svc, flag: "--cpu-shares", field: "cpu_shares")
    }

    @Test("cpuset warn-skips --cpuset-cpus")
    func cpusetFlag() throws {
        let svc = Service(image: "alpine", cpuset: "0-3")
        try expectWarnSkipped(svc, flag: "--cpuset-cpus", field: "cpuset")
    }

    @Test("cpu_period warn-skips --cpu-period")
    func cpuPeriodFlag() throws {
        let svc = Service(image: "alpine", cpu_period: 100000)
        try expectWarnSkipped(svc, flag: "--cpu-period", field: "cpu_period")
    }

    @Test("cpu_quota warn-skips --cpu-quota")
    func cpuQuotaFlag() throws {
        let svc = Service(image: "alpine", cpu_quota: 50000)
        try expectWarnSkipped(svc, flag: "--cpu-quota", field: "cpu_quota")
    }

    @Test("cpu_rt_period warn-skips --cpu-rt-period")
    func cpuRtPeriodFlag() throws {
        let svc = Service(image: "alpine", cpu_rt_period: 1000000)
        try expectWarnSkipped(svc, flag: "--cpu-rt-period", field: "cpu_rt_period")
    }

    @Test("cpu_rt_runtime warn-skips --cpu-rt-runtime")
    func cpuRtRuntimeFlag() throws {
        let svc = Service(image: "alpine", cpu_rt_runtime: 950000)
        try expectWarnSkipped(svc, flag: "--cpu-rt-runtime", field: "cpu_rt_runtime")
    }

    @Test("cpu_count warn-skips --cpu-count")
    func cpuCountFlag() throws {
        let svc = Service(image: "alpine", cpu_count: 4)
        try expectWarnSkipped(svc, flag: "--cpu-count", field: "cpu_count")
    }

    @Test("cpu_percent warn-skips --cpu-percent")
    func cpuPercentFlag() throws {
        let svc = Service(image: "alpine", cpu_percent: 75)
        try expectWarnSkipped(svc, flag: "--cpu-percent", field: "cpu_percent")
    }

    // MARK: - Ulimits

    @Test("ulimits scalar form (soft == hard) emits NAME=VALUE")
    func ulimitsScalarForm() throws {
        let svc = Service(image: "alpine", ulimits: ["nofile": Ulimit(value: 65536)])
        let result = try args(svc)
        #expect(result.contains("--ulimit"))
        let idx = try #require(result.firstIndex(of: "--ulimit"))
        #expect(result[idx + 1] == "nofile=65536")
    }

    @Test("ulimits object form emits NAME=SOFT:HARD")
    func ulimitsObjectForm() throws {
        let svc = Service(image: "alpine", ulimits: ["nproc": Ulimit(soft: 1024, hard: 2048)])
        let result = try args(svc)
        #expect(result.contains("--ulimit"))
        let idx = try #require(result.firstIndex(of: "--ulimit"))
        #expect(result[idx + 1] == "nproc=1024:2048")
    }

    @Test("ulimits multiple entries each emit --ulimit flag")
    func ulimitsMultipleEntries() throws {
        let svc = Service(image: "alpine", ulimits: [
            "nofile": Ulimit(soft: 1024, hard: 65536),
            "nproc": Ulimit(value: 512)
        ])
        let result = try args(svc)
        // Count occurrences of --ulimit
        let ulimitCount = result.filter { $0 == "--ulimit" }.count
        #expect(ulimitCount == 2)
        #expect(result.contains("nofile=1024:65536"))
        #expect(result.contains("nproc=512"))
    }

    // MARK: - Override policy

    @Test("top-level cpus_top overrides deploy.resources.limits.cpus (only one --cpus)")
    func cpusTopOverridesDeployCpus() throws {
        let svc = try decodeService("""
          image: alpine
          cpus: 4.0
          deploy:
            resources:
              limits:
                cpus: "1.0"
        """)
        let result = try args(svc)
        // Exactly one --cpus flag
        let cpusFlagCount = result.filter { $0 == "--cpus" }.count
        #expect(cpusFlagCount == 1)
        // Top-level value wins
        let idx = try #require(result.firstIndex(of: "--cpus"))
        #expect(result[idx + 1] == "4.0")
    }

    @Test("top-level mem_limit overrides deploy.resources.limits.memory (only one --memory)")
    func memLimitOverridesDeployMemory() throws {
        let svc = try decodeService("""
          image: alpine
          mem_limit: "1g"
          deploy:
            resources:
              limits:
                memory: "256m"
        """)
        let result = try args(svc)
        let memFlagCount = result.filter { $0 == "--memory" }.count
        #expect(memFlagCount == 1)
        let idx = try #require(result.firstIndex(of: "--memory"))
        #expect(result[idx + 1] == "1g")
    }

    @Test("deploy.resources.limits.cpus used when cpus_top is absent")
    func deployFallbackCpus() throws {
        let svc = try decodeService("""
          image: alpine
          deploy:
            resources:
              limits:
                cpus: "2.0"
        """)
        let result = try args(svc)
        #expect(result.contains("--cpus"))
        let idx = try #require(result.firstIndex(of: "--cpus"))
        #expect(result[idx + 1] == "2.0")
    }

    @Test("deploy.resources.limits.memory used when mem_limit is absent")
    func deployFallbackMemory() throws {
        let svc = try decodeService("""
          image: alpine
          deploy:
            resources:
              limits:
                memory: "512m"
        """)
        let result = try args(svc)
        #expect(result.contains("--memory"))
        let idx = try #require(result.firstIndex(of: "--memory"))
        #expect(result[idx + 1] == "512m")
    }

    // MARK: - Combination test

    @Test("combo: cpus_top + ulimits emit while pids_limit warn-skips")
    func comboFlags() throws {
        let svc = Service(
            image: "alpine",
            cpus_top: 1.0,
            pids_limit: 100,
            ulimits: ["nofile": Ulimit(soft: 1024, hard: 4096)]
        )
        let result = try args(svc)
        // --cpus
        #expect(result.contains("--cpus"))
        let cpusIdx = try #require(result.firstIndex(of: "--cpus"))
        #expect(result[cpusIdx + 1] == "1.0")
        // --pids-limit
        #expect(!result.contains("--pids-limit"))
        // --ulimit
        #expect(result.contains("--ulimit"))
        #expect(result.contains("nofile=1024:4096"))
    }

    // MARK: - No flags when no resource fields set

    @Test("empty service emits no resource flags")
    func emptyServiceNoFlags() throws {
        let svc = Service(image: "alpine")
        let result = try args(svc)
        #expect(result.isEmpty)
    }
}
