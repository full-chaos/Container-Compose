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
@testable import ContainerComposeCore

@Suite("Compose Ps Parsing Tests")
struct ComposePsParsingTests {

    @Test("ComposePs command parses without arguments")
    func composePsCommandParsesWithoutArguments() throws {
        let cmd = try ComposePs.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.quiet == false)
        #expect(cmd.all == false)
        #expect(cmd.profile.isEmpty)
        #expect(cmd.composeFilename == nil)
    }

    @Test("--quiet flag parses")
    func quietFlagParses() throws {
        let cmd = try ComposePs.parse(["--quiet"])
        #expect(cmd.quiet == true)
    }

    @Test("-q short flag parses as quiet")
    func shortQFlagParsesAsQuiet() throws {
        let cmd = try ComposePs.parse(["-q"])
        #expect(cmd.quiet == true)
    }

    @Test("--all flag parses")
    func allFlagParses() throws {
        let cmd = try ComposePs.parse(["--all"])
        #expect(cmd.all == true)
    }

    @Test("--profile dev parses")
    func profileDevParses() throws {
        let cmd = try ComposePs.parse(["--profile", "dev"])
        #expect(cmd.profile == ["dev"])
    }

    @Test("multiple --profile flags parse")
    func multipleProfileFlagsParse() throws {
        let cmd = try ComposePs.parse(["--profile", "dev", "--profile", "test"])
        #expect(cmd.profile == ["dev", "test"])
    }

    @Test("service name argument parses")
    func serviceNameArgumentParses() throws {
        let cmd = try ComposePs.parse(["web"])
        #expect(cmd.services == ["web"])
    }

    @Test("multiple service name arguments parse")
    func multipleServiceNameArgumentsParse() throws {
        let cmd = try ComposePs.parse(["web", "db"])
        #expect(cmd.services == ["web", "db"])
    }

    @Test("-f flag accepts compose file path")
    func fileFlagAcceptsComposePath() throws {
        let cmd = try ComposePs.parse(["-f", "my-compose.yaml"])
        #expect(cmd.composeFilename == "my-compose.yaml")
    }

    @Test("--file flag accepts compose file path")
    func longFileFlagAcceptsComposePath() throws {
        let cmd = try ComposePs.parse(["--file", "docker-compose.yml"])
        #expect(cmd.composeFilename == "docker-compose.yml")
    }

    @Test("combined flags parse together")
    func combinedFlagsParseTogether() throws {
        let cmd = try ComposePs.parse(["--quiet", "--all", "--profile", "prod", "web"])
        #expect(cmd.quiet == true)
        #expect(cmd.all == true)
        #expect(cmd.profile == ["prod"])
        #expect(cmd.services == ["web"])
    }
}
