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

@Suite("Compose Logs Parsing Tests")
struct ComposeLogsTests {

    @Test("ComposeLogs parses with no arguments")
    func composeLogsNoArgs() throws {
        let cmd = try ComposeLogs.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.follow == false)
        #expect(cmd.tail == nil)
        #expect(cmd.since == nil)
        #expect(cmd.timestamps == false)
        #expect(cmd.noColor == false)
        #expect(cmd.file == nil)
    }

    @Test("ComposeLogs parses --follow flag (-f)")
    func composeLogsFollowShort() throws {
        let cmd = try ComposeLogs.parse(["-f"])
        #expect(cmd.follow == true)
    }

    @Test("ComposeLogs parses --follow flag (long form)")
    func composeLogsFollowLong() throws {
        let cmd = try ComposeLogs.parse(["--follow"])
        #expect(cmd.follow == true)
    }

    @Test("ComposeLogs parses --tail 100")
    func composeLogsTail100() throws {
        let cmd = try ComposeLogs.parse(["--tail", "100"])
        #expect(cmd.tail == "100")
    }

    @Test("ComposeLogs parses --tail all")
    func composeLogsTailAll() throws {
        let cmd = try ComposeLogs.parse(["--tail", "all"])
        #expect(cmd.tail == "all")
    }

    @Test("ComposeLogs parses --since 1h")
    func composeLogsSince1h() throws {
        let cmd = try ComposeLogs.parse(["--since", "1h"])
        #expect(cmd.since == "1h")
    }

    @Test("ComposeLogs parses --since timestamp")
    func composeLogsSinceTimestamp() throws {
        let cmd = try ComposeLogs.parse(["--since", "2025-01-01T00:00:00Z"])
        #expect(cmd.since == "2025-01-01T00:00:00Z")
    }

    @Test("ComposeLogs parses --no-color flag")
    func composeLogsNoColor() throws {
        let cmd = try ComposeLogs.parse(["--no-color"])
        #expect(cmd.noColor == true)
    }

    @Test("ComposeLogs parses --timestamps flag")
    func composeLogsTimestamps() throws {
        let cmd = try ComposeLogs.parse(["--timestamps"])
        #expect(cmd.timestamps == true)
    }

    @Test("ComposeLogs parses service name arguments")
    func composeLogsServiceArgs() throws {
        let cmd = try ComposeLogs.parse(["web", "db"])
        #expect(cmd.services == ["web", "db"])
    }

    @Test("ComposeLogs parses single service name")
    func composeLogsSingleService() throws {
        let cmd = try ComposeLogs.parse(["api"])
        #expect(cmd.services == ["api"])
    }

    @Test("ComposeLogs parses --file path (long form only)")
    func composeLogsFileLong() throws {
        let cmd = try ComposeLogs.parse(["--file", "/tmp/docker-compose.yml"])
        #expect(cmd.file == "/tmp/docker-compose.yml")
    }

    @Test("ComposeLogs parses combination of flags and services")
    func composeLogsCombined() throws {
        let cmd = try ComposeLogs.parse(["--follow", "--tail", "50", "--no-color", "web", "worker"])
        #expect(cmd.follow == true)
        #expect(cmd.tail == "50")
        #expect(cmd.noColor == true)
        #expect(cmd.services == ["web", "worker"])
    }
}
