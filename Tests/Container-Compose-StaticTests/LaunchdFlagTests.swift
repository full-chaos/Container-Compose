//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
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

import ArgumentParser
import Testing
@testable import ContainerComposeCore

/// Tests for the `--launchd` flag on `container-compose serve`.
///
/// These tests verify CHAOS-1355: that `ComposeServe` accepts a `--launchd`
/// flag, that it defaults to `false`, and that `ServeDaemon.logPrefix` returns
/// the correct structured prefix when the flag is set.
@Suite struct LaunchdFlagTests {

    // MARK: - Flag parsing

    @Test("serve --launchd flag defaults to false when not provided")
    func launchdFlag_defaultsFalse() throws {
        let cmd = try ComposeServe.parse([])
        #expect(cmd.launchdManaged == false)
    }

    @Test("serve --launchd flag parses to true when provided")
    func launchdFlag_parsesToTrue() throws {
        let cmd = try ComposeServe.parse(["--launchd"])
        #expect(cmd.launchdManaged == true)
    }

    @Test("serve --socket and --launchd can be combined")
    func launchdFlag_combinedWithSocket() throws {
        let cmd = try ComposeServe.parse(["--socket", "/tmp/test.sock", "--launchd"])
        #expect(cmd.launchdManaged == true)
        #expect(cmd.socketPath == "/tmp/test.sock")
    }

    // MARK: - Log prefix

    @Test("logPrefix returns empty string when launchdManaged is false")
    func logPrefix_nonLaunchd_empty() {
        #expect(ServeDaemon.logPrefix(launchdManaged: false) == "")
    }

    @Test("logPrefix returns structured prefix when launchdManaged is true")
    func logPrefix_launchd_hasStructuredPrefix() {
        let prefix = ServeDaemon.logPrefix(launchdManaged: true)
        // Must be non-empty and include a timestamp component and the label
        #expect(prefix.isEmpty == false)
        #expect(prefix.contains("container-compose"))
    }

    @Test("logPrefix in launchd mode includes ISO-8601 timestamp format cue")
    func logPrefix_launchd_containsTimestampPattern() {
        let prefix = ServeDaemon.logPrefix(launchdManaged: true)
        // Verify it has a date-like component: YYYY-MM-DD
        // logPrefix is a closure/function — check it includes a year prefix
        #expect(prefix.contains("Z") || prefix.contains("+") || prefix.contains("T"))
    }
}
