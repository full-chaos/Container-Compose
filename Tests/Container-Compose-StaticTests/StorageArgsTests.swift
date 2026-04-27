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
@testable import Yams
@testable import ContainerComposeCore

@Suite("StorageArgs Tests")
struct StorageArgsTests {

    // MARK: - Helpers

    private func makeDockerCompose() throws -> DockerCompose {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        return try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    private func makeContext(service: Service, envVars: [String: String] = [:]) throws -> ComposeUp.ArgsContext {
        let dockerCompose = try makeDockerCompose()
        return ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "testproject",
            containerName: "testproject-svc-1",
            detach: false,
            environmentVariables: envVars,
            dockerCompose: dockerCompose,
            composeFilename: nil
        )
    }

    // MARK: - working_dir (regression)

    @Test("working_dir emits --workdir flag")
    func workingDirEmitsFlag() throws {
        let service = Service(image: "alpine:latest", working_dir: "/app")
        let ctx = try makeContext(service: service)
        let args = ComposeUp.StorageArgs.build(ctx)
        #expect(args.contains("--workdir"))
        let idx = try #require(args.firstIndex(of: "--workdir"))
        #expect(args[idx + 1] == "/app")
    }

    @Test("working_dir with VAR substitution resolves correctly")
    func workingDirVarSubstitution() throws {
        let service = Service(image: "alpine:latest", working_dir: "${APP_DIR}")
        let ctx = try makeContext(service: service, envVars: ["APP_DIR": "/resolved/path"])
        let args = ComposeUp.StorageArgs.build(ctx)
        let idx = try #require(args.firstIndex(of: "--workdir"))
        #expect(args[idx + 1] == "/resolved/path")
    }

    // MARK: - tmpfs

    @Test("tmpfs list emits multiple --tmpfs flags")
    func tmpfsEmitsFlags() throws {
        let service = Service(image: "alpine:latest", tmpfs: ["/tmp", "/run"])
        let ctx = try makeContext(service: service)
        let args = ComposeUp.StorageArgs.build(ctx)
        let indices = args.indices.filter { args[$0] == "--tmpfs" }
        #expect(indices.count == 2)
        let paths = indices.map { args[$0 + 1] }
        #expect(paths.contains("/tmp"))
        #expect(paths.contains("/run"))
    }

    @Test("empty tmpfs list emits no --tmpfs flags")
    func emptyTmpfsEmitsNoFlags() throws {
        let service = Service(image: "alpine:latest", tmpfs: [])
        let ctx = try makeContext(service: service)
        let args = ComposeUp.StorageArgs.build(ctx)
        #expect(!args.contains("--tmpfs"))
    }

    // MARK: - sysctls

    @Test("sysctls map emits multiple --sysctl flags")
    func sysctlsEmitsFlags() throws {
        let service = Service(image: "alpine:latest", sysctls: [
            "net.ipv4.ip_forward": "1",
            "net.core.somaxconn": "1024"
        ])
        let ctx = try makeContext(service: service)
        let args = ComposeUp.StorageArgs.build(ctx)
        let indices = args.indices.filter { args[$0] == "--sysctl" }
        #expect(indices.count == 2)
        let kvPairs = indices.map { args[$0 + 1] }
        #expect(kvPairs.contains("net.ipv4.ip_forward=1"))
        #expect(kvPairs.contains("net.core.somaxconn=1024"))
    }

    // MARK: - devices

    @Test("devices list emits multiple --device flags")
    func devicesEmitsFlags() throws {
        let service = Service(image: "alpine:latest", devices: [
            "/dev/ttyUSB0:/dev/ttyUSB0",
            "/dev/snd:/dev/snd:rw"
        ])
        let ctx = try makeContext(service: service)
        let args = ComposeUp.StorageArgs.build(ctx)
        let indices = args.indices.filter { args[$0] == "--device" }
        #expect(indices.count == 2)
        let mappings = indices.map { args[$0 + 1] }
        #expect(mappings.contains("/dev/ttyUSB0:/dev/ttyUSB0"))
        #expect(mappings.contains("/dev/snd:/dev/snd:rw"))
    }

    // MARK: - warn-and-skip: volumes_from

    @Test("volumes_from non-empty emits no flags")
    func volumesFromEmitsNoFlags() throws {
        let service = Service(image: "alpine:latest", volumes_from: ["other-service", "another:ro"])
        let ctx = try makeContext(service: service)
        let args = ComposeUp.StorageArgs.build(ctx)
        #expect(!args.contains("--volumes-from"))
        #expect(!args.contains("--volumes_from"))
    }

    // MARK: - nil cases produce no flags

    @Test("nil storage fields produce no extra flags")
    func nilStorageFieldsProduceNoFlags() throws {
        let service = Service(image: "alpine:latest")
        let ctx = try makeContext(service: service)
        let args = ComposeUp.StorageArgs.build(ctx)
        #expect(args.isEmpty)
    }
}
