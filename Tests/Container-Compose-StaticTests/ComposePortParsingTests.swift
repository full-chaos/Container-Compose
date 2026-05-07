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
import TestHelpers
@testable import ContainerComposeCore

@Suite("Compose Port Parsing Tests")
struct ComposePortParsingTests {

    @Test("required service and private-port arguments parse")
    func requiredArgumentsParse() throws {
        let cmd = try ComposePort.parse(["web", "80"])
        #expect(cmd.service == "web")
        #expect(cmd.privatePort == 80)
        #expect(cmd.all == false)
    }

    @Test("--protocol defaults to tcp")
    func protocolDefaultsToTCP() throws {
        let cmd = try ComposePort.parse(["web", "80"])
        #expect(cmd.`protocol` == .tcp)
    }

    @Test("--protocol udp parses")
    func protocolUDPParses() throws {
        let cmd = try ComposePort.parse(["web", "53", "--protocol", "udp"])
        #expect(cmd.`protocol` == .udp)
    }

    // CHAOS-1440: zero positional args is now legal — listing mode.
    @Test("no arguments parse to listing mode (CHAOS-1440)")
    func noArgsParse() throws {
        let cmd = try ComposePort.parse([])
        #expect(cmd.service == nil)
        #expect(cmd.privatePort == nil)
        #expect(cmd.all == false)
    }

    @Test("--all parses with no positionals")
    func allLongFlagParses() throws {
        let cmd = try ComposePort.parse(["--all"])
        #expect(cmd.all == true)
        #expect(cmd.service == nil)
        #expect(cmd.privatePort == nil)
    }

    @Test("-a parses with no positionals")
    func allShortFlagParses() throws {
        let cmd = try ComposePort.parse(["-a"])
        #expect(cmd.all == true)
        #expect(cmd.service == nil)
        #expect(cmd.privatePort == nil)
    }

    @Test("only <service> positional parses with privatePort nil")
    func serviceOnlyParses() throws {
        let cmd = try ComposePort.parse(["redis"])
        #expect(cmd.service == "redis")
        #expect(cmd.privatePort == nil)
        #expect(cmd.all == false)
    }

    @Test("two positional arguments still parse to today's resolver behavior")
    func twoPositionalsStillParse() throws {
        let cmd = try ComposePort.parse(["redis", "6379"])
        #expect(cmd.service == "redis")
        #expect(cmd.privatePort == 6379)
        #expect(cmd.all == false)
    }

    @Test("two positionals + --protocol udp parse together")
    func twoPositionalsWithUDPParse() throws {
        let cmd = try ComposePort.parse(["redis", "6379", "--protocol", "udp"])
        #expect(cmd.service == "redis")
        #expect(cmd.privatePort == 6379)
        #expect(cmd.`protocol` == .udp)
    }

    // `port -a 6379` — argv-parser sees a single positional. Because the
    // first positional binds to `service`, "6379" lands there as a string
    // and `privatePort` remains nil. The `--all` + non-nil-privatePort
    // mutex therefore does NOT trip at parse time; it only trips when both
    // positionals are present. This documents the parser-level behavior.
    @Test("port -a <number>: number binds to service, privatePort stays nil")
    func dashAWithSingleNumberPositional() throws {
        let cmd = try ComposePort.parse(["-a", "6379"])
        #expect(cmd.all == true)
        #expect(cmd.service == "6379")
        #expect(cmd.privatePort == nil)
    }

    @Test("resolves host port from host-to-private tcp binding")
    func resolvesHostPortFromTCPBinding() throws {
        let compose = try loadComposePortFixture(ports: ["8080:80"])
        let result = try ComposePort.resolvePublishedPort(in: compose, serviceName: "web", privatePort: 80)
        #expect(result == "0.0.0.0:8080")
    }

    @Test("resolves explicit host IP tcp binding")
    func resolvesExplicitHostIPTCPBinding() throws {
        let compose = try loadComposePortFixture(ports: ["127.0.0.1:8080:80/tcp"])
        let result = try ComposePort.resolvePublishedPort(in: compose, serviceName: "web", privatePort: 80, protocol: .tcp)
        #expect(result == "127.0.0.1:8080")
    }

    @Test("resolves udp binding")
    func resolvesUDPBinding() throws {
        let compose = try loadComposePortFixture(
            serviceName: "dns",
            image: "coredns/coredns:latest",
            ports: ["53:53/udp"]
        )
        let result = try ComposePort.resolvePublishedPort(in: compose, serviceName: "dns", privatePort: 53, protocol: .udp)
        #expect(result == "0.0.0.0:53")
    }

    @Test("bare container port is not considered published")
    func bareContainerPortIsNotPublished() throws {
        let compose = try loadComposePortFixture(ports: ["80"])
        #expect(throws: (any Error).self) {
            _ = try ComposePort.resolvePublishedPort(in: compose, serviceName: "web", privatePort: 80)
        }
    }

    @Test("missing service throws")
    func missingServiceThrows() throws {
        let compose = try loadComposePortFixture(ports: ["8080:80"])
        #expect(throws: (any Error).self) {
            _ = try ComposePort.resolvePublishedPort(in: compose, serviceName: "api", privatePort: 80)
        }
    }

    @Test("missing private-port match throws")
    func missingPrivatePortMatchThrows() throws {
        let compose = try loadComposePortFixture(ports: ["8080:80"])
        #expect(throws: (any Error).self) {
            _ = try ComposePort.resolvePublishedPort(in: compose, serviceName: "web", privatePort: 443)
        }
    }

    private func loadComposePortFixture(
        serviceName: String = "web",
        image: String = "nginx:alpine",
        ports: [String]
    ) throws -> DockerCompose {
        let renderedPorts = ports.map { "      - \"\($0)\"" }.joined(separator: "\n")
        let yaml = """
        services:
          \(serviceName):
            image: \(image)
            ports:
        \(renderedPorts)
        """
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)
        return try DockerCompose.loadAndMerge(mainPath: project.url.path).resolvingExtends()
    }
}
