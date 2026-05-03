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
@Suite("ConfigsSecretsRuntime Tests", .serialized)
struct ConfigsSecretsRuntimeTests {

    // MARK: - Helpers

    /// Build an ArgsContext with the given service and DockerCompose.
    private func makeContext(
        service: Service,
        dockerCompose: DockerCompose,
        projectName: String = "testproject",
        serviceName: String = "svc"
    ) -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: serviceName,
            projectName: projectName,
            containerName: "\(projectName)-\(serviceName)",
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

    private func tempProjectName(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }

    private func configsSecretsDir(projectName: String) -> URL {
        URL(fileURLWithPath: NSString(string: "~/.containers/Compose/\(projectName)/configs-secrets").expandingTildeInPath, isDirectory: true)
    }

    private func volumeMounts(from args: [String]) -> [String] {
        args.indices.compactMap { index in
            guard args[index] == "-v", args.indices.contains(index + 1) else {
                return nil
            }

            return args[index + 1]
        }
    }

    private func hostPath(from mount: String) -> String {
        mount.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
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

    @Test("Config file source still emits expected -v arg")
    func fileSourceStillEmitsExpectedVolumeArg() {
        let sc = ServiceConfig(source: "file_cfg", target: "/etc/file_cfg")
        let topConfig = Config(file: "~/configs/file_cfg")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["file_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let mounts = volumeMounts(from: args)
        #expect(mounts.count == 1)
        let expectedHost = NSString(string: "~/configs/file_cfg").expandingTildeInPath
        #expect(mounts.first == "\(expectedHost):/etc/file_cfg")
    }

    @Test("Config without template_driver keeps raw file mount")
    func configWithoutTemplateDriverKeepsRawFileMount() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "cfg-no-driver-\(UUID().uuidString)")
        try "hello {{ .USER }}".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let sc = ServiceConfig(source: "raw_cfg", target: "/etc/raw")
        let topConfig = Config(file: file.path)
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["raw_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        #expect(volumeMounts(from: args).first == "\(file.path):/etc/raw")
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello {{ .USER }}")
    }

    @Test("Config content source writes content-addressed temp file")
    func configContentSourceWritesTempFile() throws {
        let projectName = tempProjectName("cfg-content")
        let dir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sc = ServiceConfig(source: "inline_cfg", target: "/etc/inline_cfg")
        let topConfig = Config(content: "hello-from-content")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["inline_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc, projectName: projectName)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let mount = try #require(volumeMounts(from: args).first)
        let tempPath = hostPath(from: mount)
        #expect(tempPath.hasPrefix(dir.path + "/"))
        #expect(URL(fileURLWithPath: tempPath).lastPathComponent.hasPrefix("config-inline_cfg-"))
        #expect(URL(fileURLWithPath: tempPath).lastPathComponent.split(separator: "-").last?.count == 12)
        #expect(mount == "\(tempPath):/etc/inline_cfg")
        #expect(FileManager.default.fileExists(atPath: tempPath))
        #expect(try String(contentsOfFile: tempPath, encoding: .utf8) == "hello-from-content")
    }

    @Test("Config environment source writes host env value to temp file")
    func configEnvironmentSourceWritesTempFile() throws {
        let projectName = tempProjectName("cfg-env")
        let dir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let envName = "PHASE3_CFG_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(envName, "hello-from-env", 1)
        defer { unsetenv(envName) }

        let sc = ServiceConfig(source: "env_cfg", target: "/etc/env_cfg")
        let topConfig = Config(environment: envName)
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["env_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc, projectName: projectName)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let mount = try #require(volumeMounts(from: args).first)
        let tempPath = hostPath(from: mount)
        #expect(tempPath.hasPrefix(dir.path + "/"))
        #expect(URL(fileURLWithPath: tempPath).lastPathComponent.hasPrefix("config-env_cfg-"))
        #expect(mount == "\(tempPath):/etc/env_cfg")
        #expect(FileManager.default.fileExists(atPath: tempPath))
        #expect(try String(contentsOfFile: tempPath, encoding: .utf8) == "hello-from-env")
    }

    @Test("Config template_driver file keeps raw file mount")
    func configTemplateDriverFileKeepsRawFileMount() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "cfg-file-driver-\(UUID().uuidString)")
        try "hello {{ .HOSTNAME }}".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let sc = ServiceConfig(source: "raw_cfg", target: "/etc/raw")
        let topConfig = Config(file: file.path, templateDriver: "file")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["raw_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        #expect(volumeMounts(from: args).first == "\(file.path):/etc/raw")
        #expect(try String(contentsOf: file, encoding: .utf8) == "hello {{ .HOSTNAME }}")
    }

    @Test("Config template_driver golang renders dotted env lookup")
    func configTemplateDriverGolangRendersDottedEnvLookup() throws {
        let projectName = tempProjectName("cfg-template")
        let dir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = getenv("HOSTNAME").map { String(cString: $0) }
        setenv("HOSTNAME", "compose-host", 1)
        defer {
            if let previous { setenv("HOSTNAME", previous, 1) } else { unsetenv("HOSTNAME") }
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "cfg-golang-driver-\(UUID().uuidString)")
        try "host={{ .HOSTNAME }}".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let sc = ServiceConfig(source: "rendered_cfg", target: "/etc/rendered")
        let topConfig = Config(file: file.path, templateDriver: "golang")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["rendered_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc, projectName: projectName)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let mount = try #require(volumeMounts(from: args).first)
        let tempPath = hostPath(from: mount)
        #expect(tempPath.hasPrefix(dir.path + "/"))
        #expect(URL(fileURLWithPath: tempPath).lastPathComponent.hasPrefix("config-rendered-rendered_cfg-"))
        #expect(mount == "\(tempPath):/etc/rendered")
        #expect(try String(contentsOfFile: tempPath, encoding: .utf8) == "host=compose-host")
    }

    @Test("Config template_driver golang renders inline content source")
    func configTemplateDriverGolangRendersInlineContentSource() throws {
        let projectName = tempProjectName("cfg-template-inline")
        let dir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = getenv("USER").map { String(cString: $0) }
        setenv("USER", "alice", 1)
        defer {
            if let previous { setenv("USER", previous, 1) } else { unsetenv("USER") }
        }

        let sc = ServiceConfig(source: "inline_template_cfg", target: "/etc/inline")
        let topConfig = Config(content: "hello {{ .USER }}", templateDriver: "golang")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["inline_template_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc, projectName: projectName)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let mount = try #require(volumeMounts(from: args).first)
        let tempPath = hostPath(from: mount)
        #expect(tempPath.hasPrefix(dir.path + "/"))
        #expect(URL(fileURLWithPath: tempPath).lastPathComponent.hasPrefix("config-rendered-inline_template_cfg-"))
        #expect(try String(contentsOfFile: tempPath, encoding: .utf8) == "hello alice")
    }

    @Test("Config template_driver golang renders environment source")
    func configTemplateDriverGolangRendersEnvironmentSource() throws {
        let projectName = tempProjectName("cfg-template-env")
        let dir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceEnvName = "CHAOS_TEMPLATE_SOURCE_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let previousUser = getenv("USER").map { String(cString: $0) }
        setenv(sourceEnvName, "hello {{ .USER }}", 1)
        setenv("USER", "alice", 1)
        defer {
            unsetenv(sourceEnvName)
            if let previousUser { setenv("USER", previousUser, 1) } else { unsetenv("USER") }
        }

        let sc = ServiceConfig(source: "env_template_cfg", target: "/etc/env")
        let topConfig = Config(environment: sourceEnvName, templateDriver: "golang")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["env_template_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc, projectName: projectName)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let mount = try #require(volumeMounts(from: args).first)
        let tempPath = hostPath(from: mount)
        #expect(tempPath.hasPrefix(dir.path + "/"))
        #expect(URL(fileURLWithPath: tempPath).lastPathComponent.hasPrefix("config-rendered-env_template_cfg-"))
        #expect(try String(contentsOfFile: tempPath, encoding: .utf8) == "hello alice")
    }

    @Test("Config template_driver golang renders missing env as empty")
    func configTemplateDriverGolangMissingEnvRendersEmpty() throws {
        let projectName = tempProjectName("cfg-template-missing")
        let dir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let envName = "CHAOS_TEMPLATE_MISSING_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        unsetenv(envName)

        let sc = ServiceConfig(source: "missing_cfg", target: "/etc/missing")
        let topConfig = Config(content: "missing={{ .\(envName) }}", templateDriver: "golang")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["missing_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc, projectName: projectName)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let mount = try #require(volumeMounts(from: args).first)
        let tempPath = hostPath(from: mount)
        #expect(tempPath.hasPrefix(dir.path + "/"))
        #expect(URL(fileURLWithPath: tempPath).lastPathComponent.hasPrefix("config-rendered-missing_cfg-"))
        #expect(try String(contentsOfFile: tempPath, encoding: .utf8) == "missing=")
    }

    @Test("Config template_driver golang renders env function from host env")
    func configTemplateDriverGolangRendersEnvFunctionFromHostEnv() throws {
        let projectName = tempProjectName("cfg-template-host-env")
        let dir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let envName = "CHAOS_TEMPLATE_HOST_ENV_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(envName, "from-host-env", 1)
        defer { unsetenv(envName) }

        let sc = ServiceConfig(source: "project_env_cfg", target: "/etc/project-env")
        let topConfig = Config(content: "value={{ env \"\(envName)\" }}", templateDriver: "golang")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["project_env_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc, projectName: projectName)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let mount = try #require(volumeMounts(from: args).first)
        let tempPath = hostPath(from: mount)
        #expect(tempPath.hasPrefix(dir.path + "/"))
        #expect(try String(contentsOfFile: tempPath, encoding: .utf8) == "value=from-host-env")
    }

    @Test("Config unknown template_driver keeps raw source")
    func configUnknownTemplateDriverKeepsRawSource() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "cfg-unknown-driver-\(UUID().uuidString)")
        try "hello {{ .HOSTNAME }}".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let sc = ServiceConfig(source: "unknown_cfg", target: "/etc/unknown")
        let topConfig = Config(file: file.path, templateDriver: "mustache")
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["unknown_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        #expect(volumeMounts(from: args).first == "\(file.path):/etc/unknown")
    }

    @Test("Missing config environment source skips mount")
    func missingConfigEnvironmentSkipsMount() {
        let envName = "PHASE3_MISSING_CFG_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        unsetenv(envName)
        let sc = ServiceConfig(source: "missing_env_cfg", target: "/etc/missing")
        let topConfig = Config(environment: envName)
        let service = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["missing_env_cfg": topConfig])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        #expect(!args.contains("-v"))
    }

    @Test("Two services sharing content source reuse one temp file")
    func sharedContentSourceReusesTempFileWithoutRewrite() throws {
        let projectName = tempProjectName("cfg-shared")
        let dir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sc = ServiceConfig(source: "shared_cfg", target: "/etc/shared")
        let topConfig = Config(content: "shared-content")
        let firstService = Service(image: "alpine:latest", configs: [sc])
        let secondService = Service(image: "alpine:latest", configs: [sc])
        let dc = makeDockerCompose(configs: ["shared_cfg": topConfig])
        let firstCtx = makeContext(service: firstService, dockerCompose: dc, projectName: projectName, serviceName: "web")
        let secondCtx = makeContext(service: secondService, dockerCompose: dc, projectName: projectName, serviceName: "worker")

        let firstArgs = ComposeUp.ConfigsSecretsArgs.build(firstCtx)
        let firstMount = try #require(volumeMounts(from: firstArgs).first)
        let firstPath = hostPath(from: firstMount)
        try "preserve-existing-file".write(toFile: firstPath, atomically: true, encoding: .utf8)

        let secondArgs = ComposeUp.ConfigsSecretsArgs.build(secondCtx)
        let secondMount = try #require(volumeMounts(from: secondArgs).first)
        let secondPath = hostPath(from: secondMount)

        #expect(firstPath == secondPath)
        #expect(try String(contentsOfFile: secondPath, encoding: .utf8) == "preserve-existing-file")
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

    @Test("Secret environment source writes host env value to temp file")
    func secretEnvironmentSourceWritesTempFile() throws {
        let projectName = tempProjectName("secret-env")
        let dir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let envName = "PHASE3_SECRET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(envName, "super-secret-value", 1)
        defer { unsetenv(envName) }

        let ss = ServiceSecret(source: "env_secret")
        let topSecret = Secret(environment: envName)
        let service = Service(image: "alpine:latest", secrets: [ss])
        let dc = makeDockerCompose(secrets: ["env_secret": topSecret])
        let ctx = makeContext(service: service, dockerCompose: dc, projectName: projectName)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let mount = try #require(volumeMounts(from: args).first)
        let tempPath = hostPath(from: mount)
        #expect(tempPath.hasPrefix(dir.path + "/"))
        #expect(URL(fileURLWithPath: tempPath).lastPathComponent.hasPrefix("secret-env_secret-"))
        #expect(mount == "\(tempPath):/run/secrets/env_secret")
        #expect(FileManager.default.fileExists(atPath: tempPath))
        #expect(try String(contentsOfFile: tempPath, encoding: .utf8) == "super-secret-value")
    }

    @Test("Secret template_driver golang renders env function")
    func secretTemplateDriverGolangRendersEnvFunction() throws {
        let projectName = tempProjectName("secret-template")
        let dir = configsSecretsDir(projectName: projectName)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let envName = "CHAOS_TEMPLATE_SECRET_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(envName, "rendered-secret", 1)
        defer { unsetenv(envName) }
        let file = FileManager.default.temporaryDirectory.appending(path: "secret-golang-driver-\(UUID().uuidString)")
        try "secret={{ env \"\(envName)\" }}".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let ss = ServiceSecret(source: "templated_secret", target: "/run/secrets/rendered")
        let topSecret = Secret(file: file.path, templateDriver: "golang")
        let service = Service(image: "alpine:latest", secrets: [ss])
        let dc = makeDockerCompose(secrets: ["templated_secret": topSecret])
        let ctx = makeContext(service: service, dockerCompose: dc, projectName: projectName)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        let mount = try #require(volumeMounts(from: args).first)
        let tempPath = hostPath(from: mount)
        #expect(tempPath.hasPrefix(dir.path + "/"))
        #expect(URL(fileURLWithPath: tempPath).lastPathComponent.hasPrefix("secret-rendered-templated_secret-"))
        #expect(mount == "\(tempPath):/run/secrets/rendered")
        #expect(try String(contentsOfFile: tempPath, encoding: .utf8) == "secret=rendered-secret")
    }

    @Test("Secret unknown template_driver keeps raw source")
    func secretUnknownTemplateDriverKeepsRawSource() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "secret-unknown-driver-\(UUID().uuidString)")
        try "secret={{ .USER }}".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let ss = ServiceSecret(source: "unknown_secret", target: "/run/secrets/unknown")
        let topSecret = Secret(file: file.path, templateDriver: "jinja")
        let service = Service(image: "alpine:latest", secrets: [ss])
        let dc = makeDockerCompose(secrets: ["unknown_secret": topSecret])
        let ctx = makeContext(service: service, dockerCompose: dc)

        let args = ComposeUp.ConfigsSecretsArgs.build(ctx)

        #expect(volumeMounts(from: args).first == "\(file.path):/run/secrets/unknown")
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
