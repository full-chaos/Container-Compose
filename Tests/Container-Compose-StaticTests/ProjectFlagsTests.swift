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
import ArgumentParser
@testable import ContainerComposeCore

/// Tests for `ProjectFlags`, the project-context option group covering
/// `-p` / `--project-name` and `--project-directory` (PLAN.md §3.3 follow-up).
///
/// Also exercises the resolver helpers (`resolveProjectName`,
/// `resolveProjectDirectory`) and end-to-end argv-parse coverage on the
/// subcommands that mount the OptionGroup.
@Suite("Project Flags Tests")
struct ProjectFlagsTests {

    // MARK: - ProjectFlags parser

    @Test("Bare ProjectFlags parses with both fields nil")
    func bareParseHasNilFields() throws {
        let flags = try ProjectFlags.parse([])
        #expect(flags.projectName == nil)
        #expect(flags.projectDirectory == nil)
    }

    @Test("--project-name long form parses")
    func projectNameLongParses() throws {
        let flags = try ProjectFlags.parse(["--project-name", "foo"])
        #expect(flags.projectName == "foo")
        #expect(flags.projectDirectory == nil)
    }

    @Test("-p short form parses (alias for --project-name)")
    func projectNameShortParses() throws {
        let flags = try ProjectFlags.parse(["-p", "foo"])
        #expect(flags.projectName == "foo")
    }

    @Test("--project-directory parses")
    func projectDirectoryParses() throws {
        let flags = try ProjectFlags.parse(["--project-directory", "/tmp/x"])
        #expect(flags.projectDirectory == "/tmp/x")
        #expect(flags.projectName == nil)
    }

    @Test("Both flags parse together")
    func bothFlagsParseTogether() throws {
        let flags = try ProjectFlags.parse([
            "-p", "myproj",
            "--project-directory", "/srv/myproj",
        ])
        #expect(flags.projectName == "myproj")
        #expect(flags.projectDirectory == "/srv/myproj")
    }

    // MARK: - resolveProjectName

    @Test("resolveProjectName: CLI override wins over compose name")
    func resolveProjectNameCLIWinsOverCompose() {
        let name = resolveProjectName(
            cliOverride: "cli",
            composeName: "yaml",
            projectDirectory: "/some/dir"
        )
        #expect(name == "cli")
    }

    @Test("resolveProjectName: compose name used when no CLI override")
    func resolveProjectNameComposeFallback() {
        let name = resolveProjectName(
            cliOverride: nil,
            composeName: "yaml",
            projectDirectory: "/some/dir"
        )
        #expect(name == "yaml")
    }

    @Test("resolveProjectName: directory basename used when nothing else set")
    func resolveProjectNameDirectoryFallback() {
        let name = resolveProjectName(
            cliOverride: nil,
            composeName: nil,
            projectDirectory: "/some/dir"
        )
        // deriveProjectName replaces '.' with '_' AND lowercases (CHAOS-1511).
        #expect(name == deriveProjectName(cwd: "/some/dir"))
        #expect(name == "dir")
    }

    @Test("resolveProjectName: empty CLI override falls through to compose name")
    func resolveProjectNameEmptyCLIFallsThrough() {
        let name = resolveProjectName(
            cliOverride: "",
            composeName: "yaml",
            projectDirectory: "/some/dir"
        )
        #expect(name == "yaml")
    }

    @Test("resolveProjectName: empty CLI and empty compose fall through to directory")
    func resolveProjectNameEmptyCLIEmptyComposeFallsThrough() {
        let name = resolveProjectName(
            cliOverride: "",
            composeName: "",
            projectDirectory: "/some/dir"
        )
        #expect(name == "dir")
    }

    @Test("resolveProjectName: directory with dot is sanitized and lowercased (CHAOS-1511)")
    func resolveProjectNameDotSanitization() {
        let name = resolveProjectName(
            cliOverride: nil,
            composeName: nil,
            projectDirectory: "/Users/me/My.Project"
        )
        // CHAOS-1511: deriveProjectName now lowercases per compose-spec.
        #expect(name == "my_project")
    }

    // MARK: - resolveProjectDirectory

    @Test("resolveProjectDirectory: absolute CLI override returned verbatim")
    func resolveProjectDirectoryAbsoluteOverride() {
        let dir = resolveProjectDirectory(
            cliOverride: "/abs/path",
            composeFilePath: "/x/compose.yml",
            cwd: "/y"
        )
        #expect(dir == "/abs/path")
    }

    @Test("resolveProjectDirectory: relative CLI override is resolved against cwd")
    func resolveProjectDirectoryRelativeOverride() {
        let dir = resolveProjectDirectory(
            cliOverride: "rel",
            composeFilePath: "/x/compose.yml",
            cwd: "/y"
        )
        #expect(dir == "/y/rel")
    }

