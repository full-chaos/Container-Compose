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

@Suite("ComposePush Parsing Tests")
struct ComposePushParsingTests {

    @Test("ComposePush parses with no arguments")
    func composePushParsesWithNoArguments() throws {
        let cmd = try ComposePush.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.composeFilename == nil)
        #expect(cmd.profile.isEmpty)
        #expect(cmd.includeDeps == false)
        #expect(cmd.ignorePushFailures == false)
        #expect(cmd.quiet == false)
    }

    @Test("ComposePush parses a single service name argument")
    func composePushParsesSingleServiceName() throws {
        let cmd = try ComposePush.parse(["web"])
        #expect(cmd.services == ["web"])
    }

    @Test("ComposePush parses multiple service name arguments")
    func composePushParsesMultipleServiceNames() throws {
        let cmd = try ComposePush.parse(["web", "db"])
        #expect(cmd.services == ["web", "db"])
    }

    @Test("--quiet flag parses")
    func quietFlagParses() throws {
        let cmd = try ComposePush.parse(["--quiet"])
        #expect(cmd.quiet == true)
    }

    @Test("-q short flag parses as quiet")
    func shortQFlagParsesAsQuiet() throws {
        let cmd = try ComposePush.parse(["-q"])
        #expect(cmd.quiet == true)
    }

    @Test("--include-deps flag parses")
    func includeDepsFlagParses() throws {
        let cmd = try ComposePush.parse(["--include-deps"])
        #expect(cmd.includeDeps == true)
    }

    @Test("--ignore-push-failures flag parses")
    func ignorePushFailuresFlagParses() throws {
        let cmd = try ComposePush.parse(["--ignore-push-failures"])
        #expect(cmd.ignorePushFailures == true)
    }

    @Test("combined flags and services parse together")
    func combinedFlagsAndServicesParseTogether() throws {
        let cmd = try ComposePush.parse([
            "--quiet",
            "--include-deps",
            "--ignore-push-failures",
            "--profile", "production",
            "web", "api"
        ])
        #expect(cmd.quiet == true)
        #expect(cmd.includeDeps == true)
        #expect(cmd.ignorePushFailures == true)
        #expect(cmd.profile == ["production"])
        #expect(cmd.services == ["web", "api"])
    }
}
