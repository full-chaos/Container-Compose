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

//
//  ComposeKillRmCreateTests.swift
//  Container-Compose
//

import Testing
import Foundation
@testable import ContainerComposeCore

@Suite("Compose Kill / Rm / Create Parsing Tests")
struct ComposeKillRmCreateTests {

    // MARK: - ComposeKill

    @Test("ComposeKill parses without arguments")
    func composeKillParsesWithoutArgs() throws {
        let cmd = try ComposeKill.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.signal == "SIGKILL")
        #expect(cmd.composeFilename == nil)
        #expect(cmd.profile.isEmpty)
    }

    @Test("ComposeKill --signal SIGTERM parses")
    func composeKillParsesSignalSIGTERM() throws {
        let cmd = try ComposeKill.parse(["--signal", "SIGTERM"])
        #expect(cmd.signal == "SIGTERM")
    }

    @Test("ComposeKill -s short flag parses")
    func composeKillParsesShortSignalFlag() throws {
        let cmd = try ComposeKill.parse(["-s", "SIGINT"])
        #expect(cmd.signal == "SIGINT")
    }

    @Test("ComposeKill service name arg parses")
    func composeKillParsesServiceArg() throws {
        let cmd = try ComposeKill.parse(["web", "db"])
        #expect(cmd.services == ["web", "db"])
    }

    @Test("ComposeKill --profile parses")
    func composeKillParsesProfile() throws {
        let cmd = try ComposeKill.parse(["--profile", "dev", "--profile", "debug"])
        #expect(cmd.profile == ["dev", "debug"])
    }

    @Test("ComposeKill --file parses")
    func composeKillParsesFileFlag() throws {
        let cmd = try ComposeKill.parse(["-f", "custom-compose.yml"])
        #expect(cmd.composeFilename == "custom-compose.yml")
    }

    // MARK: - ComposeRm

    @Test("ComposeRm parses without arguments")
    func composeRmParsesWithoutArgs() throws {
        let cmd = try ComposeRm.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.force == false)
        #expect(cmd.stop == false)
        #expect(cmd.removeVolumes == false)
        #expect(cmd.file == nil)
        #expect(cmd.profile.isEmpty)
    }

    @Test("ComposeRm --force parses")
    func composeRmParsesForce() throws {
        let cmd = try ComposeRm.parse(["--force"])
        #expect(cmd.force == true)
    }

    @Test("ComposeRm -f short flag parses as force")
    func composeRmParsesShortForce() throws {
        let cmd = try ComposeRm.parse(["-f"])
        #expect(cmd.force == true)
    }

    @Test("ComposeRm --stop parses")
    func composeRmParsesStop() throws {
        let cmd = try ComposeRm.parse(["--stop"])
        #expect(cmd.stop == true)
    }

    @Test("ComposeRm -s short flag parses as stop")
    func composeRmParsesShortStop() throws {
        let cmd = try ComposeRm.parse(["-s"])
        #expect(cmd.stop == true)
    }

    @Test("ComposeRm --volumes parses")
    func composeRmParsesVolumes() throws {
        let cmd = try ComposeRm.parse(["--volumes"])
        #expect(cmd.removeVolumes == true)
    }

    @Test("ComposeRm --file long-only parses")
    func composeRmParsesFileLong() throws {
        let cmd = try ComposeRm.parse(["--file", "docker-compose.yaml"])
        #expect(cmd.file == "docker-compose.yaml")
        #expect(cmd.composeFilename == "docker-compose.yaml")
    }

    @Test("ComposeRm --profile parses")
    func composeRmParsesProfile() throws {
        let cmd = try ComposeRm.parse(["--profile", "staging"])
        #expect(cmd.profile == ["staging"])
    }

    @Test("ComposeRm service name arg parses")
    func composeRmParsesServiceArg() throws {
        let cmd = try ComposeRm.parse(["api", "worker"])
        #expect(cmd.services == ["api", "worker"])
    }

    @Test("ComposeRm --force and --stop together parse")
    func composeRmParsesForceAndStop() throws {
        let cmd = try ComposeRm.parse(["--force", "--stop"])
        #expect(cmd.force == true)
        #expect(cmd.stop == true)
    }

    // MARK: - ComposeCreate

    @Test("ComposeCreate parses without arguments")
    func composeCreateParsesWithoutArgs() throws {
        let cmd = try ComposeCreate.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.composeFilename == nil)
        #expect(cmd.profile.isEmpty)
        #expect(cmd.rebuild == false)
        #expect(cmd.noCache == false)
        #expect(cmd.pull == false)
    }

    @Test("ComposeCreate service name arg parses")
    func composeCreateParsesServiceArg() throws {
        let cmd = try ComposeCreate.parse(["web", "db"])
        #expect(cmd.services == ["web", "db"])
    }

    @Test("ComposeCreate --build parses")
    func composeCreateParsesBuildFlag() throws {
        let cmd = try ComposeCreate.parse(["--build"])
        #expect(cmd.rebuild == true)
    }

    @Test("ComposeCreate -b short flag parses")
    func composeCreateParsesShortBuildFlag() throws {
        let cmd = try ComposeCreate.parse(["-b"])
        #expect(cmd.rebuild == true)
    }

    @Test("ComposeCreate --no-cache parses")
    func composeCreateParsesNoCacheFlag() throws {
        let cmd = try ComposeCreate.parse(["--no-cache"])
        #expect(cmd.noCache == true)
    }

    @Test("ComposeCreate --pull parses")
    func composeCreateParsesPullFlag() throws {
        let cmd = try ComposeCreate.parse(["--pull"])
        #expect(cmd.pull == true)
    }

    @Test("ComposeCreate --file parses")
    func composeCreateParsesFileFlag() throws {
        let cmd = try ComposeCreate.parse(["-f", "compose.dev.yml"])
        #expect(cmd.composeFilename == "compose.dev.yml")
    }

    @Test("ComposeCreate --profile parses")
    func composeCreateParsesProfile() throws {
        let cmd = try ComposeCreate.parse(["--profile", "dev"])
        #expect(cmd.profile == ["dev"])
    }
}
