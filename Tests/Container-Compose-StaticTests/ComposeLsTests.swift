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

@Suite("ComposeLs Tests")
struct ComposeLsTests {

    // MARK: - Table row formatting (regression coverage for SIGSEGV in run())

    /// Pre-fix, `ComposeLs.run()` called `String(format: "%-\(width)s  %s", ...)`
    /// with Swift `String` values. NSString's printf bridge interpreted the
    /// String pointer as `char *` and `strlen` walked off into unmapped memory,
    /// crashing whenever there was at least one project to list. The new
    /// `formatTableRow` helper avoids `String(format:)` entirely.
    @Test("formatTableRow pads name to nameWidth with trailing spaces")
    func formatTableRowPadsName() {
        let row = ComposeLs.formatTableRow(name: "web", status: "running(2)", nameWidth: 10)
        #expect(row == "web         running(2)")
        // 3 chars + 7 spaces of padding = 10, then "  " separator, then status.
    }

    @Test("formatTableRow does not truncate names longer than nameWidth")
    func formatTableRowDoesNotTruncate() {
        let row = ComposeLs.formatTableRow(name: "very-long-project-name", status: "ok", nameWidth: 4)
        #expect(row == "very-long-project-name  ok")
    }

    @Test("formatTableRow handles unicode names without crashing or miscounting")
    func formatTableRowUnicodeName() {
        // The original `%s` format would have crashed on this. UTF-8 byte count
        // is larger than `count` (Character count), but we use `count` for
        // padding so visual width is approximate but never crashes.
        let row = ComposeLs.formatTableRow(name: "café", status: "running(1)", nameWidth: 8)
        #expect(row.hasPrefix("café"))
        #expect(row.contains("  running(1)"))
    }

    @Test("formatTableRow with name equal to nameWidth has no padding")
    func formatTableRowExactWidth() {
        let row = ComposeLs.formatTableRow(name: "abcd", status: "x", nameWidth: 4)
        #expect(row == "abcd  x")
    }

    @Test("formatTableRow tolerates negative effective padding")
    func formatTableRowNegativePadding() {
        // nameWidth < name.count → max(0, ...) prevents a String(repeating:) crash.
        let row = ComposeLs.formatTableRow(name: "abcdef", status: "x", nameWidth: 0)
        #expect(row == "abcdef  x")
    }

    // MARK: - Command parsing

    @Test("ComposeLs parses with no arguments")
    func composeLsParseDefault() throws {
        let cmd = try ComposeLs.parse([])
        #expect(cmd.all == false)
        #expect(cmd.quiet == false)
    }

    @Test("ComposeLs parses --all flag (long)")
    func composeLsParseAllLong() throws {
        let cmd = try ComposeLs.parse(["--all"])
        #expect(cmd.all == true)
    }

    @Test("ComposeLs parses -a flag (short)")
    func composeLsParseAllShort() throws {
        let cmd = try ComposeLs.parse(["-a"])
        #expect(cmd.all == true)
    }

    @Test("ComposeLs parses --quiet flag (long)")
    func composeLsParseQuietLong() throws {
        let cmd = try ComposeLs.parse(["--quiet"])
        #expect(cmd.quiet == true)
    }

    @Test("ComposeLs parses -q flag (short)")
    func composeLsParseQuietShort() throws {
        let cmd = try ComposeLs.parse(["-q"])
        #expect(cmd.quiet == true)
    }

    @Test("ComposeLs parses both --all and --quiet together")
    func composeLsParseAllAndQuiet() throws {
        let cmd = try ComposeLs.parse(["--all", "--quiet"])
        #expect(cmd.all == true)
        #expect(cmd.quiet == true)
    }

    // MARK: - extractProject helper

    @Test("extractProject returns project from simple name")
    func extractProjectSimple() {
        #expect(ComposeLs.extractProject(from: "myproj-web") == "myproj")
    }

    @Test("extractProject returns project from multi-dash name")
    func extractProjectMultiDash() {
        #expect(ComposeLs.extractProject(from: "my-cool-proj-web") == "my-cool-proj")
    }

    @Test("extractProject returns nil when no dash present")
    func extractProjectNoDash() {
        #expect(ComposeLs.extractProject(from: "single") == nil)
    }

    @Test("extractProject returns nil for empty string")
    func extractProjectEmpty() {
        #expect(ComposeLs.extractProject(from: "") == nil)
    }

    @Test("extractProject returns nil when dash is only at the start")
    func extractProjectLeadingDashOnly() {
        // "-service" → project part before last dash is "", which is empty → nil
        #expect(ComposeLs.extractProject(from: "-service") == nil)
    }

    @Test("extractProject handles single-char project name")
    func extractProjectSingleChar() {
        #expect(ComposeLs.extractProject(from: "a-svc") == "a")
    }
}
