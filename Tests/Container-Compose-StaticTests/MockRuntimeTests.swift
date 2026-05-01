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

import Foundation
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite("MockRuntime state machine")
struct MockRuntimeTests {

    @Test("create then start updates list() state")
    func createStartListReflectsState() async throws {
        let runtime = MockRuntime()

        let created = try await runtime.create(
            id: "demo-web-1",
            configuration: RuntimeCreateConfiguration(imageReference: "nginx:1")
        )
        #expect(created.status == .created)

        try await runtime.start(id: "demo-web-1")

        let listed = try await runtime.list(filters: .all)
        #expect(listed.map(\.id) == ["demo-web-1"])
        #expect(listed.first?.status == .running)
        #expect(listed.first?.startedAt != nil)

        let snapshot = await runtime.snapshot()
        #expect(snapshot["demo-web-1"]?.status == .running)
    }

    @Test("events stream emits lifecycle transitions in order")
    func eventsEmitOrderedLifecycleTransitions() async throws {
        let runtime = MockRuntime()
        let stream = try await runtime.events()
        let collector = Task {
            var events: [RuntimeContainerEvent] = []
            for await event in stream {
                events.append(event)
                if events.count == 3 { break }
            }
            return events
        }

        _ = try await runtime.create(
            id: "demo-web-1",
            configuration: RuntimeCreateConfiguration(imageReference: "nginx:1")
        )
        try await runtime.start(id: "demo-web-1")
        try await runtime.stop(id: "demo-web-1", options: .default)

        let events = await collector.value
        #expect(events.count == 3)
        guard events.count == 3 else { return }
        guard case .created(let createdID, _) = events[0] else {
            Issue.record("expected .created, got \(events[0])")
            return
        }
        guard case .started(let startedID, _) = events[1] else {
            Issue.record("expected .started, got \(events[1])")
            return
        }
        guard case .stopped(let stoppedID, let exitCode, _) = events[2] else {
            Issue.record("expected .stopped, got \(events[2])")
            return
        }
        #expect(createdID == "demo-web-1")
        #expect(startedID == "demo-web-1")
        #expect(stoppedID == "demo-web-1")
        #expect(exitCode == 0)
    }

    @Test("logs replay history then follow live frames")
    func logsReplayThenFollow() async throws {
        let runtime = MockRuntime()
        _ = try await runtime.create(
            id: "demo-web-1",
            configuration: RuntimeCreateConfiguration(imageReference: "nginx:1")
        )

        let first = Self.frame("first", timestamp: Date(timeIntervalSince1970: 1))
        let second = Self.frame("second", timestamp: Date(timeIntervalSince1970: 2), source: .stderr)
        await runtime.injectLogFrame(first, forContainerID: "demo-web-1")
        await runtime.injectLogFrame(second, forContainerID: "demo-web-1")

        let replay = try await runtime.logs(id: "demo-web-1", options: .default)
        var replayed: [RuntimeLogFrame] = []
        for await frame in replay {
            replayed.append(frame)
        }
        #expect(replayed.map(Self.string) == ["first", "second"])

        let follow = try await runtime.logs(
            id: "demo-web-1",
            options: RuntimeLogOptions(follow: true, tail: nil, since: nil)
        )
        let collector = Task {
            var frames: [RuntimeLogFrame] = []
            for await frame in follow {
                frames.append(frame)
                if frames.count == 3 { break }
            }
            return frames
        }

        await runtime.injectLogFrame(
            Self.frame("third", timestamp: Date(timeIntervalSince1970: 3)),
            forContainerID: "demo-web-1"
        )

        let followed = await collector.value
        #expect(followed.map(Self.string) == ["first", "second", "third"])
    }

    private static func frame(
        _ string: String,
        timestamp: Date,
        source: RuntimeLogFrame.Source = .stdout
    ) -> RuntimeLogFrame {
        RuntimeLogFrame(timestamp: timestamp, source: source, data: Data(string.utf8))
    }

    private static func string(_ frame: RuntimeLogFrame) -> String {
        String(decoding: frame.data, as: UTF8.self)
    }
}
