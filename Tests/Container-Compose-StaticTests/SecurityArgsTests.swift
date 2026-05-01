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
import Darwin
import Yams
@testable import ContainerComposeCore

@Suite("SecurityArgs builder tests", .serialized)
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

    private func captureStandardOutput(_ body: () throws -> Void) throws -> String {
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        guard original >= 0 else { throw CaptureError.dupFailed }

        let pipe = Pipe()
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            close(original)
            throw CaptureError.dupFailed
        }

        do {
            try body()
            fflush(stdout)
            restoreStandardOutput(original: original, pipe: pipe)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
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

    @Test("security_opt warns once and emits no unsupported flags")
    func securityOptWarnsOnceAndEmitsNoUnsupportedFlags() throws {
        let svc = Service(image: "nginx", security_opt: ["seccomp:unconfined", "no-new-privileges:true"])
        var args: [String] = []
        let output = try captureStandardOutput {
            args = ComposeUp.SecurityArgs.build(try ctx(svc))
        }
        #expect(!args.contains("--security-opt"))
        #expect(!args.contains("seccomp:unconfined"))
        #expect(!args.contains("no-new-privileges:true"))
        #expect(output.contains("Note: 'security_opt' is parsed but not supported by Apple container; ignored."))

        let repeatedOutput = try captureStandardOutput {
            _ = ComposeUp.SecurityArgs.build(try ctx(svc))
        }
        #expect(repeatedOutput.isEmpty)
    }

    @Test("security_opt nil emits no flag")
    func securityOptNilEmitsNothing() throws {
        let svc = Service(image: "nginx", security_opt: nil)
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(!args.contains("--security-opt"))
    }

    // MARK: - Phase 2A: userns_mode

    @Test("userns_mode warns once and emits no unsupported flags")
    func usernsModeWarnsOnceAndEmitsNoUnsupportedFlags() throws {
        let svc = Service(image: "nginx", userns_mode: "host")
        var args: [String] = []
        let output = try captureStandardOutput {
            args = ComposeUp.SecurityArgs.build(try ctx(svc))
        }
        #expect(!args.contains("--userns"))
        #expect(!args.contains("host"))
        #expect(output.contains("Note: 'userns_mode' is parsed but not supported by Apple container; ignored."))

        let repeatedOutput = try captureStandardOutput {
            _ = ComposeUp.SecurityArgs.build(try ctx(svc))
        }
        #expect(repeatedOutput.isEmpty)
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

    @Test("supported Phase 2A flags together produce correct argv")
    func supportedPhase2AFlagsTogether() throws {
        let svc = Service(
            image: "nginx",
            cap_add: ["NET_ADMIN"],
            cap_drop: ["ALL"],
            group_add: ["audio"]
        )
        let args = ComposeUp.SecurityArgs.build(try ctx(svc))
        #expect(args.contains("--cap-add"))
        #expect(args.contains("NET_ADMIN"))
        #expect(args.contains("--cap-drop"))
        #expect(args.contains("ALL"))
        #expect(!args.contains("--security-opt"))
        #expect(!args.contains("--userns"))
        #expect(args.contains("--group-add"))
        #expect(args.contains("audio"))
    }
}
