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
import TestHelpers
@testable import ContainerComposeCore

@Suite("ComposePull Parsing Tests")
struct ComposePullTests {

    @Test("ComposePull parses with no arguments")
    func composePullParsesWithNoArguments() throws {
        let cmd = try ComposePull.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.composeFilename == nil)
        #expect(cmd.profile.isEmpty)
        #expect(cmd.includeDeps == false)
        #expect(cmd.ignorePullFailures == false)
        #expect(cmd.policy == nil)
    }

    @Test("ComposePull parses service name arguments")
    func composePullParsesServiceNames() throws {
        let cmd = try ComposePull.parse(["web", "db"])
        #expect(cmd.services == ["web", "db"])
    }

    @Test("ComposePull parses --policy always")
    func composePullParsesPolicyAlways() throws {
        let cmd = try ComposePull.parse(["--policy", "always"])
        #expect(cmd.policy == "always")
    }

    @Test("ComposePull parses --policy missing")
    func composePullParsesPolicyMissing() throws {
        let cmd = try ComposePull.parse(["--policy", "missing"])
        #expect(cmd.policy == "missing")
    }

    @Test("ComposePull parses --policy never")
    func composePullParsesPolicyNever() throws {
        let cmd = try ComposePull.parse(["--policy", "never"])
        #expect(cmd.policy == "never")
    }

    @Test("ComposePull parses --include-deps flag")
    func composePullParsesIncludeDeps() throws {
        let cmd = try ComposePull.parse(["--include-deps"])
        #expect(cmd.includeDeps == true)
    }

    @Test("ComposePull parses --ignore-pull-failures flag")
    func composePullParsesIgnorePullFailures() throws {
        let cmd = try ComposePull.parse(["--ignore-pull-failures"])
        #expect(cmd.ignorePullFailures == true)
    }

    @Test("ComposePull parses --profile flag")
    func composePullParsesProfile() throws {
        let cmd = try ComposePull.parse(["--profile", "production"])
        #expect(cmd.profile == ["production"])
    }

    @Test("ComposePull parses multiple --profile flags")
    func composePullParsesMultipleProfiles() throws {
        let cmd = try ComposePull.parse(["--profile", "production", "--profile", "debug"])
        #expect(cmd.profile == ["production", "debug"])
    }

    @Test("ComposePull parses -f flag for compose file")
    func composePullParsesFileFlag() throws {
        let cmd = try ComposePull.parse(["-f", "my-compose.yaml"])
        #expect(cmd.composeFilename == "my-compose.yaml")
    }

    @Test("ComposePull parses --file flag for compose file")
    func composePullParsesLongFileFlag() throws {
        let cmd = try ComposePull.parse(["--file", "docker-compose.yml"])
        #expect(cmd.composeFilename == "docker-compose.yml")
    }

    @Test("ComposePull parses combination of flags and services")
    func composePullParsesCombinedFlagsAndServices() throws {
        let cmd = try ComposePull.parse([
            "--policy", "always",
            "--include-deps",
            "--ignore-pull-failures",
            "--profile", "production",
            "web", "api"
        ])
        #expect(cmd.policy == "always")
        #expect(cmd.includeDeps == true)
        #expect(cmd.ignorePullFailures == true)
        #expect(cmd.profile == ["production"])
        #expect(cmd.services == ["web", "api"])
    }

    @Test("Shared pullImage helper respects pull policies")
    func sharedPullImageHelperRespectsPullPolicies() async throws {
        let hostPlatform = defaultRuntimePlatform()

        let alwaysRunner = RecordingRunner()
        let alwaysClient = RecordingContainerClientProvider()
        try await pullImage(
            image: "redis:latest",
            policy: "always",
            client: alwaysClient,
            runner: alwaysRunner
        )
        #expect(await alwaysClient.entriesSnapshot() == [.imageList])
        #expect(await alwaysRunner.swiftAPIArgvs(named: "ImagePull") == [["docker.io/library/redis:latest", "--platform", hostPlatform]])

        let neverRunner = RecordingRunner()
        let neverClient = RecordingContainerClientProvider()
        await #expect(throws: (any Error).self) {
            try await pullImage(
                image: "postgres:latest",
                policy: "never",
                client: neverClient,
                runner: neverRunner
            )
        }
        #expect(await neverClient.entriesSnapshot() == [.imageList])
        #expect(await neverRunner.swiftAPIArgvs(named: "ImagePull").isEmpty)

        let missingAbsentRunner = RecordingRunner()
        let missingAbsentClient = RecordingContainerClientProvider()
        try await pullImage(
            image: "nginx:latest",
            policy: "missing",
            client: missingAbsentClient,
            runner: missingAbsentRunner
        )
        #expect(await missingAbsentClient.entriesSnapshot() == [.imageList])
        #expect(await missingAbsentRunner.swiftAPIArgvs(named: "ImagePull") == [["docker.io/library/nginx:latest", "--platform", hostPlatform]])

        let missingPresentRunner = RecordingRunner()
        let missingPresentClient = RecordingContainerClientProvider(imageReferences: ["docker.io/library/nginx:latest"])
        try await pullImage(
            image: "nginx:latest",
            policy: "missing",
            client: missingPresentClient,
            runner: missingPresentRunner
        )
        #expect(await missingPresentClient.entriesSnapshot() == [.imageList])
        #expect(await missingPresentRunner.swiftAPIArgvs(named: "ImagePull").isEmpty)
    }

    // MARK: - CHAOS-1344: pullImage must default to the host platform

    @Test("pullImage defaults --platform to host architecture when service.platform is nil")
    func pullImageDefaultsToHostPlatformWhenNil() async throws {
        let runner = RecordingRunner()
        let client = RecordingContainerClientProvider()
        try await pullImage(
            image: "alpine:latest",
            policy: "always",
            client: client,
            runner: runner,
            platform: nil
        )
        let argvs = await runner.swiftAPIArgvs(named: "ImagePull")
        #expect(argvs.count == 1)
        let argv = try #require(argvs.first)
        let platformIdx = try #require(argv.firstIndex(of: "--platform"), "--platform must always be emitted (CHAOS-1344)")
        #expect(argv[argv.index(after: platformIdx)] == defaultRuntimePlatform())
    }

    @Test("pullImage forwards explicit service.platform unchanged")
    func pullImageForwardsExplicitPlatform() async throws {
        let runner = RecordingRunner()
        let client = RecordingContainerClientProvider()
        try await pullImage(
            image: "alpine:latest",
            policy: "always",
            client: client,
            runner: runner,
            platform: "linux/amd64"
        )
        let argv = try #require(await runner.swiftAPIArgvs(named: "ImagePull").first)
        let platformIdx = try #require(argv.firstIndex(of: "--platform"))
        #expect(argv[argv.index(after: platformIdx)] == "linux/amd64")
    }

    @Test("defaultRuntimePlatform returns linux/<host-arch>")
    func defaultRuntimePlatformShape() {
        let platform = defaultRuntimePlatform()
        #expect(platform.hasPrefix("linux/"))
        #if arch(arm64)
        #expect(platform == "linux/arm64")
        #elseif arch(x86_64)
        #expect(platform == "linux/amd64")
        #endif
    }
}
