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

/// Tests for Phase 5A — service-level configs and secrets mounted as bind mounts.
@Suite("ConfigsSecretsRuntime Tests")
struct ConfigsSecretsRuntimeTests {

    // MARK: - Helpers

    /// Build an ArgsContext with the given service and DockerCompose.
    private func makeContext(service: Service, dockerCompose: DockerCompose) -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "testproject",
            containerName: "testproject-svc",
            detach: false,
            environmentVariables: [:],
            dockerCompose: dockerCompose,
            composeFilename: nil
        )
    }

    /// Build a minimal DockerCompose with the specified top-level configs and secrets.
    private func makeDockerCompose(
        configs: [String: Config?]? = nil,
        secrets: [String: Secret?]? = nil
    ) -> DockerCompose {
        DockerCompose(
            version: nil,
            name: nil,
            services: ["svc": Service(image: "alpine:latest")],
            volumes: nil,
            networks: nil,
            configs: configs,
            secrets: secrets
        )
    }

    // MARK: - Configs

    @Test("Config with explicit target emits -v hostPath:target")
    func configWithExplicitTarget() {
        let sc = ServiceConfig(source: "myconfig", target: "/etc/myconfig.conf")
        let topConfig = Config(file: "/host/path/myconfig.conf")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["myconfig": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let vIndices = args.indices.filter { args[$0] == "-v" }
        #expect(vIndices.count == 1)
        let mountVal = args[vIndices[0] + 1]
        #expect(mountVal == "/host/path/myconfig.conf:/etc/myconfig.conf")
    }

    @Test("Config without target defaults to /<source>")
    func configDefaultTarget() {
        let sc = ServiceConfig(source: "appconfig")
        let topConfig = Config(file: "/host/configs/appconfig")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["appconfig": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let vIndices = args.indices.filter { args[$0] == "-v" }
        #expect(vIndices.count == 1)
        let mountVal = args[vIndices[0] + 1]
        #expect(mountVal == "/host/configs/appconfig:/appconfig")
    }

    @Test("External config skips mount and emits no -v flag")
    func externalConfigSkipsMount() {
        let sc = ServiceConfig(source: "extcfg")
        let extConfig = Config(file: nil, external: ExternalConfig(isExternal: true, name: nil))
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["extcfg": extConfig])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)
        #expect(!args.contains("-v"))
    }

    @Test("Config not in top-level map skips mount")
    func configMissingFromTopLevel() {
        let sc = ServiceConfig(source: "ghost")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: [:])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)
        #expect(!args.contains("-v"))
    }

    @Test("Config with no file field skips mount")
    func configWithNoFileSkipsMount() {
        let sc = ServiceConfig(source: "nofile")
        let topConfig = Config(file: nil)
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["nofile": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)
        #expect(!args.contains("-v"))
    }

    // MARK: - Secrets

    @Test("Secret with explicit target emits -v hostPath:target")
    func secretWithExplicitTarget() {
        let ss = ServiceSecret(source: "dbpass", target: "/run/secrets/db_password")
        let topSecret = Secret(file: "/host/secrets/dbpass.txt")
        let service = Service(image: "alpine:latest", secrets: [ss])
        let dc = makeDockerCompose(secrets: ["dbpass": topSecret])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let vIndices = args.indices.filter { args[$0] == "-v" }
        #expect(vIndices.count == 1)
        let mountVal = args[vIndices[0] + 1]
        #expect(mountVal == "/host/secrets/dbpass.txt:/run/secrets/db_password")
    }

    @Test("Secret without target defaults to /run/secrets/<source>")
    func secretDefaultTarget() {
        let ss = ServiceSecret(source: "apikey")
        let topSecret = Secret(file: "/host/secrets/apikey")
        let service = Service(image: "alpine:latest", secrets: [ss])
        let dc = makeDockerCompose(secrets: ["apikey": topSecret])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let vIndices = args.indices.filter { args[$0] == "-v" }
        #expect(vIndices.count == 1)
        let mountVal = args[vIndices[0] + 1]
        #expect(mountVal == "/host/secrets/apikey:/run/secrets/apikey")
    }

    @Test("External secret skips mount and emits no -v flag")
    func externalSecretSkipsMount() {
        let ss = ServiceSecret(source: "extsec")
        let extSecret = Secret(file: nil, external: ExternalSecret(isExternal: true, name: nil))
        let service = Service(image: "alpine:latest", secrets: [ss])
        let dc = makeDockerCompose(secrets: ["extsec": extSecret])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)
        #expect(!args.contains("-v"))
    }

    @Test("Secret not in top-level map skips mount")
    func secretMissingFromTopLevel() {
        let ss = ServiceSecret(source: "phantom")
        let service = Service(image: "alpine:latest", secrets: [ss])
        let dc = makeDockerCompose(secrets: [:])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)
        #expect(!args.contains("-v"))
    }

    // MARK: - Tilde expansion

    @Test("Secret file with tilde path is expanded to absolute path")
    func secretTildeExpansion() {
        let ss = ServiceSecret(source: "tildesecret")
        let topSecret = Secret(file: "~/secrets/mykey")
        let service = Service(image: "alpine:latest", secrets: [ss])
        let dc = makeDockerCompose(secrets: ["tildesecret": topSecret])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let vIndices = args.indices.filter { args[$0] == "-v" }
        #expect(vIndices.count == 1)
        let mountVal = args[vIndices[0] + 1]
        // The host path should be an absolute path (tilde expanded), not start with ~
        let hostPath = mountVal.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        #expect(!hostPath.hasPrefix("~"))
        #expect(hostPath.hasPrefix("/"))
    }

    // MARK: - Multiple entries

    @Test("Multiple configs emit one -v per config in order")
    func multipleConfigsEmitInOrder() {
        let sc1 = ServiceConfig(source: "cfg1", target: "/etc/cfg1.conf")
        let sc2 = ServiceConfig(source: "cfg2", target: "/etc/cfg2.conf")
        let service = Service(image: "alpine:latest", configs: [sc1, sc2])
        let dc = makeDockerCompose(configs: [
            "cfg1": Config(file: "/host/cfg1"),
            "cfg2": Config(file: "/host/cfg2")
        ])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let vIndices = args.indices.filter { args[$0] == "-v" }
        #expect(vIndices.count == 2)
        #expect(args[vIndices[0] + 1] == "/host/cfg1:/etc/cfg1.conf")
        #expect(args[vIndices[1] + 1] == "/host/cfg2:/etc/cfg2.conf")
    }

    @Test("Multiple secrets emit one -v per secret in order")
    func multipleSecretsEmitInOrder() {
        let ss1 = ServiceSecret(source: "sec1")
        let ss2 = ServiceSecret(source: "sec2")
        let service = Service(image: "alpine:latest", secrets: [ss1, ss2])
        let dc = makeDockerCompose(secrets: [
            "sec1": Secret(file: "/host/sec1"),
            "sec2": Secret(file: "/host/sec2")
        ])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let vIndices = args.indices.filter { args[$0] == "-v" }
        #expect(vIndices.count == 2)
        #expect(args[vIndices[0] + 1] == "/host/sec1:/run/secrets/sec1")
        #expect(args[vIndices[1] + 1] == "/host/sec2:/run/secrets/sec2")
    }

    @Test("Mixed configs and secrets each emit their -v entries")
    func mixedConfigsAndSecrets() {
        let sc = ServiceConfig(source: "cfg1", target: "/etc/cfg.conf")
        let ss = ServiceSecret(source: "sec1")
        let service = Service(image: "alpine:latest", configs: [sc], secrets: [ss])
        let dc = makeDockerCompose(
            configs: ["cfg1": Config(file: "/host/cfg1")],
            secrets: ["sec1": Secret(file: "/host/sec1")]
        )
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let vIndices = args.indices.filter { args[$0] == "-v" }
        #expect(vIndices.count == 2)
        let mounts = vIndices.map { args[$0 + 1] }
        #expect(mounts.contains("/host/cfg1:/etc/cfg.conf"))
        #expect(mounts.contains("/host/sec1:/run/secrets/sec1"))
    }

    @Test("No configs or secrets produces empty args")
    func noConfigsOrSecretsProducesEmpty() {
        let service = Service(image: "alpine:latest")
        let dc = makeDockerCompose()
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)
        #expect(args.isEmpty)
    }
}
