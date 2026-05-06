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

@Suite("Remote runtime command wiring")
struct RemoteRuntimeWiringTests {

    @Test("compose start uses Runtime when remote mode is active")
    func startUsesRuntimeInRemoteMode() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            RuntimeContainer(
                id: "remoteproj-web",
                imageReference: "nginx:1",
                status: .created
            )
        ])

        try await RuntimeExecutionMode.$isRemote.withValue(true) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = ComposeStart()
                try await command.startServices(
                    [(serviceName: "web", service: Service(image: "nginx:1"))],
                    projectName: "remoteproj"
                )
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries == [.get(id: "remoteproj-web"), .start(id: "remoteproj-web")])
    }

    @Test("local-only system key commands fail clearly in remote mode")
    func systemListKeysRejectsRemoteMode() async throws {
        await #expect(throws: RuntimeError.notSupported(operation: "system list-keys", conformer: "RemoteRuntime")) {
            try await RuntimeExecutionMode.$isRemote.withValue(true) {
                let command = SystemListKeys()
                try await command.run()
            }
        }
    }

    @Test("compose up creates and starts image services through Runtime in remote mode")
    func upCreatesAndStartsRemoteRuntimeContainers() async throws {
        let runtime = RecordingRuntime()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "remote-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let composePath = dir.appending(path: "compose.yml")
        try """
        name: remoteup
        services:
          web:
            image: nginx:1
        """.write(to: composePath, atomically: true, encoding: .utf8)

        try await RuntimeExecutionMode.$isRemote.withValue(true) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeUp.parse([
                    "--file", composePath.path,
                    "--detach",
                ])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries == [
            .get(id: "remoteup-web"),
            .create(id: "remoteup-web"),
            .start(id: "remoteup-web"),
        ])
    }

    @Test("compose run creates, starts, waits, and removes one-off containers through Runtime in remote mode")
    func runUsesRuntimeInRemoteMode() async throws {
        let runtime = RecordingRuntime()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "remote-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let composePath = dir.appending(path: "compose.yml")
        try """
        name: remoterun
        services:
          web:
            image: alpine:3
        """.write(to: composePath, atomically: true, encoding: .utf8)

        try await RuntimeExecutionMode.$isRemote.withValue(true) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeRun.parse([
                    "--file", composePath.path,
                    "--name", "remoterun-web-run-test",
                    "--rm",
                    "web",
                    "echo",
                    "hi",
                ])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries == [
            .get(id: "remoterun-web-run-test"),
            .create(id: "remoterun-web-run-test"),
            .start(id: "remoterun-web-run-test"),
            .wait(id: "remoterun-web-run-test"),
            .remove(id: "remoterun-web-run-test", force: true),
        ])
    }

    @Test("compose exec uses Runtime in remote mode")
    func execUsesRuntimeInRemoteMode() async throws {
        let runtime = RecordingRuntime()
        let dir = try makeProjectDir(name: "remoteexec", image: "alpine:3")

        try await RuntimeExecutionMode.$isRemote.withValue(true) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeExec.parse([
                    "--file", dir.appending(path: "compose.yml").path,
                    "web",
                    "echo",
                    "hi",
                ])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries == [.exec(id: "remoteexec-web", command: ["echo", "hi"])])
    }

    @Test("compose top uses Runtime in remote mode")
    func topUsesRuntimeInRemoteMode() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            RuntimeContainer(id: "remotetop-web", imageReference: "alpine:3", status: .running)
        ])
        let dir = try makeProjectDir(name: "remotetop", image: "alpine:3")

        try await RuntimeExecutionMode.$isRemote.withValue(true) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposeTop.parse([
                    "--file", dir.appending(path: "compose.yml").path,
                ])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries == [.list, .processes(id: "remotetop-web")])
    }

    @Test("compose push uses Runtime in remote mode")
    func pushUsesRuntimeInRemoteMode() async throws {
        let runtime = RecordingRuntime()
        let dir = try makeProjectDir(name: "remotepush", image: "registry.example/web:1")

        try await RuntimeExecutionMode.$isRemote.withValue(true) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                var command = try ComposePush.parse([
                    "--file", dir.appending(path: "compose.yml").path,
                    "web",
                ])
                try await command.run()
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries == [.pushImage(reference: "registry.example/web:1")])
    }

    private func makeProjectDir(name: String, image: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let composePath = dir.appending(path: "compose.yml")
        try """
        name: \(name)
        services:
          web:
            image: \(image)
        """.write(to: composePath, atomically: true, encoding: .utf8)
        return dir
    }
}
