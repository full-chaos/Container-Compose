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

/// Tests for the new Phase 1.2 optional Service properties (parse-only).
@Suite("Service Properties Parsing Tests")
struct ServicePropertiesParsingTests {

    // MARK: - Helpers

    private func decodeService(_ yaml: String) throws -> Service {
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let service = try #require(compose.services["svc"] as? Service)
        return service
    }

    private func wrap(_ serviceYaml: String) -> String {
        """
        services:
          svc:
            image: alpine:latest
        \(serviceYaml.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }.joined(separator: "\n"))
        """
    }

    // MARK: - Security & Capabilities

    @Test("Parse cap_add and cap_drop")
    func parseCapabilities() throws {
        let yaml = wrap("""
        cap_add:
          - NET_ADMIN
          - SYS_PTRACE
        cap_drop:
          - ALL
        """)
        let svc = try decodeService(yaml)
        #expect(svc.cap_add == ["NET_ADMIN", "SYS_PTRACE"])
        #expect(svc.cap_drop == ["ALL"])
    }

    @Test("Parse security_opt")
    func parseSecurityOpt() throws {
        let yaml = wrap("""
        security_opt:
          - seccomp:unconfined
          - no-new-privileges:true
        """)
        let svc = try decodeService(yaml)
        #expect(svc.security_opt?.count == 2)
        #expect(svc.security_opt?.contains("seccomp:unconfined") == true)
    }

    // MARK: - DNS

    @Test("Parse dns as list")
    func parseDnsList() throws {
        let yaml = wrap("""
        dns:
          - 8.8.8.8
          - 8.8.4.4
        """)
        let svc = try decodeService(yaml)
        #expect(svc.dns == ["8.8.8.8", "8.8.4.4"])
    }

    @Test("Parse dns as single string")
    func parseDnsString() throws {
        let yaml = wrap("dns: 1.1.1.1")
        let svc = try decodeService(yaml)
        #expect(svc.dns == ["1.1.1.1"])
    }

    @Test("Parse dns_opt")
    func parseDnsOpt() throws {
        let yaml = wrap("""
        dns_opt:
          - use-vc
          - no-tld-query
        """)
        let svc = try decodeService(yaml)
        #expect(svc.dns_opt == ["use-vc", "no-tld-query"])
    }

    @Test("Parse dns_search as list")
    func parseDnsSearchList() throws {
        let yaml = wrap("""
        dns_search:
          - example.com
          - internal.local
        """)
        let svc = try decodeService(yaml)
        #expect(svc.dns_search == ["example.com", "internal.local"])
    }

    @Test("Parse dns_search as single string")
    func parseDnsSearchString() throws {
        let yaml = wrap("dns_search: example.com")
        let svc = try decodeService(yaml)
        #expect(svc.dns_search == ["example.com"])
    }

    // MARK: - Network Settings

    @Test("Parse extra_hosts as list")
    func parseExtraHostsList() throws {
        let yaml = wrap("""
        extra_hosts:
          - "myhost:192.168.1.100"
          - "otherhost:10.0.0.1"
        """)
        let svc = try decodeService(yaml)
        #expect(svc.extra_hosts?.count == 2)
        #expect(svc.extra_hosts?.contains("myhost:192.168.1.100") == true)
    }

    @Test("Parse extra_hosts as map")
    func parseExtraHostsMap() throws {
        let yaml = wrap("""
        extra_hosts:
          myhost: "192.168.1.100"
        """)
        let svc = try decodeService(yaml)
        let hosts = try #require(svc.extra_hosts)
        #expect(hosts.count == 1)
        // Map form serializes to "key:value"
        #expect(hosts.first?.contains("myhost") == true)
        #expect(hosts.first?.contains("192.168.1.100") == true)
    }

    @Test("Parse domainname")
    func parseDomainname() throws {
        let yaml = wrap("domainname: example.com")
        let svc = try decodeService(yaml)
        #expect(svc.domainname == "example.com")
    }

    @Test("Parse expose ports")
    func parseExpose() throws {
        let yaml = wrap("""
        expose:
          - "3000"
          - "8080"
        """)
        let svc = try decodeService(yaml)
        #expect(svc.expose == ["3000", "8080"])
    }

