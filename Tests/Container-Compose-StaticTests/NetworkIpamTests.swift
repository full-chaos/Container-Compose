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

@Suite("Network IPAM Tests")
struct NetworkIpamTests {

    @Test("Network with basic IPAM config decodes one entry")
    func networkWithSingleIpamConfig() throws {
        let yaml = """
        driver: default
        ipam:
          driver: default
          config:
            - subnet: 10.0.0.0/24
        """
        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)

        #expect(network.ipam != nil)
        #expect(network.ipam?.driver == "default")
        #expect(network.ipam?.config?.count == 1)
        #expect(network.ipam?.config?.first?.subnet == "10.0.0.0/24")
        #expect(network.ipam?.config?.first?.ip_range == nil)
        #expect(network.ipam?.config?.first?.gateway == nil)
    }

    @Test("Network with multiple IPAM configs decodes all entries")
    func networkWithMultipleIpamConfigs() throws {
        let yaml = """
        ipam:
          config:
            - subnet: 172.16.0.0/24
              gateway: 172.16.0.1
            - subnet: 192.168.1.0/24
              ip_range: 192.168.1.128/25
        """
        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)

        #expect(network.ipam?.config?.count == 2)
        let first = network.ipam?.config?[0]
        #expect(first?.subnet == "172.16.0.0/24")
        #expect(first?.gateway == "172.16.0.1")
        let second = network.ipam?.config?[1]
        #expect(second?.subnet == "192.168.1.0/24")
        #expect(second?.ip_range == "192.168.1.128/25")
    }

    @Test("Network with IPAM options decodes driver and options")
    func networkWithIpamOptions() throws {
        let yaml = """
        ipam:
          driver: custom
          options:
            foo: bar
            baz: qux
        """
        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)

        #expect(network.ipam?.driver == "custom")
        #expect(network.ipam?.options?["foo"] == "bar")
        #expect(network.ipam?.options?["baz"] == "qux")
        #expect(network.ipam?.config == nil)
    }

    @Test("Network without IPAM field has nil ipam")
    func networkWithoutIpam() throws {
        let yaml = """
        driver: bridge
        labels:
          env: test
        """
        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)

        #expect(network.ipam == nil)
        #expect(network.driver == "bridge")
    }

    @Test("IpamConfig memberwise init sets all fields")
    func ipamConfigMemberwiseInit() {
        let config = IpamConfig(
            subnet: "10.1.0.0/16",
            ip_range: "10.1.1.0/24",
            gateway: "10.1.0.1",
            aux_addresses: ["host1": "10.1.0.5"]
        )
        #expect(config.subnet == "10.1.0.0/16")
        #expect(config.ip_range == "10.1.1.0/24")
        #expect(config.gateway == "10.1.0.1")
        #expect(config.aux_addresses?["host1"] == "10.1.0.5")
    }

    @Test("Ipam memberwise init sets all fields")
    func ipamMemberwiseInit() {
        let ipamConfig = IpamConfig(subnet: "10.2.0.0/24")
        let ipam = Ipam(driver: "default", config: [ipamConfig], options: ["opt": "val"])
        #expect(ipam.driver == "default")
        #expect(ipam.config?.count == 1)
        #expect(ipam.config?.first?.subnet == "10.2.0.0/24")
        #expect(ipam.options?["opt"] == "val")
    }

    @Test("Network memberwise init with ipam field")
    func networkMemberwiseInitWithIpam() {
        let ipam = Ipam(driver: "default", config: [IpamConfig(subnet: "10.3.0.0/24")])
        let network = Network(driver: "bridge", ipam: ipam)
        #expect(network.driver == "bridge")
        #expect(network.ipam?.driver == "default")
        #expect(network.ipam?.config?.first?.subnet == "10.3.0.0/24")
    }

    @Test("Network IPAM aux_addresses decodes correctly")
    func networkIpamAuxAddresses() throws {
        let yaml = """
        ipam:
          config:
            - subnet: 10.4.0.0/24
              aux_addresses:
                my-router: 10.4.0.2
        """
        let decoder = YAMLDecoder()
        let network = try decoder.decode(Network.self, from: yaml)

        #expect(network.ipam?.config?.first?.aux_addresses?["my-router"] == "10.4.0.2")
    }
}
