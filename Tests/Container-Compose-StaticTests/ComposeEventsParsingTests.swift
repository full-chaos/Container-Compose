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

    @Test("polling diff emits create/start/stop/die/destroy events")
    func pollingDiffEmitsExpectedEvents() throws {
        let poller = EventStreamPoller()
        let previous = [
            EventStreamPoller.Snapshot(id: "demo-web", image: "nginx:latest", name: "demo-web", status: "stopped"),
            EventStreamPoller.Snapshot(id: "demo-old", image: "redis:latest", name: "demo-old", status: "running"),
        ]
        let current = [
            EventStreamPoller.Snapshot(id: "demo-web", image: "nginx:latest", name: "demo-web", status: "running"),
            EventStreamPoller.Snapshot(id: "demo-db", image: "postgres:16", name: "demo-db", status: "running"),
        ]

        let events = poller.diff(
            prev: previous,
            current: current,
            at: Date(timeIntervalSince1970: 0)
        )

        #expect(events.map(\.action) == ["create", "start", "die", "destroy", "start"])
        #expect(events.map(\.id) == ["demo-db", "demo-db", "demo-old", "demo-old", "demo-web"])
        #expect(events.allSatisfy { $0.timestamp == "1970-01-01T00:00:00Z" })
    }
}
