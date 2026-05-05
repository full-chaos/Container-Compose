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
@testable import TestHelpers

@Suite("Runtime.build / Runtime.pull (CHAOS-1425, Leak #14)")
struct RuntimeBuildPullTests {

    // MARK: - Pull

    @Test("MockRuntime.pull emits started+completed per spec by default")
    func pull_default_startedCompletedPerSpec() async throws {
        let runtime = MockRuntime()
        let specs = [
            RuntimePullSpec(service: "web", imageReference: "nginx:1.27"),
            RuntimePullSpec(service: "db", imageReference: "postgres:16"),
        ]
        let stream = try await runtime.pull(specs: specs, ignoreFailures: false)

        var events: [RuntimePullEvent] = []
        for await event in stream { events.append(event) }

        #expect(events.count == 4)
        #expect(events[0].kind == .started)
        #expect(events[0].service == "web")
        #expect(events[1].kind == .completed)
        #expect(events[1].service == "web")
        #expect(events[2].kind == .started)
        #expect(events[2].service == "db")
        #expect(events[3].kind == .completed)
        #expect(events[3].service == "db")
    }

    @Test("MockRuntime.pull emits failed when injection matches and stops on ignoreFailures=false")
    func pull_failureStopsStream() async throws {
        let runtime = MockRuntime()
        await runtime.injectPullFailure(reference: "nginx:1.27", message: "registry unreachable")
        let specs = [
            RuntimePullSpec(service: "web", imageReference: "nginx:1.27"),
            RuntimePullSpec(service: "db", imageReference: "postgres:16"),
        ]
        let stream = try await runtime.pull(specs: specs, ignoreFailures: false)

        var events: [RuntimePullEvent] = []
        for await event in stream { events.append(event) }

        // started for web, failed for web, then break — db never starts
        #expect(events.count == 2)
        #expect(events[0].kind == .started)
        #expect(events[1].kind == .failed)
        #expect(events[1].message == "registry unreachable")
    }

    @Test("MockRuntime.pull continues past failure when ignoreFailures=true")
    func pull_ignoreFailuresContinues() async throws {
        let runtime = MockRuntime()
        await runtime.injectPullFailure(reference: "nginx:1.27", message: "boom")
        let specs = [
            RuntimePullSpec(service: "web", imageReference: "nginx:1.27"),
            RuntimePullSpec(service: "db", imageReference: "postgres:16"),
        ]
        let stream = try await runtime.pull(specs: specs, ignoreFailures: true)

        var kinds: [RuntimePullEvent.Kind] = []
        for await event in stream { kinds.append(event.kind) }

        #expect(kinds == [.started, .failed, .started, .completed])
    }

    @Test("MockRuntime.pull on empty specs finishes immediately with no events")
    func pull_emptySpecs() async throws {
        let runtime = MockRuntime()
        let stream = try await runtime.pull(specs: [], ignoreFailures: false)

        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }

    // MARK: - Build

    @Test("MockRuntime.build emits notSupported per spec by default")
    func build_default_notSupported() async throws {
        let runtime = MockRuntime()
        let specs = [
            RuntimeBuildSpec(service: "web"),
            RuntimeBuildSpec(service: "db"),
        ]
        let stream = try await runtime.build(specs: specs)

        var events: [RuntimeBuildEvent] = []
        for await event in stream { events.append(event) }

        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.kind == .notSupported })
        #expect(events[0].service == "web")
        #expect(events[1].service == "db")
    }

    @Test("MockRuntime.build with injected successful outcome emits started+completed")
    func build_injectedSuccess() async throws {
        let runtime = MockRuntime()
        await runtime.injectBuildOutcome(service: "web", outcome: .successful)
        let stream = try await runtime.build(specs: [RuntimeBuildSpec(service: "web")])

        var kinds: [RuntimeBuildEvent.Kind] = []
        for await event in stream { kinds.append(event.kind) }
        #expect(kinds == [.started, .completed])
    }

    @Test("MockRuntime.build with injected failure outcome emits started+failed")
    func build_injectedFailure() async throws {
        let runtime = MockRuntime()
        await runtime.injectBuildOutcome(service: "db", outcome: .failed(message: "missing Dockerfile"))
        let stream = try await runtime.build(specs: [RuntimeBuildSpec(service: "db")])

        var events: [RuntimeBuildEvent] = []
        for await event in stream { events.append(event) }

        #expect(events.count == 2)
        #expect(events[0].kind == .started)
        #expect(events[1].kind == .failed)
        #expect(events[1].message == "missing Dockerfile")
    }

    // MARK: - Type plumbing

    @Test("RuntimePullSpec.platform=nil signals defaultRuntimePlatform fallback")
    func pullSpec_platformNilDefaults() {
        let spec = RuntimePullSpec(service: "web", imageReference: "alpine:3")
        #expect(spec.platform == nil)
        #expect(spec.imageReference == "alpine:3")
        #expect(spec.service == "web")
    }

    @Test("RuntimeBuildSpec preserves all fields with sensible defaults")
    func buildSpec_defaults() {
        let bare = RuntimeBuildSpec(service: "web")
        #expect(bare.imageTag == nil)
        #expect(bare.contextPath == nil)
        #expect(bare.dockerfile == nil)
        #expect(bare.noCache == false)
        #expect(bare.pullBaseImages == false)

        let full = RuntimeBuildSpec(
            service: "web",
            imageTag: "myapp:latest",
            contextPath: "./web",
            dockerfile: "./web/Dockerfile",
            noCache: true,
            pullBaseImages: true
        )
        #expect(full.imageTag == "myapp:latest")
        #expect(full.contextPath == "./web")
        #expect(full.dockerfile == "./web/Dockerfile")
        #expect(full.noCache == true)
        #expect(full.pullBaseImages == true)
    }

    @Test("RuntimeBuildEvent.Kind.notSupported is the default daemon-side path until CHAOS-1426")
    func buildEvent_notSupportedKind() {
        let event = RuntimeBuildEvent(
            timestamp: Date(),
            service: "web",
            kind: .notSupported,
            message: "build context unavailable"
        )
        #expect(event.kind == .notSupported)
        #expect(event.message == "build context unavailable")
    }
}
