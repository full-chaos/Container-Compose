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

/// Tests for niche secret and config fields per compose-spec (CHAOS-1306).
@Suite("Secret and Config niche field parsing")
struct SecretConfigNicheTests {

    // MARK: - Secret.driver_opts

    @Test("Secret driver_opts is decoded from YAML map")
    func secretDriverOptsDecoded() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            secrets:
              - mysecret
        secrets:
          mysecret:
            file: ./secret.txt
            driver_opts:
              opt1: value1
              opt2: value2
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let secret = try #require(compose.secrets?["mysecret"] ?? nil)
        #expect(secret.driverOpts?["opt1"] == "value1")
        #expect(secret.driverOpts?["opt2"] == "value2")
    }

    @Test("Secret driver_opts is nil when absent")
    func secretDriverOptsNilWhenAbsent() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            secrets:
              - mysecret
        secrets:
          mysecret:
            file: ./secret.txt
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let secret = try #require(compose.secrets?["mysecret"] ?? nil)
        #expect(secret.driverOpts == nil)
    }

    // MARK: - Secret.template_driver

    @Test("Secret template_driver is decoded from YAML string")
    func secretTemplateDriverDecoded() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            secrets:
              - mysecret
        secrets:
          mysecret:
            file: ./secret.txt
            template_driver: golang
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let secret = try #require(compose.secrets?["mysecret"] ?? nil)
        #expect(secret.templateDriver == "golang")
    }

    @Test("Secret template_driver is nil when absent")
    func secretTemplateDriverNilWhenAbsent() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            secrets:
              - mysecret
        secrets:
          mysecret:
            file: ./secret.txt
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let secret = try #require(compose.secrets?["mysecret"] ?? nil)
        #expect(secret.templateDriver == nil)
    }

    @Test("Secret with driver_opts and template_driver together")
    func secretAllNicheFieldsTogether() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            secrets:
              - mysecret
        secrets:
          mysecret:
            file: ./secret.txt
            template_driver: golang
            driver_opts:
              ttl: 60s
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let secret = try #require(compose.secrets?["mysecret"] ?? nil)
        #expect(secret.templateDriver == "golang")
        #expect(secret.driverOpts?["ttl"] == "60s")
    }

    // MARK: - Config.content

    @Test("Config content is decoded from YAML string")
    func configContentDecoded() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            configs:
              - myconfig
        configs:
          myconfig:
            content: |
              key=value
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let config = try #require(compose.configs?["myconfig"] ?? nil)
        #expect(config.content?.trimmingCharacters(in: .whitespacesAndNewlines) == "key=value")
    }

    @Test("Config content is nil when absent")
    func configContentNilWhenAbsent() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            configs:
              - myconfig
        configs:
          myconfig:
            file: ./config.txt
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let config = try #require(compose.configs?["myconfig"] ?? nil)
        #expect(config.content == nil)
    }

    // MARK: - Config.environment

    @Test("Config environment is decoded from YAML string")
    func configEnvironmentDecoded() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            configs:
              - myconfig
        configs:
          myconfig:
            environment: MY_CONFIG_VAR
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let config = try #require(compose.configs?["myconfig"] ?? nil)
        #expect(config.environment == "MY_CONFIG_VAR")
    }

    @Test("Config environment is nil when absent")
    func configEnvironmentNilWhenAbsent() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            configs:
              - myconfig
        configs:
          myconfig:
            file: ./config.txt
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let config = try #require(compose.configs?["myconfig"] ?? nil)
        #expect(config.environment == nil)
    }

    // MARK: - Config.template_driver

    @Test("Config template_driver is decoded from YAML string")
    func configTemplateDriverDecoded() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            configs:
              - myconfig
        configs:
          myconfig:
            file: ./config.txt
            template_driver: golang
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let config = try #require(compose.configs?["myconfig"] ?? nil)
        #expect(config.templateDriver == "golang")
    }

    @Test("Config template_driver is nil when absent")
    func configTemplateDriverNilWhenAbsent() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            configs:
              - myconfig
        configs:
          myconfig:
            file: ./config.txt
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let config = try #require(compose.configs?["myconfig"] ?? nil)
        #expect(config.templateDriver == nil)
    }

    @Test("Config with content, environment, and template_driver together")
    func configAllNicheFieldsTogether() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            configs:
              - myconfig
        configs:
          myconfig:
            content: inline-content
            environment: MY_VAR
            template_driver: golang
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let config = try #require(compose.configs?["myconfig"] ?? nil)
        #expect(config.content == "inline-content")
        #expect(config.environment == "MY_VAR")
        #expect(config.templateDriver == "golang")
    }

    // MARK: - Existing fields unaffected

    @Test("Secret existing fields still decode correctly alongside new fields")
    func secretExistingFieldsUnaffected() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            secrets:
              - mysecret
        secrets:
          mysecret:
            file: ./secret.txt
            environment: SECRET_ENV_VAR
            name: my-real-secret
            template_driver: golang
            driver_opts:
              ttl: 30s
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let secret = try #require(compose.secrets?["mysecret"] ?? nil)
        #expect(secret.file == "./secret.txt")
        #expect(secret.environment == "SECRET_ENV_VAR")
        #expect(secret.name == "my-real-secret")
        #expect(secret.templateDriver == "golang")
        #expect(secret.driverOpts?["ttl"] == "30s")
    }

    @Test("Config existing fields still decode correctly alongside new fields")
    func configExistingFieldsUnaffected() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            configs:
              - myconfig
        configs:
          myconfig:
            file: ./config.txt
            name: my-real-config
            template_driver: golang
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let config = try #require(compose.configs?["myconfig"] ?? nil)
        #expect(config.file == "./config.txt")
        #expect(config.name == "my-real-config")
        #expect(config.templateDriver == "golang")
    }
}
