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

@Suite("Resource Args Tests")
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

    @Test("mem_reservation emits --memory-reservation")
    func memReservationFlag() throws {
        let svc = Service(image: "alpine", mem_reservation: "256m")
        let result = try args(svc)
        #expect(result.contains("--memory-reservation"))
        let idx = try #require(result.firstIndex(of: "--memory-reservation"))
        #expect(result[idx + 1] == "256m")
    }

    @Test("mem_swappiness emits --memory-swappiness")
    func memSwappinessFlag() throws {
        let svc = Service(image: "alpine", mem_swappiness: 60)
        let result = try args(svc)
        #expect(result.contains("--memory-swappiness"))
        let idx = try #require(result.firstIndex(of: "--memory-swappiness"))
        #expect(result[idx + 1] == "60")
    }

    @Test("memswap_limit emits --memory-swap")
    func memswapLimitFlag() throws {
        let svc = Service(image: "alpine", memswap_limit: "1g")
        let result = try args(svc)
        #expect(result.contains("--memory-swap"))
        let idx = try #require(result.firstIndex(of: "--memory-swap"))
        #expect(result[idx + 1] == "1g")
    }

    @Test("pids_limit emits --pids-limit")
    func pidsLimitFlag() throws {
        let svc = Service(image: "alpine", pids_limit: 200)
        let result = try args(svc)
        #expect(result.contains("--pids-limit"))
        let idx = try #require(result.firstIndex(of: "--pids-limit"))
        #expect(result[idx + 1] == "200")
    }

    @Test("shm_size emits --shm-size")
    func shmSizeFlag() throws {
        let svc = Service(image: "alpine", shm_size: "128m")
        let result = try args(svc)
        #expect(result.contains("--shm-size"))
        let idx = try #require(result.firstIndex(of: "--shm-size"))
        #expect(result[idx + 1] == "128m")
    }

    @Test("oom_kill_disable true emits --oom-kill-disable flag")
    func oomKillDisableTrue() throws {
        let svc = Service(image: "alpine", oom_kill_disable: true)
        let result = try args(svc)
        #expect(result.contains("--oom-kill-disable"))
    }

    @Test("oom_kill_disable false does not emit --oom-kill-disable flag")
    func oomKillDisableFalse() throws {
        let svc = Service(image: "alpine", oom_kill_disable: false)
        let result = try args(svc)
        #expect(!result.contains("--oom-kill-disable"))
    }

    @Test("oom_score_adj emits --oom-score-adj")
    func oomScoreAdjFlag() throws {
        let svc = Service(image: "alpine", oom_score_adj: 300)
        let result = try args(svc)
        #expect(result.contains("--oom-score-adj"))
        let idx = try #require(result.firstIndex(of: "--oom-score-adj"))
        #expect(result[idx + 1] == "300")
    }

    @Test("cpu_shares emits --cpu-shares")
    func cpuSharesFlag() throws {
        let svc = Service(image: "alpine", cpu_shares: 512)
        let result = try args(svc)
        #expect(result.contains("--cpu-shares"))
        let idx = try #require(result.firstIndex(of: "--cpu-shares"))
        #expect(result[idx + 1] == "512")
    }

    @Test("cpuset emits --cpuset-cpus")
    func cpusetFlag() throws {
        let svc = Service(image: "alpine", cpuset: "0-3")
        let result = try args(svc)
        #expect(result.contains("--cpuset-cpus"))
        let idx = try #require(result.firstIndex(of: "--cpuset-cpus"))
        #expect(result[idx + 1] == "0-3")
    }

    @Test("cpu_period emits --cpu-period")
    func cpuPeriodFlag() throws {
        let svc = Service(image: "alpine", cpu_period: 100000)
        let result = try args(svc)
        #expect(result.contains("--cpu-period"))
        let idx = try #require(result.firstIndex(of: "--cpu-period"))
        #expect(result[idx + 1] == "100000")
    }

    @Test("cpu_quota emits --cpu-quota")
    func cpuQuotaFlag() throws {
        let svc = Service(image: "alpine", cpu_quota: 50000)
        let result = try args(svc)
        #expect(result.contains("--cpu-quota"))
        let idx = try #require(result.firstIndex(of: "--cpu-quota"))
        #expect(result[idx + 1] == "50000")
    }

    @Test("cpu_rt_period emits --cpu-rt-period")
    func cpuRtPeriodFlag() throws {
        let svc = Service(image: "alpine", cpu_rt_period: 1000000)
        let result = try args(svc)
        #expect(result.contains("--cpu-rt-period"))
        let idx = try #require(result.firstIndex(of: "--cpu-rt-period"))
        #expect(result[idx + 1] == "1000000")
    }

    @Test("cpu_rt_runtime emits --cpu-rt-runtime")
    func cpuRtRuntimeFlag() throws {
        let svc = Service(image: "alpine", cpu_rt_runtime: 950000)
        let result = try args(svc)
        #expect(result.contains("--cpu-rt-runtime"))
        let idx = try #require(result.firstIndex(of: "--cpu-rt-runtime"))
        #expect(result[idx + 1] == "950000")
    }

    @Test("cpu_count emits --cpu-count")
    func cpuCountFlag() throws {
        let svc = Service(image: "alpine", cpu_count: 4)
        let result = try args(svc)
        #expect(result.contains("--cpu-count"))
        let idx = try #require(result.firstIndex(of: "--cpu-count"))
        #expect(result[idx + 1] == "4")
    }

    @Test("cpu_percent emits --cpu-percent")
    func cpuPercentFlag() throws {
        let svc = Service(image: "alpine", cpu_percent: 75)
        let result = try args(svc)
        #expect(result.contains("--cpu-percent"))
        let idx = try #require(result.firstIndex(of: "--cpu-percent"))
        #expect(result[idx + 1] == "75")
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

    @Test("combo: cpus_top + ulimits + pids_limit all emit correctly")
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
        #expect(result.contains("--pids-limit"))
        let pidsIdx = try #require(result.firstIndex(of: "--pids-limit"))
        #expect(result[pidsIdx + 1] == "100")
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
