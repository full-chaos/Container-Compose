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

/// Tests for `promoteGlobalFlags(_:)` — PLAN.md §3.3 option 2 pre-subcommand
/// global flag reordering, matching `docker compose` UX.
@Suite("Pre-subcommand Flag Promotion Tests")
struct PreSubcommandFlagPromotionTests {

    @Test("Empty args → unchanged")
    func emptyArgs() {
        #expect(promoteGlobalFlags([]) == [])
    }

    @Test("No globals before subcommand → unchanged (just subcommand)")
    func subcommandOnly() {
        #expect(promoteGlobalFlags(["build"]) == ["build"])
    }

    @Test("No globals before subcommand → unchanged (subcommand with its own -f)")
    func subcommandWithFlagAfter() {
        #expect(promoteGlobalFlags(["build", "-f", "x"]) == ["build", "-f", "x"])
    }

    @Test("Single global -f promoted after subcommand")
    func singleGlobalShort() {
        #expect(
            promoteGlobalFlags(["-f", "compose.yml", "build"])
            == ["build", "-f", "compose.yml"]
        )
    }

    @Test("Equals form --file=path promoted as single token")
    func equalsFormFile() {
        #expect(
            promoteGlobalFlags(["--file=compose.yml", "build"])
            == ["build", "--file=compose.yml"]
        )
    }

    @Test("Repeated --profile preserves order")
    func repeatedProfile() {
        #expect(
            promoteGlobalFlags(["--profile", "dev", "--profile", "test", "build"])
            == ["build", "--profile", "dev", "--profile", "test"]
        )
    }

    @Test("Mixed globals: -f, -p, --env-file all promoted, trailing args preserved")
    func mixedGlobals() {
        #expect(
            promoteGlobalFlags(["-f", "a", "-p", "proj", "--env-file", ".e", "build", "foo"])
            == ["build", "-f", "a", "-p", "proj", "--env-file", ".e", "foo"]
        )
    }

    @Test("--project-directory recognized")
    func projectDirectory() {
        #expect(
            promoteGlobalFlags(["--project-directory", "/tmp/p", "up"])
            == ["up", "--project-directory", "/tmp/p"]
        )
    }

    @Test("--project-name recognized (long form)")
    func projectNameLong() {
        #expect(
            promoteGlobalFlags(["--project-name", "myproj", "build"])
            == ["build", "--project-name", "myproj"]
        )
    }

    @Test("-p (short alias for --project-name) recognized")
    func projectNameShort() {
        #expect(
            promoteGlobalFlags(["-p", "myproj", "up"])
            == ["up", "-p", "myproj"]
        )
    }

    @Test("--env-file recognized")
    func envFile() {
        #expect(
            promoteGlobalFlags(["--env-file", ".env.dev", "up"])
            == ["up", "--env-file", ".env.dev"]
        )
    }

    @Test("Repeated --env-file preserves order")
    func repeatedEnvFile() {
        #expect(
            promoteGlobalFlags(["--env-file", ".a", "--env-file", ".b", "up"])
            == ["up", "--env-file", ".a", "--env-file", ".b"]
        )
    }

    @Test("Repeated -f preserves order")
    func repeatedFile() {
        #expect(
            promoteGlobalFlags(["-f", "a.yml", "-f", "b.yml", "up"])
            == ["up", "-f", "a.yml", "-f", "b.yml"]
        )
    }

    @Test("Unknown flag before subcommand → unchanged")
    func unknownFlagBefore() {
        #expect(
            promoteGlobalFlags(["--bogus", "build"])
            == ["--bogus", "build"]
        )
    }

    @Test("Help-style: only --help, no subcommand → unchanged")
    func helpOnly() {
        #expect(promoteGlobalFlags(["--help"]) == ["--help"])
    }

    @Test("Version-style: only --version, no subcommand → unchanged")
    func versionOnly() {
        #expect(promoteGlobalFlags(["--version"]) == ["--version"])
    }

    @Test("Subcommand-side flag preserved after promotion")
    func subcommandSideFlagPreserved() {
        #expect(
            promoteGlobalFlags(["-f", "x", "up", "-d"])
            == ["up", "-f", "x", "-d"]
        )
    }

    @Test("Equals form mixed with space form")
    func equalsAndSpaceMixed() {
        #expect(
            promoteGlobalFlags(["--file=a.yml", "-p", "proj", "build"])
            == ["build", "--file=a.yml", "-p", "proj"]
        )
    }

    @Test("Equals form for repeated --profile preserves order")
    func equalsFormRepeated() {
        #expect(
            promoteGlobalFlags(["--profile=dev", "--profile=test", "up"])
            == ["up", "--profile=dev", "--profile=test"]
        )
    }

    @Test("Multiple subcommand-side args preserved (positional after subcommand)")
    func positionalsAfterSubcommand() {
        #expect(
            promoteGlobalFlags(["-f", "x", "logs", "svc1", "svc2"])
            == ["logs", "-f", "x", "svc1", "svc2"]
        )
    }

    @Test("Subcommand starts with non-dash even if it contains numbers")
    func subcommandIsFirstNonDashToken() {
        // "version" is a real subcommand, but verifying that as long as the token
        // doesn't start with `-`, scanning stops there.
        #expect(
            promoteGlobalFlags(["-f", "x", "version"])
            == ["version", "-f", "x"]
        )
    }
}