    @Test("resolveProjectDirectory: nested relative CLI override resolves correctly")
    func resolveProjectDirectoryNestedRelativeOverride() {
        let dir = resolveProjectDirectory(
            cliOverride: "nested/path",
            composeFilePath: "/x/compose.yml",
            cwd: "/y"
        )
        #expect(dir == "/y/nested/path")
    }

    @Test("resolveProjectDirectory: nil CLI override falls back to compose file's dir")
    func resolveProjectDirectoryNilOverride() {
        let dir = resolveProjectDirectory(
            cliOverride: nil,
            composeFilePath: "/x/compose.yml",
            cwd: "/y"
        )
        #expect(dir == "/x")
    }

    @Test("resolveProjectDirectory: empty-string CLI override falls back to compose file's dir")
    func resolveProjectDirectoryEmptyOverride() {
        let dir = resolveProjectDirectory(
            cliOverride: "",
            composeFilePath: "/x/compose.yml",
            cwd: "/y"
        )
        #expect(dir == "/x")
    }

    @Test("resolveProjectDirectory: tilde-prefixed CLI override expands to home")
    func resolveProjectDirectoryTildeOverride() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = resolveProjectDirectory(
            cliOverride: "~/projects/x",
            composeFilePath: "/x/compose.yml",
            cwd: "/y"
        )
        #expect(dir == "\(home)/projects/x")
    }

    // MARK: - Integration: subcommand argv parsing

    @Test("ComposeBuild parses promoted globals + project flags together")
    func composeBuildParsesAllPromotedGlobals() throws {
        let cmd = try ComposeBuild.parse([
            "--project-name", "foo",
            "--project-directory", "/some/path",
            "--file", "compose.yml",
            "--profile", "dev",
            "--env-file", ".env.dev",
        ])
        #expect(cmd.projectFlags.projectName == "foo")
        #expect(cmd.projectFlags.projectDirectory == "/some/path")
        #expect(cmd.composeFilename == "compose.yml")
        #expect(cmd.profile == ["dev"])
        #expect(cmd.process.envFile == [".env.dev"])
    }

    @Test("ComposeUp parses promoted globals + project flags together")
    func composeUpParsesAllPromotedGlobals() throws {
        let cmd = try ComposeUp.parse([
            "-p", "myproj",
            "--project-directory", "/srv/myproj",
            "-f", "compose.yml",
            "--env-file", ".env.dev",
            "--profile", "dev",
        ])
        #expect(cmd.projectFlags.projectName == "myproj")
        #expect(cmd.projectFlags.projectDirectory == "/srv/myproj")
        #expect(cmd.composeFilename == "compose.yml")
        #expect(cmd.profile == ["dev"])
        #expect(cmd.process.envFile == [".env.dev"])
    }

    @Test("ComposeRun parses promoted globals + project flags together")
    func composeRunParsesAllPromotedGlobals() throws {
        let cmd = try ComposeRun.parse([
            "--project-name", "foo",
            "--project-directory", "/some/path",
            "--file", "compose.yml",
            "web",
        ])
        #expect(cmd.projectFlags.projectName == "foo")
        #expect(cmd.projectFlags.projectDirectory == "/some/path")
        #expect(cmd.composeFilename == "compose.yml")
        #expect(cmd.serviceName == "web")
    }

    @Test("ComposeDown picks up project flags via OptionGroup")
    func composeDownAcceptsProjectFlags() throws {
        let cmd = try ComposeDown.parse([
            "-p", "down-proj",
            "--project-directory", "/p/down",
            "-f", "compose.yml",
        ])
        #expect(cmd.projectFlags.projectName == "down-proj")
        #expect(cmd.projectFlags.projectDirectory == "/p/down")
    }

    @Test("ComposePs picks up project flags via OptionGroup")
    func composePsAcceptsProjectFlags() throws {
        let cmd = try ComposePs.parse([
            "--project-name", "ps-proj",
            "-f", "compose.yml",
        ])
        #expect(cmd.projectFlags.projectName == "ps-proj")
        #expect(cmd.projectFlags.projectDirectory == nil)
    }

    @Test("ComposeConfig picks up project flags via OptionGroup")
    func composeConfigAcceptsProjectFlags() throws {
        let cmd = try ComposeConfig.parse([
            "--project-directory", "/here",
        ])
        #expect(cmd.projectFlags.projectName == nil)
        #expect(cmd.projectFlags.projectDirectory == "/here")
    }

    @Test("ComposeWatch picks up project flags via OptionGroup")
    func composeWatchAcceptsProjectFlags() throws {
        let cmd = try ComposeWatch.parse([
            "-p", "watch-proj",
        ])
        #expect(cmd.projectFlags.projectName == "watch-proj")
    }

    // MARK: - Bare-subcommand sanity checks (no project flags supplied)

    @Test("ComposeUp parses without project flags (bare invocation)")
    func composeUpBareParsesCleanly() throws {
        let cmd = try ComposeUp.parse([])
        #expect(cmd.projectFlags.projectName == nil)
        #expect(cmd.projectFlags.projectDirectory == nil)
    }
}
