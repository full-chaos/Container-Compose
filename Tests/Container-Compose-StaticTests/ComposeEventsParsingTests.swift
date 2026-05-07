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

import Foundation
import Testing
@testable import ContainerComposeCore

@Suite("Compose Events Parsing Tests")
struct ComposeEventsParsingTests {

    @Test("ComposeEvents command parses without arguments")
    func composeEventsCommandParsesWithoutArguments() throws {
        let cmd = try ComposeEvents.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.json == false)
        #expect(cmd.composeFilename == nil)
    }

    @Test("--json flag parses")
    func jsonFlagParses() throws {
        let cmd = try ComposeEvents.parse(["--json"])
        #expect(cmd.json == true)
        #expect(cmd.services.isEmpty)
    }

    // CHAOS-1444: short alias for --json (project-ergonomic; docker-compose
    // upstream is long-only, but the project commits to this short for parity
    // with other CLIs that use `-j` for JSON output).
    @Test("-j short flag parses as json")
    func shortJFlagParsesAsJson() throws {
        let cmd = try ComposeEvents.parse(["-j"])
        #expect(cmd.json == true)
        #expect(cmd.services.isEmpty)
    }

    @Test("single service argument parses")
    func singleServiceArgumentParses() throws {
        let cmd = try ComposeEvents.parse(["web"])
        #expect(cmd.services == ["web"])
        #expect(cmd.json == false)
    }

    @Test("multiple service arguments parse")
    func multipleServiceArgumentsParse() throws {
        let cmd = try ComposeEvents.parse(["web", "db"])
        #expect(cmd.services == ["web", "db"])
        #expect(cmd.json == false)
    }

    @Test("--json combines with service filter")
    func jsonCombinesWithServiceFilter() throws {
        let cmd = try ComposeEvents.parse(["--json", "web"])
        #expect(cmd.json == true)
        #expect(cmd.services == ["web"])
    }
}
