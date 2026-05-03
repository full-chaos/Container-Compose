//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
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
@testable import ContainerComposeCore

/// Tests covering `DockerCompose.validatePorts(_:forService:)` — Task 1.8.
///
/// Each test calls `validate()` on a minimal single-service compose document
/// (or the public `validatePorts` API directly) and asserts the expected outcome.
@Suite("Port Format Validation Tests")
struct PortFormatValidationTests {

    // MARK: - Valid single-port forms

    @Test("Bare container port '80' is valid")
    func bareContainerPort80IsValid() {
        assertValidPorts(["80"])
    }

    @Test("Bare container port '0' is valid")
    func bareContainerPort0IsValid() {
        assertValidPorts(["0"])
    }

    @Test("Bare max port '65535' is valid")
    func bareMaxPortIsValid() {
        assertValidPorts(["65535"])
    }

    @Test("HOST:CONTAINER form '8080:80' is valid")
    func hostColonContainerIsValid() {
        assertValidPorts(["8080:80"])
    }

    @Test("IP:HOST:CONTAINER form '127.0.0.1:8080:80' is valid")
    func ipHostContainerIsValid() {
        assertValidPorts(["127.0.0.1:8080:80"])
    }

    @Test("'0.0.0.0:8080:80' is valid")
    func wildcardIpHostContainerIsValid() {
        assertValidPorts(["0.0.0.0:8080:80"])
    }

    // MARK: - Protocol suffixes

    @Test("'/tcp' suffix on bare port is valid")
    func tcpSuffixOnBarePortIsValid() {
        assertValidPorts(["80/tcp"])
    }

    @Test("'/udp' suffix on bare port is valid")
    func udpSuffixOnBarePortIsValid() {
        assertValidPorts(["53/udp"])
    }

    @Test("'/tcp' suffix on HOST:CONTAINER is valid")
    func tcpSuffixOnHostContainerIsValid() {
        assertValidPorts(["8080:80/tcp"])
    }

    @Test("'/udp' suffix on HOST:CONTAINER is valid")
    func udpSuffixOnHostContainerIsValid() {
        assertValidPorts(["5353:53/udp"])
    }

    @Test("'/tcp' suffix on IP:HOST:CONTAINER is valid")
    func tcpSuffixOnIpHostContainerIsValid() {
        assertValidPorts(["127.0.0.1:8080:80/tcp"])
    }

    @Test("'/udp' suffix on IP:HOST:CONTAINER is valid")
    func udpSuffixOnIpHostContainerIsValid() {
        assertValidPorts(["127.0.0.1:5353:53/udp"])
    }

    // MARK: - Port ranges

    @Test("Symmetric port range '8080-8090:8080-8090' is valid")
    func symmetricPortRangeIsValid() {
        assertValidPorts(["8080-8090:8080-8090"])
    }

    @Test("Asymmetric range '8080-8081:80' is valid")
    func asymmetricRangeIsValid() {
        assertValidPorts(["8080-8081:80"])
    }

    // MARK: - Out-of-range port numbers

    @Test("Container port 65536 is out of range")
    func containerPort65536IsOutOfRange() {
        assertInvalidPorts(["65536"])
    }

    @Test("Host port 65536 in HOST:CONTAINER is out of range")
    func hostPort65536IsOutOfRange() {
        assertInvalidPorts(["65536:80"])
    }

    @Test("Container port 99999 is out of range")
    func containerPort99999IsOutOfRange() {
        assertInvalidPorts(["99999"])
    }

    @Test("Negative port '-1' is out of range")
    func negativeContainerPortIsOutOfRange() {
        assertInvalidPorts(["-1"])
    }

    // MARK: - Malformed specs

    @Test("Non-numeric port 'abc' is malformed")
    func nonNumericPortABCIsMalformed() {
        assertInvalidPorts(["abc"])
    }

    @Test("Non-numeric host part 'abc:80' is malformed")
    func nonNumericHostPartIsMalformed() {
        assertInvalidPorts(["abc:80"])
    }

    @Test("Empty string port is malformed")
    func emptyStringPortIsMalformed() {
        assertInvalidPorts([""])
    }

    @Test("Unknown protocol suffix '/sctp' is malformed")
    func unknownProtocolSuffixSCTPIsMalformed() {
        assertInvalidPorts(["80/sctp"])
    }

    @Test("Unknown protocol suffix '/http' is malformed")
    func unknownProtocolSuffixHTTPIsMalformed() {
        assertInvalidPorts(["80/http"])
    }

    @Test("Four colon-separated components is malformed")
    func fourColonComponentsIsMalformed() {
        assertInvalidPorts(["0.0.0.0:8080:80:extra"])
    }

    // MARK: - Edge cases

    @Test("Multiple valid ports all pass")
    func multipleValidPortsAllPass() {
        assertValidPorts(["80", "8080:80", "127.0.0.1:443:443/tcp", "53:53/udp"])
    }

    @Test("Mix of valid and invalid — invalid entry triggers error")
    func mixedPortsInvalidTriggerError() {
        assertInvalidPorts(["80", "99999"])
    }

    @Test("Port 0 is valid (any available port)")
    func portZeroIsValid() {
        assertValidPorts(["0:0"])
    }

    @Test("IPv4 broadcast '255.255.255.255:8080:80' is valid")
    func broadcastIPIsValid() {
        assertValidPorts(["255.255.255.255:8080:80"])
    }

    // MARK: - Direct `validatePorts` API

    @Test("validatePorts with empty list does not throw")
    func validatePortsWithEmptyListDoesNotThrow() {
        let compose = makeCompose(ports: [])
        #expect(throws: Never.self) {
            try compose.validatePorts([], forService: "web")
        }
    }

    @Test("validatePorts returns invalidPortFormat for bad spec")
    func validatePortsReturnsBadPortError() {
        let compose = makeCompose(ports: [])
        #expect(throws: ComposeValidationError.invalidPortFormat(portSpec: "99999", serviceName: "svc")) {
            try compose.validatePorts(["99999"], forService: "svc")
        }
    }

    @Test("validatePorts passes for valid spec '443/tcp'")
    func validatePortsPassesForValidSpec() {
        let compose = makeCompose(ports: [])
        #expect(throws: Never.self) {
            try compose.validatePorts(["443/tcp"], forService: "web")
        }
    }

    // MARK: - Helpers

    private func assertValidPorts(_ ports: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let compose = makeCompose(ports: ports)
        #expect(throws: Never.self, sourceLocation: sourceLocation) {
            try compose.validate()
        }
    }

    private func assertInvalidPorts(_ ports: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let compose = makeCompose(ports: ports)
        #expect(throws: ComposeValidationError.self, sourceLocation: sourceLocation) {
            try compose.validate()
        }
    }

    private func makeCompose(ports: [String]) -> DockerCompose {
        let service = Service(
            image: "nginx:latest",
            ports: ports.isEmpty ? nil : ports
        )
        return DockerCompose(
            version: nil,
            name: nil,
            services: ["web": service],
            volumes: nil,
            networks: nil,
            configs: nil,
            secrets: nil
        )
    }
}
