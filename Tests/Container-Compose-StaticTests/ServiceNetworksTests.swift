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

/// Tests for Phase 3B — ServiceNetworks: object-form decoding and argv emission.
@Suite("Service Networks Tests")
struct ServiceNetworksTests {

    // MARK: - Helpers

    private let emptyCompose: DockerCompose = {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        return try! YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }()

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

    private func networkArgs(for service: Service, env: [String: String] = [:]) -> [String] {
        ComposeUp.NetworkingArgs.build(ctx(service, env: env))
    }

    // MARK: - Decoding: list form

    @Test("List form decodes to entries with empty configs")
    func listFormDecodesEntries() throws {
        let yaml = """
        - foo
        - bar
        """
        let decoder = YAMLDecoder()
        let sn = try decoder.decode(ServiceNetworks.self, from: yaml)
        #expect(sn.entries.count == 2)
        #expect(sn.entries[0].name == "foo")
        #expect(sn.entries[1].name == "bar")
        #expect(sn.entries[0].config.aliases == nil)
        #expect(sn.entries[1].config.aliases == nil)
    }

    @Test("List form names property returns ordered names")
    func listFormNamesProperty() throws {
        let yaml = """
        - alpha
        - beta
        - gamma
        """
        let sn = try YAMLDecoder().decode(ServiceNetworks.self, from: yaml)
        #expect(sn.names == ["alpha", "beta", "gamma"])
    }

    // MARK: - Decoding: map form with nil/empty values

    @Test("Map form with empty values decodes to nil configs")
    func mapFormEmptyValues() throws {
        let yaml = """
        foo:
        bar:
        """
        let sn = try YAMLDecoder().decode(ServiceNetworks.self, from: yaml)
        #expect(sn.entries.count == 2)
        // Map form is sorted alphabetically
        #expect(sn.names.sorted() == ["bar", "foo"])
        let barEntry = sn.entries.first(where: { $0.name == "bar" })
        let fooEntry = sn.entries.first(where: { $0.name == "foo" })
        #expect(barEntry != nil)
        #expect(fooEntry != nil)
        #expect(barEntry?.config.aliases == nil)
        #expect(fooEntry?.config.aliases == nil)
    }

    // MARK: - Decoding: map form with aliases

    @Test("Map form with aliases decodes correctly")
    func mapFormWithAliases() throws {
        let yaml = """
        foo:
          aliases:
            - a1
            - a2
        """
        let sn = try YAMLDecoder().decode(ServiceNetworks.self, from: yaml)
        #expect(sn.entries.count == 1)
        let entry = sn.entries[0]
        #expect(entry.name == "foo")
        #expect(entry.config.aliases == ["a1", "a2"])
    }

    @Test("Map form with multiple networks some having aliases")
    func mapFormMultipleWithAliases() throws {
        let yaml = """
        frontend:
          aliases:
            - web
            - www
        backend:
          aliases:
            - api
        """
        let sn = try YAMLDecoder().decode(ServiceNetworks.self, from: yaml)
        #expect(sn.entries.count == 2)
        let backendEntry = sn.entries.first(where: { $0.name == "backend" })
        let frontendEntry = sn.entries.first(where: { $0.name == "frontend" })
        #expect(backendEntry?.config.aliases == ["api"])
        #expect(frontendEntry?.config.aliases == ["web", "www"])
    }

    // MARK: - Decoding: map form with ipv4_address

    @Test("Map form with ipv4_address decodes correctly")
    func mapFormWithIPv4Address() throws {
        let yaml = """
        mynet:
          ipv4_address: 172.16.0.5
        """
        let sn = try YAMLDecoder().decode(ServiceNetworks.self, from: yaml)
        #expect(sn.entries.count == 1)
        #expect(sn.entries[0].name == "mynet")
        #expect(sn.entries[0].config.ipv4_address == "172.16.0.5")
    }

    @Test("Map form with full config decodes all fields")
    func mapFormWithFullConfig() throws {
        let yaml = """
        mynet:
          aliases:
            - svc-alias
          ipv4_address: 10.0.0.2
          ipv6_address: "::1"
          mac_address: "02:42:ac:11:00:05"
          priority: 100
        """
        let sn = try YAMLDecoder().decode(ServiceNetworks.self, from: yaml)
        let entry = sn.entries[0]
        #expect(entry.config.aliases == ["svc-alias"])
        #expect(entry.config.ipv4_address == "10.0.0.2")
        #expect(entry.config.ipv6_address == "::1")
        #expect(entry.config.mac_address == "02:42:ac:11:00:05")
        #expect(entry.config.priority == 100)
    }

    // MARK: - ServiceNetworks.list helper

    @Test("ServiceNetworks.list helper produces same structure as list-form decode")
    func listHelperMatchesListDecode() throws {
        let yaml = """
        - foo
        - bar
        """
        let decoded = try YAMLDecoder().decode(ServiceNetworks.self, from: yaml)
        let fromHelper = ServiceNetworks.list(["foo", "bar"])
        #expect(fromHelper == decoded)
        #expect(fromHelper.names == ["foo", "bar"])
    }

