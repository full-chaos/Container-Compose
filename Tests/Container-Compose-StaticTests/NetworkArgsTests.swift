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

/// Tests for Phase 2C — NetworkingArgs.build: dns, dns_opt, dns_search,
/// extra_hosts, domainname, expose, mac_address, network_mode, ipc, pid, uts.
/// This suite is distinct from NetworkConfigurationTests (which tests parsing).
@Suite("Network Args Tests")
struct NetworkArgsTests {

    // MARK: - Helpers

    /// Minimal DockerCompose wrapper used to satisfy ArgsContext.
    private let emptyCompose: DockerCompose = {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        return try! YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }()

    /// Build an ArgsContext from a Service, with optional environment overrides.
    private func ctx(
        _ service: Service,
        env: [String: String] = [:]
    ) -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "test",
            containerName: "test-svc-1",
            detach: true,
            environmentVariables: env,
            dockerCompose: emptyCompose,
            composeFilename: nil
        )
    }

    /// Convenience: build args from a service.
    private func args(for service: Service, env: [String: String] = [:]) -> [String] {
        ComposeUp.NetworkingArgs.build(ctx(service, env: env))
    }

    // MARK: - DNS

    @Test("dns list emits --dns per item")
    func dnsListEmitsPerItem() {
        let svc = Service(image: "alpine", dns: ["8.8.8.8", "8.8.4.4"])
        let result = args(for: svc)
        #expect(result.contains("--dns"))
        // Pair check
        let pairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--dns" }
            .map { result[$0 + 1] }
        #expect(pairs.contains("8.8.8.8"))
        #expect(pairs.contains("8.8.4.4"))
        #expect(pairs.count == 2)
    }

    @Test("dns_opt list emits --dns-option per item")
    func dnsOptListEmitsPerItem() {
        let svc = Service(image: "alpine", dns_opt: ["ndots:5", "timeout:2"])
        let result = args(for: svc)
        let pairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--dns-option" }
            .map { result[$0 + 1] }
        #expect(pairs.contains("ndots:5"))
        #expect(pairs.contains("timeout:2"))
        #expect(pairs.count == 2)
    }

    @Test("dns_search list emits --dns-search per item")
    func dnsSearchListEmitsPerItem() {
        let svc = Service(image: "alpine", dns_search: ["example.com", "corp.internal"])
        let result = args(for: svc)
        let pairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--dns-search" }
            .map { result[$0 + 1] }
        #expect(pairs.contains("example.com"))
        #expect(pairs.contains("corp.internal"))
        #expect(pairs.count == 2)
    }

    // MARK: - extra_hosts

    @Test("extra_hosts list form emits --add-host per item")
    func extraHostsListEmitsAddHost() {
        let svc = Service(image: "alpine", extra_hosts: ["db:10.0.0.1", "cache:10.0.0.2"])
        let result = args(for: svc)
        let pairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--add-host" }
            .map { result[$0 + 1] }
        #expect(pairs.contains("db:10.0.0.1"))
        #expect(pairs.contains("cache:10.0.0.2"))
        #expect(pairs.count == 2)
    }

    // MARK: - domainname

    @Test("domainname emits --domainname NAME")
    func domainnameEmitsFlag() {
        let svc = Service(image: "alpine", domainname: "example.com")
        let result = args(for: svc)
        let idx = result.firstIndex(of: "--domainname")
        #expect(idx != nil)
        if let idx = idx {
            #expect(result[idx + 1] == "example.com")
        }
    }

    // MARK: - expose

    @Test("expose list emits --expose per item")
    func exposeListEmitsPerItem() {
        let svc = Service(image: "alpine", expose: ["8080/tcp", "9090/udp"])
        let result = args(for: svc)
        let pairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--expose" }
            .map { result[$0 + 1] }
        #expect(pairs.contains("8080/tcp"))
        #expect(pairs.contains("9090/udp"))
        #expect(pairs.count == 2)
    }

    // MARK: - mac_address

    @Test("mac_address emits --mac-address MAC")
    func macAddressEmitsFlag() {
        let svc = Service(image: "alpine", mac_address: "02:42:ac:11:00:02")
        let result = args(for: svc)
        let idx = result.firstIndex(of: "--mac-address")
        #expect(idx != nil)
        if let idx = idx {
            #expect(result[idx + 1] == "02:42:ac:11:00:02")
        }
    }

    // MARK: - network_mode

    @Test("network_mode 'host' emits --network host")
    func networkModeHostEmitsFlag() {
        let svc = Service(image: "alpine", network_mode: "host")
        let result = args(for: svc)
        // --network appears from network_mode (not from networks list which is nil here)
        let networkPairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--network" }
            .map { result[$0 + 1] }
        #expect(networkPairs.contains("host"))
    }

    @Test("network_mode 'none' emits --network none")
    func networkModeNoneEmitsFlag() {
        let svc = Service(image: "alpine", network_mode: "none")
        let result = args(for: svc)
        let networkPairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--network" }
            .map { result[$0 + 1] }
        #expect(networkPairs.contains("none"))
    }

    // MARK: - ipc / pid / uts

    @Test("ipc emits --ipc MODE")
    func ipcEmitsFlag() {
        let svc = Service(image: "alpine", ipc: "host")
        let result = args(for: svc)
        let idx = result.firstIndex(of: "--ipc")
        #expect(idx != nil)
        if let idx = idx { #expect(result[idx + 1] == "host") }
    }

    @Test("pid emits --pid MODE")
    func pidEmitsFlag() {
        let svc = Service(image: "alpine", pid: "host")
        let result = args(for: svc)
        let idx = result.firstIndex(of: "--pid")
        #expect(idx != nil)
        if let idx = idx { #expect(result[idx + 1] == "host") }
    }

    @Test("uts emits --uts MODE")
    func utsEmitsFlag() {
        let svc = Service(image: "alpine", uts: "host")
        let result = args(for: svc)
        let idx = result.firstIndex(of: "--uts")
        #expect(idx != nil)
        if let idx = idx { #expect(result[idx + 1] == "host") }
    }

    // MARK: - Variable substitution

    @Test("${VAR} substitution works in dns addresses")
    func varSubstitutionInDns() {
        let svc = Service(image: "alpine", dns: ["${DNS_ADDR}"])
        let result = args(for: svc, env: ["DNS_ADDR": "1.1.1.1"])
        let pairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--dns" }
            .map { result[$0 + 1] }
        #expect(pairs == ["1.1.1.1"])
    }

    @Test("${VAR} substitution works in domainname")
    func varSubstitutionInDomainname() {
        let svc = Service(image: "alpine", domainname: "${DOMAIN}")
        let result = args(for: svc, env: ["DOMAIN": "my.corp"])
        let idx = result.firstIndex(of: "--domainname")
        #expect(idx != nil)
        if let idx = idx { #expect(result[idx + 1] == "my.corp") }
    }

    // MARK: - Combination test

    @Test("Combo: dns + dns_search + extra_hosts all emit correct flags")
    func comboDnsDnsSearchExtraHosts() {
        let svc = Service(
            image: "alpine",
            dns: ["8.8.8.8"],
            dns_search: ["example.com"],
            extra_hosts: ["host1:192.168.1.1"]
        )
        let result = args(for: svc)

        let dnsVals = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--dns" }.map { result[$0 + 1] }
        let searchVals = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--dns-search" }.map { result[$0 + 1] }
        let hostVals = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--add-host" }.map { result[$0 + 1] }

        #expect(dnsVals == ["8.8.8.8"])
        #expect(searchVals == ["example.com"])
        #expect(hostVals == ["host1:192.168.1.1"])
    }

    // MARK: - Regression: existing flags still emit

    @Test("Regression: ports still emit -p flags")
    func regressionPortsStillEmit() {
        let svc = Service(image: "alpine", ports: ["8080:80"])
        let result = args(for: svc)
        #expect(result.contains("-p"))
        let portPairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "-p" }.map { result[$0 + 1] }
        #expect(!portPairs.isEmpty)
    }

    @Test("Regression: hostname still emits --hostname")
    func regressionHostnameStillEmits() {
        let svc = Service(image: "alpine", hostname: "myhostname")
        let result = args(for: svc)
        let idx = result.firstIndex(of: "--hostname")
        #expect(idx != nil)
        if let idx = idx { #expect(result[idx + 1] == "myhostname") }
    }

    @Test("Regression: nil fields produce no args")
    func regressionNilFieldsProduceNoArgs() {
        let svc = Service(image: "alpine")
        let result = args(for: svc)
        // A bare service with no networking fields should produce an empty argv
        #expect(result.isEmpty)
    }
}
