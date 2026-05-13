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
@testable import ContainerComposeCore

@Suite("Helper Functions Tests")
struct HelperFunctionsTests {
    
    @Test("Derive project name: dots become underscores and result is lowercased (CHAOS-1511)")
    func testDeriveProjectName() throws {
        // CHAOS-1511: deriveProjectName now lowercases per compose-spec.
        // Dots still become underscores (container resource names forbid dots).
        var cwd = "/Users/user/Projects/My.Project"
        var projectName = deriveProjectName(cwd: cwd)
        #expect(projectName == "my_project")

        cwd = ".devcontainers"
        projectName = deriveProjectName(cwd: cwd)
        #expect(projectName == "_devcontainers")
    }

    @Test("Derive project name: uppercase directories are lowercased (CHAOS-1511)")
    func testDeriveProjectNameLowercase() throws {
        // CHAOS-1511 — apple/container's network ID validation rejects
        // uppercase; align with `docker compose`'s downcase-on-derive behavior.
        #expect(deriveProjectName(cwd: "/tmp/CHAOS-1506-repro") == "chaos-1506-repro")
        #expect(deriveProjectName(cwd: "/tmp/MixedCase") == "mixedcase")
        #expect(deriveProjectName(cwd: "/tmp/already-lowercase") == "already-lowercase")
    }

    @Test("Resolve explicit relative paths against base URL")
    func testResolvedPathRelativeSegments() throws {
        let base = "/tmp/project/compose"

        #expect(resolvedPath(for: "./file.yaml", relativeTo: base) == "/tmp/project/compose/file.yaml")
        #expect(resolvedPath(for: "../shared/file.yaml", relativeTo: base) == "/tmp/project/shared/file.yaml")
        #expect(resolvedPath(for: "configs/dev/compose.yaml", relativeTo: base) == "/tmp/project/compose/configs/dev/compose.yaml")
    }

    @Test("Resolve absolute and tilde paths without rebasing")
    func testResolvedPathAbsoluteAndTilde() throws {
        let base = "/tmp/project/compose"
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(resolvedPath(for: "/var/tmp/compose.yaml", relativeTo: base) == "/var/tmp/compose.yaml")
        #expect(resolvedPath(for: "~/compose.yaml", relativeTo: base) == "\(homePath)/compose.yaml")
    }

    @Test("Compose port - simple container port")
    func testPortSimple() throws {
        let result = composePortToRunArg("3000")
        #expect(result == "0.0.0.0:3000:3000")
    }

    @Test("Compose port - host:container same port")
    func testPortHostContainerSame() throws {
        let result = composePortToRunArg("3000:3000")
        #expect(result == "0.0.0.0:3000:3000")
    }

    @Test("Compose port - host:container different ports")
    func testPortHostContainerDifferent() throws {
        let result = composePortToRunArg("8080:3000")
        #expect(result == "0.0.0.0:8080:3000")
    }

    @Test("Compose port - explicit IP binding IPv4")
    func testPortIPv4Binding() throws {
        let result = composePortToRunArg("127.0.0.1:5432:5432")
        #expect(result == "127.0.0.1:5432:5432")
    }

    @Test("Compose port - explicit IP binding IPv6")
    func testPortIPv6Binding() throws {
        let result = composePortToRunArg("[::1]:3000:3000")
        #expect(result == "[::1]:3000:3000")
    }

    @Test("Compose port - with protocol tcp")
    func testPortWithProtocolTCP() throws {
        let result = composePortToRunArg("3000:3000/tcp")
        #expect(result == "0.0.0.0:3000:3000/tcp")
    }

    @Test("Compose port - explicit IP with protocol")
    func testPortIPv4WithProtocol() throws {
        let result = composePortToRunArg("127.0.0.1:5432:5432/tcp")
        #expect(result == "127.0.0.1:5432:5432/tcp")
    }

    @Test("Compose port - explicit IP already with 0.0.0.0")
    func testPortZeroZeroZeroZero() throws {
        let result = composePortToRunArg("0.0.0.0:3000:3000")
        #expect(result == "0.0.0.0:3000:3000")
    }

    // MARK: - effectiveContainerName

    @Test("effectiveContainerName uses explicit container_name when provided")
    func testEffectiveContainerNameUsesExplicit() throws {
        let resolved = effectiveContainerName(
            projectName: "myproj",
            serviceName: "web",
            explicit: "my-web"
        )
        #expect(resolved == "my-web")
    }

    @Test("effectiveContainerName falls back to project-service when explicit is nil")
    func testEffectiveContainerNameFallsBackWhenNil() throws {
        let resolved = effectiveContainerName(
            projectName: "myproj",
            serviceName: "web",
            explicit: nil
        )
        #expect(resolved == "myproj-web")
    }

    @Test("effectiveContainerName falls back when explicit is empty string")
    func testEffectiveContainerNameFallsBackWhenEmpty() throws {
        let resolved = effectiveContainerName(
            projectName: "myproj",
            serviceName: "web",
            explicit: ""
        )
        #expect(resolved == "myproj-web")
    }

    // MARK: - formatPublishedPorts (CHAOS-1440)

    @Test("formatPublishedPorts: empty input returns empty string")
    func testFormatPublishedPortsEmpty() throws {
        #expect(formatPublishedPorts([]) == "")
    }

    @Test("formatPublishedPorts: single port renders host:host->container/proto")
    func testFormatPublishedPortsSingle() throws {
        let ports = [
            RuntimePublishedPort(
                hostAddress: "0.0.0.0",
                hostPort: 8080,
                containerPort: 80,
                proto: .tcp
            )
        ]
        #expect(formatPublishedPorts(ports) == "0.0.0.0:8080->80/tcp")
    }

    @Test("formatPublishedPorts: multi-port joins with comma-space")
    func testFormatPublishedPortsMulti() throws {
        let ports = [
            RuntimePublishedPort(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: .tcp),
            RuntimePublishedPort(hostAddress: "127.0.0.1", hostPort: 8443, containerPort: 443, proto: .tcp),
        ]
        #expect(
            formatPublishedPorts(ports) ==
            "0.0.0.0:8080->80/tcp, 127.0.0.1:8443->443/tcp"
        )
    }

    @Test("formatPublishedPorts: mixed tcp + udp protocols are honored")
    func testFormatPublishedPortsMixedProto() throws {
        let ports = [
            RuntimePublishedPort(hostAddress: "0.0.0.0", hostPort: 53, containerPort: 53, proto: .tcp),
            RuntimePublishedPort(hostAddress: "0.0.0.0", hostPort: 53, containerPort: 53, proto: .udp),
        ]
        #expect(
            formatPublishedPorts(ports) ==
            "0.0.0.0:53->53/tcp, 0.0.0.0:53->53/udp"
        )
    }

}
