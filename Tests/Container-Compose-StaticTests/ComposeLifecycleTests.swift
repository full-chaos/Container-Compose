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
//  ComposeLifecycleTests.swift
//  Container-Compose
//

import Testing
import Foundation
@testable import ContainerComposeCore

@Suite("Compose Lifecycle Command Parsing Tests")
struct ComposeLifecycleTests {

    // MARK: - ComposeStart

    @Test("ComposeStart parses without arguments")
    func composeStartParsesWithoutArgs() throws {
        let cmd = try ComposeStart.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.composeFilename == nil)
        #expect(cmd.profile.isEmpty)
    }

    @Test("ComposeStart parses with service name arguments")
    func composeStartParsesWithServicesFilter() throws {
        let cmd = try ComposeStart.parse(["web", "db"])
        #expect(cmd.services == ["web", "db"])
    }

    @Test("ComposeStart parses --file flag")
    func composeStartParsesFileFlag() throws {
        let cmd = try ComposeStart.parse(["-f", "custom-compose.yml"])
        #expect(cmd.composeFilename == "custom-compose.yml")
    }

    @Test("ComposeStart parses --profile flag")
    func composeStartParsesProfileFlag() throws {
        let cmd = try ComposeStart.parse(["--profile", "dev", "--profile", "debug"])
        #expect(cmd.profile == ["dev", "debug"])
    }

    @Test("ComposeStart parses single service with --file and --profile")
    func composeStartParsesServiceWithFileAndProfile() throws {
        let cmd = try ComposeStart.parse(["-f", "prod.yml", "--profile", "prod", "api"])
        #expect(cmd.composeFilename == "prod.yml")
        #expect(cmd.profile == ["prod"])
        #expect(cmd.services == ["api"])
    }

    // MARK: - ComposeStop

    @Test("ComposeStop parses without arguments")
    func composeStopParsesWithoutArgs() throws {
        let cmd = try ComposeStop.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.composeFilename == nil)
        #expect(cmd.profile.isEmpty)
    }

    @Test("ComposeStop parses with service name arguments")
    func composeStopParsesWithServicesFilter() throws {
        let cmd = try ComposeStop.parse(["web", "cache"])
        #expect(cmd.services == ["web", "cache"])
    }

    @Test("ComposeStop parses --file flag")
    func composeStopParsesFileFlag() throws {
        let cmd = try ComposeStop.parse(["-f", "docker-compose.yaml"])
        #expect(cmd.composeFilename == "docker-compose.yaml")
    }

    @Test("ComposeStop parses --profile flag")
    func composeStopParsesProfileFlag() throws {
        let cmd = try ComposeStop.parse(["--profile", "staging"])
        #expect(cmd.profile == ["staging"])
    }

    @Test("ComposeStop parses multiple services with --profile")
    func composeStopParsesServicesWithProfile() throws {
        let cmd = try ComposeStop.parse(["--profile", "prod", "api", "worker"])
        #expect(cmd.profile == ["prod"])
        #expect(cmd.services == ["api", "worker"])
    }

    // MARK: - ComposeRestart

    @Test("ComposeRestart parses without arguments")
    func composeRestartParsesWithoutArgs() throws {
        let cmd = try ComposeRestart.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.composeFilename == nil)
        #expect(cmd.profile.isEmpty)
    }

    @Test("ComposeRestart parses with service name arguments")
    func composeRestartParsesWithServicesFilter() throws {
        let cmd = try ComposeRestart.parse(["api"])
        #expect(cmd.services == ["api"])
    }

    @Test("ComposeRestart parses --file flag")
    func composeRestartParsesFileFlag() throws {
        let cmd = try ComposeRestart.parse(["-f", "compose.yml"])
        #expect(cmd.composeFilename == "compose.yml")
    }

    @Test("ComposeRestart parses --profile flag")
    func composeRestartParsesProfileFlag() throws {
        let cmd = try ComposeRestart.parse(["--profile", "dev"])
        #expect(cmd.profile == ["dev"])
    }

    @Test("ComposeRestart parses multiple --profile flags")
    func composeRestartParsesMultipleProfileFlags() throws {
        let cmd = try ComposeRestart.parse(["--profile", "dev", "--profile", "local"])
        #expect(cmd.profile == ["dev", "local"])
    }

    @Test("ComposeRestart parses --file and --profile together")
    func composeRestartParsesFileAndProfile() throws {
        let cmd = try ComposeRestart.parse(["-f", "compose.dev.yml", "--profile", "dev"])
        #expect(cmd.composeFilename == "compose.dev.yml")
        #expect(cmd.profile == ["dev"])
    }
}