    @Test("Parse mac_address")
    func parseMacAddress() throws {
        let yaml = wrap("mac_address: \"02:42:ac:11:00:02\"")
        let svc = try decodeService(yaml)
        #expect(svc.mac_address == "02:42:ac:11:00:02")
    }

    @Test("Parse network_mode")
    func parseNetworkMode() throws {
        let yaml = wrap("network_mode: host")
        let svc = try decodeService(yaml)
        #expect(svc.network_mode == "host")
    }

    // MARK: - IPC / PID / UTS / User Namespaces

    @Test("Parse ipc, pid, uts, userns_mode")
    func parseNamespaceOptions() throws {
        let yaml = wrap("""
        ipc: shareable
        pid: host
        uts: host
        userns_mode: host
        """)
        let svc = try decodeService(yaml)
        #expect(svc.ipc == "shareable")
        #expect(svc.pid == "host")
        #expect(svc.uts == "host")
        #expect(svc.userns_mode == "host")
    }

    // MARK: - User & Groups

    @Test("Parse group_add")
    func parseGroupAdd() throws {
        let yaml = wrap("""
        group_add:
          - dialout
          - "1000"
        """)
        let svc = try decodeService(yaml)
        #expect(svc.group_add?.contains("dialout") == true)
    }

    // MARK: - Runtime Behaviour

    @Test("Parse init flag (CodingKey 'init')")
    func parseInitFlag() throws {
        let yaml = wrap("init: true")
        let svc = try decodeService(yaml)
        #expect(svc.init_ == true)
    }

    @Test("Parse runtime")
    func parseRuntime() throws {
        let yaml = wrap("runtime: nvidia")
        let svc = try decodeService(yaml)
        #expect(svc.runtime == "nvidia")
    }

    @Test("Parse scale")
    func parseScale() throws {
        let yaml = wrap("scale: 3")
        let svc = try decodeService(yaml)
        #expect(svc.scale == 3)
    }

    @Test("Parse pull_policy")
    func parsePullPolicy() throws {
        let yaml = wrap("pull_policy: always")
        let svc = try decodeService(yaml)
        #expect(svc.pull_policy == "always")
    }

    @Test("Parse profiles")
    func parseProfiles() throws {
        let yaml = wrap("""
        profiles:
          - dev
          - debug
        """)
        let svc = try decodeService(yaml)
        #expect(svc.profiles == ["dev", "debug"])
    }

    // MARK: - Labels

    @Test("Parse labels as map")
    func parseLabels() throws {
        let yaml = wrap("""
        labels:
          com.example.app: myapp
          version: "1.0"
        """)
        let svc = try decodeService(yaml)
        #expect(svc.labels?["com.example.app"] == "myapp")
        #expect(svc.labels?["version"] == "1.0")
    }

    // MARK: - Stop Behaviour

    @Test("Parse stop_signal and stop_grace_period")
    func parseStopOptions() throws {
        let yaml = wrap("""
        stop_signal: SIGTERM
        stop_grace_period: 30s
        """)
        let svc = try decodeService(yaml)
        #expect(svc.stop_signal == "SIGTERM")
        #expect(svc.stop_grace_period == "30s")
    }

    // MARK: - Filesystem

    @Test("Parse tmpfs")
    func parseTmpfs() throws {
        let yaml = wrap("""
        tmpfs:
          - /tmp
          - /run
        """)
        let svc = try decodeService(yaml)
        #expect(svc.tmpfs?.contains("/tmp") == true)
    }

    @Test("Parse sysctls")
    func parseSysctls() throws {
        let yaml = wrap("""
        sysctls:
          net.core.somaxconn: "1024"
          net.ipv4.tcp_syncookies: "0"
        """)
        let svc = try decodeService(yaml)
        #expect(svc.sysctls?["net.core.somaxconn"] == "1024")
    }

    @Test("Parse volumes_from")
    func parseVolumesFrom() throws {
        let yaml = wrap("""
        volumes_from:
          - service1
          - service2:ro
        """)
        let svc = try decodeService(yaml)
        #expect(svc.volumes_from?.contains("service1") == true)
    }

