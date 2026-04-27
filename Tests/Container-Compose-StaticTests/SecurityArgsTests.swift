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
import Yams
@testable import ContainerComposeCore

@Suite("SecurityArgs builder tests")
struct SecurityArgsTests {

    // MARK: - Helpers

    /// Decode a minimal DockerCompose from YAML (DockerCompose has no memberwise init).
    private func minimalDC() throws -> DockerCompose {
        let yaml = """
        services:
          placeholder:
            image: alpine
        """
        return try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    private func ctx(_ service: Service, projectName: String = "test") throws -> ComposeUp.ArgsContext {
        let dc = try minimalDC()
        return ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: projectName,
            containerName: "\(projectName)-svc",
            detach: false,
            environmentVariables: [:],
            dockerCompose: dc,
            composeFilename: nil
        )
    }

    // MARK: - Existing flags (regression)

    @Test("user flag is emitted")
    func userFlagEmitted() throws {
        let svc = Service(image: "nginx", user: "1000:1000")
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(args.contains("--user"))
        #expect(args.contains("1000:1000"))
    }

    @Test("privileged flag is emitted")
    func privilegedFlagEmitted() throws {
        let svc = Service(image: "nginx", privileged: true)
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(args.contains("--privileged"))
    }

    @Test("read_only flag is emitted")
    func readOnlyFlagEmitted() throws {
        let svc = Service(image: "nginx", read_only: true)
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(args.contains("--read-only"))
    }

    // MARK: - Phase 2A: cap_add

    @Test("cap_add emits --cap-add per item")
    func capAddEmitsFlagPerItem() throws {
        let svc = Service(image: "nginx", cap_add: ["NET_ADMIN", "SYS_TIME"])
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(args.contains("--cap-add"))
        #expect(args.contains("NET_ADMIN"))
        #expect(args.contains("SYS_TIME"))
        // Each item gets its own --cap-add flag
        let indices = args.indices.filter { args[$0] == "--cap-add" }
        #expect(indices.count == 2)
    }

    @Test("cap_add nil emits no flag")
    func capAddNilEmitsNothing() throws {
        let svc = Service(image: "nginx", cap_add: nil)
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(!args.contains("--cap-add"))
    }

    // MARK: - Phase 2A: cap_drop

    @Test("cap_drop emits --cap-drop per item")
    func capDropEmitsFlagPerItem() throws {
        let svc = Service(image: "nginx", cap_drop: ["ALL", "NET_RAW"])
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(args.contains("--cap-drop"))
        #expect(args.contains("ALL"))
        #expect(args.contains("NET_RAW"))
        let indices = args.indices.filter { args[$0] == "--cap-drop" }
        #expect(indices.count == 2)
    }

    @Test("cap_drop nil emits no flag")
    func capDropNilEmitsNothing() throws {
        let svc = Service(image: "nginx", cap_drop: nil)
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(!args.contains("--cap-drop"))
    }

    // MARK: - Phase 2A: security_opt

    @Test("security_opt emits --security-opt per item")
    func securityOptEmitsFlagPerItem() throws {
        let svc = Service(image: "nginx", security_opt: ["seccomp:unconfined", "no-new-privileges:true"])
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(args.contains("--security-opt"))
        #expect(args.contains("seccomp:unconfined"))
        #expect(args.contains("no-new-privileges:true"))
        let indices = args.indices.filter { args[$0] == "--security-opt" }
        #expect(indices.count == 2)
    }

    @Test("security_opt nil emits no flag")
    func securityOptNilEmitsNothing() throws {
        let svc = Service(image: "nginx", security_opt: nil)
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(!args.contains("--security-opt"))
    }

    // MARK: - Phase 2A: userns_mode

    @Test("userns_mode emits --userns MODE")
    func usernsModePresentEmitsFlag() throws {
        let svc = Service(image: "nginx", userns_mode: "host")
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(args.contains("--userns"))
        #expect(args.contains("host"))
    }

    @Test("userns_mode nil emits no flag")
    func usernsModeNilEmitsNothing() throws {
        let svc = Service(image: "nginx", userns_mode: nil)
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(!args.contains("--userns"))
    }

    // MARK: - Phase 2A: group_add

    @Test("group_add emits --group-add per item")
    func groupAddEmitsFlagPerItem() throws {
        let svc = Service(image: "nginx", group_add: ["audio", "video"])
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(args.contains("--group-add"))
        #expect(args.contains("audio"))
        #expect(args.contains("video"))
        let indices = args.indices.filter { args[$0] == "--group-add" }
        #expect(indices.count == 2)
    }

    @Test("group_add nil emits no flag")
    func groupAddNilEmitsNothing() throws {
        let svc = Service(image: "nginx", group_add: nil)
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(!args.contains("--group-add"))
    }

    // MARK: - Combination tests

    @Test("cap_add and cap_drop together, correct counts")
    func capAddAndDropTogether() throws {
        let svc = Service(image: "nginx", cap_add: ["NET_ADMIN"], cap_drop: ["ALL"])
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        let addIndices = args.indices.filter { args[$0] == "--cap-add" }
        let dropIndices = args.indices.filter { args[$0] == "--cap-drop" }
        #expect(addIndices.count == 1)
        #expect(dropIndices.count == 1)
    }

    @Test("all Phase 2A flags together produce correct argv")
    func allPhase2AFlagsTogether() throws {
        let svc = Service(
            image: "nginx",
            cap_add: ["NET_ADMIN"],
            cap_drop: ["ALL"],
            security_opt: ["no-new-privileges:true"],
            userns_mode: "host",
            group_add: ["audio"]
        )
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(args.contains("--cap-add"))
        #expect(args.contains("NET_ADMIN"))
        #expect(args.contains("--cap-drop"))
        #expect(args.contains("ALL"))
        #expect(args.contains("--security-opt"))
        #expect(args.contains("no-new-privileges:true"))
        #expect(args.contains("--userns"))
        #expect(args.contains("host"))
        #expect(args.contains("--group-add"))
        #expect(args.contains("audio"))
    }
}