    @Test("ServiceNetworks.list helper with empty array")
    func listHelperEmptyArray() {
        let sn = ServiceNetworks.list([])
        #expect(sn.entries.isEmpty)
        #expect(sn.names.isEmpty)
        #expect(sn.count == 0)
    }

    // MARK: - Decoding in service context

    @Test("Service with list-form networks decodes correctly")
    func serviceListFormNetworksDecode() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
            networks:
              - frontend
              - backend
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let sn = compose.services["web"]??.networks
        #expect(sn != nil)
        #expect(sn?.count == 2)
        #expect(sn?.contains("frontend") == true)
        #expect(sn?.contains("backend") == true)
    }

    @Test("Service with map-form networks decodes correctly")
    func serviceMapFormNetworksDecode() throws {
        let yaml = """
        services:
          app:
            image: myapp:latest
            networks:
              mynet:
                aliases:
                  - app-alias
              other:
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let sn = compose.services["app"]??.networks
        #expect(sn != nil)
        #expect(sn?.count == 2)
        let mynetEntry = sn?.entries.first(where: { $0.name == "mynet" })
        #expect(mynetEntry?.config.aliases == ["app-alias"])
    }

    // MARK: - Argv emission: list form

    @Test("List form network emission produces --network per entry (no --alias)")
    func listFormArgvEmission() {
        let svc = Service(image: "alpine", networks: ServiceNetworks.list(["net1", "net2"]))
        let result = networkArgs(for: svc)
        let networkPairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--network" }
            .map { result[$0 + 1] }
        #expect(networkPairs.contains("net1"))
        #expect(networkPairs.contains("net2"))
        #expect(networkPairs.count == 2)
        // No --alias flags
        #expect(!result.contains("--alias"))
    }

    @Test("Single list-form network emits exactly one --network flag")
    func singleListFormNetworkArg() {
        let svc = Service(image: "alpine", networks: ServiceNetworks.list(["mynet"]))
        let result = networkArgs(for: svc)
        let networkPairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--network" }
            .map { result[$0 + 1] }
        #expect(networkPairs == ["mynet"])
        #expect(!result.contains("--alias"))
    }

    // MARK: - Argv emission: map form with aliases

    @Test("Map form with aliases emits --network and no unsupported --alias flags")
    func mapFormWithAliasesArgvEmission() {
        let config = ServiceNetworkConfig(aliases: ["a1", "a2"])
        let sn = ServiceNetworks(entries: [("foo", config)])
        let svc = Service(image: "alpine", networks: sn)
        let result = networkArgs(for: svc)
        // Should have --network foo
        let networkIdx = result.firstIndex(of: "--network")
        #expect(networkIdx != nil)
        if let idx = networkIdx {
            #expect(result[idx + 1] == "foo")
        }
        #expect(!result.contains("--alias"))
    }

    @Test("Map form without aliases does not emit --alias flags")
    func mapFormNoAliasesNoAliasFlag() {
        let config = ServiceNetworkConfig(ipv4_address: "10.0.0.5")
        let sn = ServiceNetworks(entries: [("mynet", config)])
        let svc = Service(image: "alpine", networks: sn)
        let result = networkArgs(for: svc)
        let networkPairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--network" }
            .map { result[$0 + 1] }
        #expect(networkPairs == ["mynet"])
        #expect(!result.contains("--alias"))
        // --ip should be emitted for ipv4_address
        let ipPairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--ip" }
            .map { result[$0 + 1] }
        #expect(ipPairs == ["10.0.0.5"])
    }

    @Test("Map form with aliases and ipv4 emits network/ip but no unsupported --alias flags")
    func mapFormWithAliasesAndIPv4() {
        let config = ServiceNetworkConfig(aliases: ["svc-alias"], ipv4_address: "192.168.1.10")
        let sn = ServiceNetworks(entries: [("appnet", config)])
        let svc = Service(image: "alpine", networks: sn)
        let result = networkArgs(for: svc)
        let networkPairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--network" }
            .map { result[$0 + 1] }
        #expect(networkPairs == ["appnet"])
        #expect(!result.contains("--alias"))
        let ipPairs = stride(from: 0, to: result.count - 1, by: 1)
            .filter { result[$0] == "--ip" }
            .map { result[$0 + 1] }
        #expect(ipPairs == ["192.168.1.10"])
    }

    // MARK: - Ordering

    @Test("Map form sorts keys alphabetically")
    func mapFormAlphabeticalOrdering() throws {
        let yaml = """
        zebra:
        apple:
        mango:
        """
        let sn = try YAMLDecoder().decode(ServiceNetworks.self, from: yaml)
        #expect(sn.names == ["apple", "mango", "zebra"])
    }

    @Test("List form preserves YAML declaration order")
    func listFormPreservesOrder() throws {
        let yaml = """
        - zebra
        - apple
        - mango
        """
        let sn = try YAMLDecoder().decode(ServiceNetworks.self, from: yaml)
        #expect(sn.names == ["zebra", "apple", "mango"])
    }
}