    // MARK: - CPU Limits

    @Test("Parse cpus_top (CodingKey 'cpus')")
    func parseCpusTop() throws {
        let yaml = wrap("cpus: 1.5")
        let svc = try decodeService(yaml)
        #expect(svc.cpus_top == 1.5)
    }

    @Test("Parse cpu_shares and cpu_quota")
    func parseCpuSharesAndQuota() throws {
        let yaml = wrap("""
        cpu_shares: 512
        cpu_quota: 50000
        """)
        let svc = try decodeService(yaml)
        #expect(svc.cpu_shares == 512)
        #expect(svc.cpu_quota == 50000)
    }

    @Test("Parse cpu_count, cpu_percent, cpu_period, cpuset")
    func parseCpuCountPercent() throws {
        let yaml = wrap("""
        cpu_count: 2
        cpu_percent: 50
        cpu_period: 100000
        cpuset: "0-1"
        """)
        let svc = try decodeService(yaml)
        #expect(svc.cpu_count == 2)
        #expect(svc.cpu_percent == 50)
        #expect(svc.cpu_period == 100000)
        #expect(svc.cpuset == "0-1")
    }

    @Test("Parse cpu_rt_period and cpu_rt_runtime")
    func parseCpuRealtime() throws {
        let yaml = wrap("""
        cpu_rt_period: 1000000
        cpu_rt_runtime: 950000
        """)
        let svc = try decodeService(yaml)
        #expect(svc.cpu_rt_period == 1000000)
        #expect(svc.cpu_rt_runtime == 950000)
    }

    // MARK: - Memory Limits

    @Test("Parse mem_limit and mem_reservation")
    func parseMemLimits() throws {
        let yaml = wrap("""
        mem_limit: 512m
        mem_reservation: 256m
        """)
        let svc = try decodeService(yaml)
        #expect(svc.mem_limit == "512m")
        #expect(svc.mem_reservation == "256m")
    }

    @Test("Parse mem_swappiness, memswap_limit, shm_size")
    func parseMemSwap() throws {
        let yaml = wrap("""
        mem_swappiness: 60
        memswap_limit: 1g
        shm_size: 128m
        """)
        let svc = try decodeService(yaml)
        #expect(svc.mem_swappiness == 60)
        #expect(svc.memswap_limit == "1g")
        #expect(svc.shm_size == "128m")
    }

    @Test("Parse oom_kill_disable, oom_score_adj, pids_limit")
    func parseOomAndPids() throws {
        let yaml = wrap("""
        oom_kill_disable: true
        oom_score_adj: 500
        pids_limit: 100
        """)
        let svc = try decodeService(yaml)
        #expect(svc.oom_kill_disable == true)
        #expect(svc.oom_score_adj == 500)
        #expect(svc.pids_limit == 100)
    }

    // MARK: - Ulimits

    @Test("Parse ulimits with scalar Int form")
    func parseUlimitsScalar() throws {
        let yaml = wrap("""
        ulimits:
          nofile: 1024
        """)
        let svc = try decodeService(yaml)
        let nofile = try #require(svc.ulimits?["nofile"])
        #expect(nofile.soft == 1024)
        #expect(nofile.hard == 1024)
    }

    @Test("Parse ulimits with object soft/hard form")
    func parseUlimitsObject() throws {
        let yaml = wrap("""
        ulimits:
          nofile:
            soft: 1024
            hard: 65536
        """)
        let svc = try decodeService(yaml)
        let nofile = try #require(svc.ulimits?["nofile"])
        #expect(nofile.soft == 1024)
        #expect(nofile.hard == 65536)
    }

    @Test("Parse ulimits multiple entries")
    func parseUlimitsMultiple() throws {
        let yaml = wrap("""
        ulimits:
          nproc: 65535
          nofile:
            soft: 20000
            hard: 40000
        """)
        let svc = try decodeService(yaml)
        #expect(svc.ulimits?.count == 2)
        #expect(svc.ulimits?["nproc"]?.soft == 65535)
        #expect(svc.ulimits?["nproc"]?.hard == 65535)
        #expect(svc.ulimits?["nofile"]?.hard == 40000)
    }

