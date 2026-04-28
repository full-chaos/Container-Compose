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
import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
@testable import ContainerComposeCore
import TestHelpers

@Suite("Compose Top Runtime Argv Tests")
struct ComposeTopRuntimeArgvTests {

    private func writeTempCompose(_ yaml: String) throws -> (dir: URL, compose: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let compose = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: compose, atomically: true, encoding: .utf8)
        return (dir, compose)
    }

    @Test("top: shells out to container exec ps -ef for running service container")
    func top_shells_out_to_container_exec_ps() async throws {
        let yaml = """
        name: myproj
        services:
          web:
            image: nginx:alpine
          db:
            image: postgres:14
        """
        let (dir, compose) = try writeTempCompose(yaml)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = RecordingRunner()
        let containerProvider = TopTestContainerProvider(containers: [
            Self.snapshot(id: "myproj-web", status: .running),
            Self.snapshot(id: "myproj-db", status: .running),
        ])

        try await RunnerEnvironment.$current.withValue(recorder) {
            try await ContainerClientEnvironment.$current.withValue(containerProvider) {
                var cmd = try ComposeTop.parse(["-f", compose.path, "web"])
                try await cmd.run()
            }
        }

        let argvs = await recorder.argvs()
        #expect(
            argvs.contains(["container", "exec", "myproj-web", "ps", "-ef"]),
            "expected compose top to shell out through container exec ps -ef (got: \(argvs))"
        )
        #expect(
            !argvs.contains(["container", "exec", "myproj-db", "ps", "-ef"]),
            "service filter should exclude non-requested services (got: \(argvs))"
        )
    }

    private static func snapshot(id: String, status: RuntimeStatus) -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            size: 0
        )
        let image = ImageDescription(reference: id, descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "true"],
            environment: []
        )
        let configuration = ContainerConfiguration(id: id, image: image, process: process)
        return ContainerSnapshot(
            configuration: configuration,
            status: status,
            networks: []
        )
    }
}

// MARK: - Test-only ContainerClientProvider for ComposeTopRuntimeArgvTests

private actor TopTestContainerProvider: ContainerClientProvider {
    private let containers: [ContainerSnapshot]

    init(containers: [ContainerSnapshot]) {
        self.containers = containers
    }

    func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] { containers }

    func get(id: String) async throws -> ContainerSnapshot {
        throw NSError(
            domain: "TopTestContainerProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no container '\(id)'"]
        )
    }

    func stop(id: String, opts: ContainerStopOptions) async throws {}
    func delete(id: String, force: Bool) async throws {}
    func logs(id: String) async throws -> [FileHandle] { [] }

    func networkGet(id: String) async throws -> NetworkState {
        throw NSError(
            domain: "TopTestContainerProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no network '\(id)'"]
        )
    }

    func imageList() async throws -> [ClientImage] { [] }
}
