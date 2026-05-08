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

/// Tests for Phase 2C — NetworkingArgs.build: dns, dns_opt, dns_search,
/// extra_hosts, domainname, expose, mac_address, network_mode, ipc, pid, uts.
/// This suite is distinct from NetworkConfigurationTests (which tests parsing).
@Suite("Network Args Tests", .serialized)
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

    private func captureStandardOutput<T>(_ body: () throws -> T) throws -> (T, String) {
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        guard original >= 0 else { throw CaptureError.dupFailed }

        let pipe = Pipe()
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            close(original)
            throw CaptureError.dupFailed
        }

        do {
            let value = try body()
            fflush(stdout)
            restoreStandardOutput(original: original, pipe: pipe)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (value, String(data: data, encoding: .utf8) ?? "")
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

    @Test("extra_hosts list form emits no unsupported --add-host flags")
    func extraHostsListEmitsNoUnsupportedAddHost() {
        let svc = Service(image: "alpine", extra_hosts: ["db:10.0.0.1", "cache:10.0.0.2"])
        let result = args(for: svc)
        #expect(!result.contains("--add-host"))
    }

    // MARK: - domainname

    @Test("domainname warns and emits no unsupported --domainname flag")
    func domainnameWarnsAndEmitsNoUnsupportedFlag() throws {
        let svc = Service(image: "alpine", domainname: "example.com")
        let (result, output) = try captureStandardOutput { args(for: svc) }
        #expect(!result.contains("--domainname"))
        #expect(!result.contains("example.com"))
        #expect(output.contains("Note: 'domainname' is parsed but not supported by Apple container; ignored."))
    }

    // MARK: - expose

    @Test("expose list warns and emits no unsupported --expose flag")
    func exposeListWarnsAndEmitsNoUnsupportedFlag() throws {
        let svc = Service(image: "alpine", expose: ["8080/tcp", "9090/udp"])
        let (result, output) = try captureStandardOutput { args(for: svc) }
        #expect(!result.contains("--expose"))
        #expect(!result.contains("8080/tcp"))
        #expect(!result.contains("9090/udp"))
        #expect(output.contains("Note: 'expose' is parsed but not supported by Apple container; ignored."))
    }

    // MARK: - mac_address

    @Test("mac_address warns and emits no unsupported --mac-address flag")
    func macAddressWarnsAndEmitsNoUnsupportedFlag() throws {
        let svc = Service(image: "alpine", mac_address: "02:42:ac:11:00:02")
        let (result, output) = try captureStandardOutput { args(for: svc) }
        #expect(!result.contains("--mac-address"))
        #expect(output.contains("Note: 'mac_address' is parsed but not supported by Apple container; ignored."))
    }

    @Test("networks ipv4_address warns and emits no unsupported --ip flag")
    func serviceNetworkIPv4WarnsAndEmitsNoUnsupportedFlag() throws {
        let config = ServiceNetworkConfig(ipv4_address: "10.0.0.5")
        let serviceNetworks = ServiceNetworks(entries: [("mynet", config)])
        let svc = Service(image: "alpine", networks: serviceNetworks)
        let (result, output) = try captureStandardOutput { args(for: svc) }

        #expect(result.contains("--network"))
        #expect(!result.contains("--ip"))
        #expect(output.contains("Note: 'networks.<name>.ipv4_address' is parsed but not supported by Apple container; ignored."))
    }

    @Test("networks ipv6_address warns and emits no unsupported --ip6 flag")
    func serviceNetworkIPv6WarnsAndEmitsNoUnsupportedFlag() throws {
        let config = ServiceNetworkConfig(ipv6_address: "2001:db8::5")
        let serviceNetworks = ServiceNetworks(entries: [("mynet", config)])
        let svc = Service(image: "alpine", networks: serviceNetworks)
        let (result, output) = try captureStandardOutput { args(for: svc) }

        #expect(result.contains("--network"))
        #expect(!result.contains("--ip6"))
        #expect(output.contains("Note: 'networks.<name>.ipv6_address' is parsed but not supported by Apple container; ignored."))
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

    @Test("ipc warns and emits no unsupported --ipc flag")
    func ipcWarnsAndEmitsNoUnsupportedFlag() throws {
        let svc = Service(image: "alpine", ipc: "host")
        let (result, output) = try captureStandardOutput { args(for: svc) }
        #expect(!result.contains("--ipc"))
        #expect(output.contains("Note: 'ipc' is parsed but not supported by Apple container; ignored."))
    }

    @Test("pid warns and emits no unsupported --pid flag")
    func pidWarnsAndEmitsNoUnsupportedFlag() throws {
        let svc = Service(image: "alpine", pid: "host")
        let (result, output) = try captureStandardOutput { args(for: svc) }
        #expect(!result.contains("--pid"))
        #expect(output.contains("Note: 'pid' is parsed but not supported by Apple container; ignored."))
    }

    @Test("uts warns and emits no unsupported --uts flag")
    func utsWarnsAndEmitsNoUnsupportedFlag() throws {
        let svc = Service(image: "alpine", uts: "host")
        let (result, output) = try captureStandardOutput { args(for: svc) }
        #expect(!result.contains("--uts"))
        #expect(output.contains("Note: 'uts' is parsed but not supported by Apple container; ignored."))
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

    @Test("${VAR} substitution is skipped for unsupported domainname")
    func varSubstitutionSkippedInDomainname() {
        let svc = Service(image: "alpine", domainname: "${DOMAIN}")
        let result = args(for: svc, env: ["DOMAIN": "my.corp"])
        #expect(!result.contains("--domainname"))
        #expect(!result.contains("my.corp"))
    }

    // MARK: - Combination test

    @Test("Combo: dns + dns_search emit and extra_hosts does not emit unsupported flags")
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

        #expect(dnsVals == ["8.8.8.8"])
        #expect(searchVals == ["example.com"])
        #expect(!result.contains("--add-host"))
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

    @Test("hostname warns and emits no unsupported --hostname flag")
    func hostnameWarnsAndEmitsNoUnsupportedFlag() throws {
        let svc = Service(image: "alpine", hostname: "myhostname")
        let (result, output) = try captureStandardOutput { args(for: svc) }
        #expect(!result.contains("--hostname"))
        #expect(!result.contains("myhostname"))
        #expect(output.contains("Note: 'hostname' is parsed but not yet implemented (CHAOS-1474). The container's runtime --name remains the only locally-set hostname."))
    }

    @Test("Regression: nil fields produce no args")
    func regressionNilFieldsProduceNoArgs() {
        let svc = Service(image: "alpine")
        let result = args(for: svc)
        // A bare service with no networking fields should produce an empty argv
        #expect(result.isEmpty)
    }
}