    // MARK: - Logging

    @Test("Parse logging with driver and options")
    func parseLogging() throws {
        let yaml = wrap("""
        logging:
          driver: json-file
          options:
            max-size: 10m
            max-file: "3"
        """)
        let svc = try decodeService(yaml)
        let log = try #require(svc.logging)
        #expect(log.driver == "json-file")
        #expect(log.options?["max-size"] == "10m")
        #expect(log.options?["max-file"] == "3")
    }

    @Test("Parse logging driver only")
    func parseLoggingDriverOnly() throws {
        let yaml = wrap("""
        logging:
          driver: none
        """)
        let svc = try decodeService(yaml)
        #expect(svc.logging?.driver == "none")
        #expect(svc.logging?.options == nil)
    }

    // MARK: - Devices

    @Test("Parse devices and device_cgroup_rules")
    func parseDevices() throws {
        let yaml = wrap("""
        devices:
          - /dev/ttyUSB0:/dev/ttyUSB0
        device_cgroup_rules:
          - "c 1:3 mr"
        """)
        let svc = try decodeService(yaml)
        #expect(svc.devices?.contains("/dev/ttyUSB0:/dev/ttyUSB0") == true)
        #expect(svc.device_cgroup_rules?.contains("c 1:3 mr") == true)
    }

    @Test("Parse storage_opt")
    func parseStorageOpt() throws {
        let yaml = wrap("""
        storage_opt:
          size: "1G"
        """)
        let svc = try decodeService(yaml)
        #expect(svc.storage_opt?["size"] == "1G")
    }

    // MARK: - Absence tests (optional fields absent when not set)

    @Test("All new optional fields are nil when not specified")
    func newFieldsAreNilWhenAbsent() throws {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        let svc = try decodeService(yaml)
        #expect(svc.cap_add == nil)
        #expect(svc.cap_drop == nil)
        #expect(svc.security_opt == nil)
        #expect(svc.dns == nil)
        #expect(svc.dns_opt == nil)
        #expect(svc.dns_search == nil)
        #expect(svc.extra_hosts == nil)
        #expect(svc.domainname == nil)
        #expect(svc.expose == nil)
        #expect(svc.mac_address == nil)
        #expect(svc.network_mode == nil)
        #expect(svc.ipc == nil)
        #expect(svc.pid == nil)
        #expect(svc.uts == nil)
        #expect(svc.userns_mode == nil)
        #expect(svc.group_add == nil)
        #expect(svc.init_ == nil)
        #expect(svc.runtime == nil)
        #expect(svc.scale == nil)
        #expect(svc.pull_policy == nil)
        #expect(svc.profiles == nil)
        #expect(svc.labels == nil)
        #expect(svc.stop_signal == nil)
        #expect(svc.stop_grace_period == nil)
        #expect(svc.tmpfs == nil)
        #expect(svc.sysctls == nil)
        #expect(svc.volumes_from == nil)
        #expect(svc.cpus_top == nil)
        #expect(svc.cpu_count == nil)
        #expect(svc.cpu_percent == nil)
        #expect(svc.cpu_shares == nil)
        #expect(svc.cpuset == nil)
        #expect(svc.cpu_period == nil)
        #expect(svc.cpu_quota == nil)
        #expect(svc.cpu_rt_period == nil)
        #expect(svc.cpu_rt_runtime == nil)
        #expect(svc.mem_limit == nil)
        #expect(svc.mem_reservation == nil)
        #expect(svc.mem_swappiness == nil)
        #expect(svc.memswap_limit == nil)
        #expect(svc.oom_kill_disable == nil)
        #expect(svc.oom_score_adj == nil)
        #expect(svc.pids_limit == nil)
        #expect(svc.shm_size == nil)
        #expect(svc.ulimits == nil)
        #expect(svc.logging == nil)
        #expect(svc.devices == nil)
        #expect(svc.device_cgroup_rules == nil)
        #expect(svc.storage_opt == nil)
    }
}
