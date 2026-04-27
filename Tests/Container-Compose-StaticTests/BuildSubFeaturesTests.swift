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

@Suite("Build Sub-Features Tests")
struct BuildSubFeaturesTests {

    // MARK: - target

    @Test("Parse build target stage")
    func parseBuildTarget() throws {
        let yaml = """
        context: .
        target: production
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.target == "production")
    }

    @Test("Build target is nil when absent")
    func buildTargetNilWhenAbsent() throws {
        let yaml = """
        context: .
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.target == nil)
    }

    // MARK: - dockerfile_inline

    @Test("Parse dockerfile_inline content survives decode")
    func parseDockerfileInlineContent() throws {
        let yaml = """
        context: .
        dockerfile_inline: |
          FROM alpine:3.18
          RUN echo hello
          CMD ["sh"]
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.dockerfile_inline != nil)
        #expect(build.dockerfile_inline?.contains("FROM alpine:3.18") == true)
        #expect(build.dockerfile_inline?.contains("RUN echo hello") == true)
        #expect(build.dockerfile_inline?.contains("CMD") == true)
    }

    @Test("dockerfile_inline is nil when absent")
    func dockerfileInlineNilWhenAbsent() throws {
        let yaml = """
        context: ./app
        dockerfile: Dockerfile.prod
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.dockerfile_inline == nil)
    }

    // MARK: - cache_from

    @Test("Parse single cache_from reference")
    func parseSingleCacheFrom() throws {
        let yaml = """
        context: .
        cache_from:
          - myregistry.example.com/myimage:latest
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.cache_from?.count == 1)
        #expect(build.cache_from?.first == "myregistry.example.com/myimage:latest")
    }

    @Test("Parse multiple cache_from references")
    func parseMultipleCacheFrom() throws {
        let yaml = """
        context: .
        cache_from:
          - registry/image:tag1
          - registry/image:tag2
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.cache_from?.count == 2)
        #expect(build.cache_from?.contains("registry/image:tag1") == true)
        #expect(build.cache_from?.contains("registry/image:tag2") == true)
    }

    @Test("cache_from is nil when absent")
    func cacheFromNilWhenAbsent() throws {
        let yaml = "context: ."
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.cache_from == nil)
    }

    // MARK: - cache_to

    @Test("Parse cache_to reference")
    func parseCacheTo() throws {
        let yaml = """
        context: .
        cache_to:
          - type=registry,ref=myregistry.example.com/myimage:cache
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.cache_to?.count == 1)
        #expect(build.cache_to?.first == "type=registry,ref=myregistry.example.com/myimage:cache")
    }

    @Test("cache_to is nil when absent")
    func cacheToNilWhenAbsent() throws {
        let yaml = "context: ."
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.cache_to == nil)
    }

    // MARK: - labels

    @Test("Parse build labels map")
    func parseBuildLabels() throws {
        let yaml = """
        context: .
        labels:
          com.example.version: "1.0"
          com.example.env: staging
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.labels?.count == 2)
        #expect(build.labels?["com.example.version"] == "1.0")
        #expect(build.labels?["com.example.env"] == "staging")
    }

    @Test("labels is nil when absent")
    func labelsNilWhenAbsent() throws {
        let yaml = "context: ."
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.labels == nil)
    }

    // MARK: - network

    @Test("Parse build network mode")
    func parseBuildNetwork() throws {
        let yaml = """
        context: .
        network: host
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.network == "host")
    }

    @Test("network is nil when absent")
    func networkNilWhenAbsent() throws {
        let yaml = "context: ."
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.network == nil)
    }

    // MARK: - secrets

    @Test("Parse build secrets list")
    func parseBuildSecrets() throws {
        let yaml = """
        context: .
        secrets:
          - server-certificate
          - api-key
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.secrets?.count == 2)
        #expect(build.secrets?.contains("server-certificate") == true)
        #expect(build.secrets?.contains("api-key") == true)
    }

    @Test("secrets is nil when absent")
    func secretsNilWhenAbsent() throws {
        let yaml = "context: ."
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.secrets == nil)
    }

    // MARK: - ssh

    @Test("Parse build ssh mappings")
    func parseBuildSSH() throws {
        let yaml = """
        context: .
        ssh:
          - default
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.ssh?.count == 1)
        #expect(build.ssh?.first == "default")
    }

    @Test("ssh is nil when absent")
    func sshNilWhenAbsent() throws {
        let yaml = "context: ."
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.ssh == nil)
    }

    // MARK: - platforms

    @Test("Parse platforms single entry")
    func parsePlatformsSingle() throws {
        let yaml = """
        context: .
        platforms:
          - linux/amd64
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.platforms?.count == 1)
        #expect(build.platforms?.first == "linux/amd64")
    }

    @Test("Parse platforms multi-list decodes all entries")
    func parsePlatformsMultiList() throws {
        let yaml = """
        context: .
        platforms:
          - linux/amd64
          - linux/arm64
          - linux/arm/v7
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.platforms?.count == 3)
        #expect(build.platforms?.contains("linux/amd64") == true)
        #expect(build.platforms?.contains("linux/arm64") == true)
        #expect(build.platforms?.contains("linux/arm/v7") == true)
    }

    @Test("platforms is nil when absent")
    func platformsNilWhenAbsent() throws {
        let yaml = "context: ."
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.platforms == nil)
    }

    // MARK: - shm_size

    @Test("Parse build shm_size")
    func parseBuildShmSize() throws {
        let yaml = """
        context: .
        shm_size: 128m
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.shm_size == "128m")
    }

    @Test("shm_size is nil when absent")
    func shmSizeNilWhenAbsent() throws {
        let yaml = "context: ."
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.shm_size == nil)
    }

    // MARK: - String shorthand still works

    @Test("String shorthand build still decodes; new fields are nil")
    func stringShorthandNewFieldsNil() throws {
        let yaml = "."
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.context == ".")
        #expect(build.target == nil)
        #expect(build.dockerfile_inline == nil)
        #expect(build.cache_from == nil)
        #expect(build.cache_to == nil)
        #expect(build.labels == nil)
        #expect(build.network == nil)
        #expect(build.secrets == nil)
        #expect(build.ssh == nil)
        #expect(build.platforms == nil)
        #expect(build.shm_size == nil)
    }

    // MARK: - Combo test

    @Test("Combo: target + cache_from + labels decode together")
    func comboTargetCacheFromLabels() throws {
        let yaml = """
        context: ./src
        dockerfile: Dockerfile.prod
        target: release
        cache_from:
          - ghcr.io/org/app:buildcache
          - ghcr.io/org/app:latest
        labels:
          maintainer: "team@example.com"
          version: "2.0"
        shm_size: 256m
        network: none
        """
        let build = try YAMLDecoder().decode(Build.self, from: yaml)
        #expect(build.context == "./src")
        #expect(build.dockerfile == "Dockerfile.prod")
        #expect(build.target == "release")
        #expect(build.cache_from?.count == 2)
        #expect(build.labels?["maintainer"] == "team@example.com")
        #expect(build.labels?["version"] == "2.0")
        #expect(build.shm_size == "256m")
        #expect(build.network == "none")
    }

    // MARK: - Full compose integration

    @Test("Full compose YAML with rich build section decodes correctly")
    func fullComposeBuildDecode() throws {
        let yaml = """
        version: '3.9'
        services:
          api:
            build:
              context: ./api
              target: builder
              cache_from:
                - registry/api:cache
              cache_to:
                - type=inline
              labels:
                app: api
              network: host
              secrets:
                - db-password
              ssh:
                - default
              platforms:
                - linux/amd64
                - linux/arm64
              shm_size: 64m
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let build = compose.services["api"]??.build
        #expect(build != nil)
        #expect(build?.target == "builder")
        #expect(build?.cache_from?.first == "registry/api:cache")
        #expect(build?.cache_to?.first == "type=inline")
        #expect(build?.labels?["app"] == "api")
        #expect(build?.network == "host")
        #expect(build?.secrets?.contains("db-password") == true)
        #expect(build?.ssh?.contains("default") == true)
        #expect(build?.platforms?.count == 2)
        #expect(build?.shm_size == "64m")
    }
}
