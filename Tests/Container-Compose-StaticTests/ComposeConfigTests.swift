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

//
//  ComposeConfigTests.swift
//  Container-Compose
//

import Testing
import Foundation
import Yams
@testable import ContainerComposeCore

@Suite("ComposeConfig Command Tests")
struct ComposeConfigTests {

    // MARK: - Argument parsing tests

    @Test("ComposeConfig parses with no arguments")
    func parsesWithNoArgs() throws {
        let cmd = try ComposeConfig.parse([])
        #expect(cmd.services == false)
        #expect(cmd.volumes == false)
        #expect(cmd.profiles == false)
        #expect(cmd.noInterpolate == false)
        #expect(cmd.composeFilename == nil)
        #expect(cmd.profile.isEmpty)
    }

    @Test("--services flag parses correctly")
    func parsesServicesFlag() throws {
        let cmd = try ComposeConfig.parse(["--services"])
        #expect(cmd.services == true)
        #expect(cmd.volumes == false)
        #expect(cmd.profiles == false)
    }

    @Test("--volumes flag parses correctly")
    func parsesVolumesFlag() throws {
        let cmd = try ComposeConfig.parse(["--volumes"])
        #expect(cmd.volumes == true)
        #expect(cmd.services == false)
        #expect(cmd.profiles == false)
    }

    @Test("--profiles flag parses correctly")
    func parsesProfilesFlag() throws {
        let cmd = try ComposeConfig.parse(["--profiles"])
        #expect(cmd.profiles == true)
        #expect(cmd.services == false)
        #expect(cmd.volumes == false)
    }

    @Test("--no-interpolate flag parses correctly")
    func parsesNoInterpolateFlag() throws {
        let cmd = try ComposeConfig.parse(["--no-interpolate"])
        #expect(cmd.noInterpolate == true)
    }

    @Test("--file option parses correctly")
    func parsesFileOption() throws {
        let cmd = try ComposeConfig.parse(["--file", "my-compose.yml"])
        #expect(cmd.composeFilename == "my-compose.yml")
    }

    @Test("--profile option parses multiple values")
    func parsesProfileOption() throws {
        let cmd = try ComposeConfig.parse(["--profile", "dev", "--profile", "debug"])
        #expect(cmd.profile == ["dev", "debug"])
    }

    // MARK: - Behaviour test: full YAML output contains a service name

    @Test("Running config command outputs YAML containing service name")
    func fullYAMLOutputContainsServiceName() async throws {
        // Write a minimal compose file to a temp dir.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let yaml = """
        services:
          mywebapp:
            image: nginx:alpine
          mydb:
            image: postgres:16
        volumes:
          mydata:
        """
        let composePath = tempDir.appendingPathComponent("docker-compose.yml").path
        try yaml.write(toFile: composePath, atomically: true, encoding: .utf8)

        // Load + resolve directly (mirrors what ComposeConfig.run() does).
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        // Encode to YAML using the same encoder ComposeConfig uses.
        let encoded = try YAMLEncoder().encode(dockerCompose)

        #expect(encoded.contains("mywebapp"))
        #expect(encoded.contains("mydb"))
        #expect(encoded.contains("nginx:alpine"))
        #expect(encoded.contains("postgres:16"))
        #expect(encoded.contains("mydata"))
    }

    // MARK: - --services filter test

    @Test("--services flag produces sorted service names from compose file")
    func servicesFilterReturnsSortedNames() throws {
        let yaml = """
        services:
          zulu:
            image: alpine
          alpha:
            image: nginx
          bravo:
            image: redis
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let serviceList: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, svc in
            guard let svc else { return nil }
            return (name, svc)
        }
        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: [])
        let filtered = Service.filterByProfiles(serviceList, activeProfiles: activeProfiles)
        let names = filtered.map(\.serviceName).sorted()

        #expect(names == ["alpha", "bravo", "zulu"])
    }

    // MARK: - --volumes filter test

    @Test("--volumes flag produces sorted volume names")
    func volumesFilterReturnsSortedNames() throws {
        let yaml = """
        services:
          web:
            image: nginx
        volumes:
          pgdata:
          redisdata:
          appdata:
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let names = (dockerCompose.volumes ?? [:]).keys.sorted()
        #expect(names == ["appdata", "pgdata", "redisdata"])
    }

    // MARK: - --profiles union test

    @Test("--profiles flag returns union of all service profiles sorted")
    func profilesUnionIsSorted() throws {
        let yaml = """
        services:
          dev-tool:
            image: alpine
            profiles: [dev, tools]
          prod-service:
            image: nginx
            profiles: [prod]
          always-on:
            image: redis
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let serviceList: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, svc in
            guard let svc else { return nil }
            return (name, svc)
        }
        let allProfiles = Set(serviceList.flatMap { $0.service.profiles ?? [] })
        let sorted = allProfiles.sorted()
        #expect(sorted == ["dev", "prod", "tools"])
    }
}
