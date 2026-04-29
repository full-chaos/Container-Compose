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

@Suite("Compose down parsing")
struct ComposeDownParsingTests {
    @Test("ComposeDown accepts cwd without inheriting process flags")
    func acceptsCwdWithoutProcessFlags() throws {
        _ = try ComposeDown.parse(["--cwd", "/tmp/project"])

        #expect(throws: (any Error).self) {
            try ComposeDown.parse(["--env-file", ".env"])
        }
        #expect(throws: (any Error).self) {
            try ComposeDown.parse(["--tty"])
        }
        #expect(throws: (any Error).self) {
            try ComposeDown.parse(["--uid", "501"])
        }
    }

    @Test("ComposeDown help omits container process options")
    func helpOmitsProcessOptions() {
        let help = ComposeDown.helpMessage()

        #expect(help.contains("--cwd"))
        #expect(!help.contains("--env-file"))
        #expect(!help.contains("--gid"))
        #expect(!help.contains("--interactive"))
        #expect(!help.contains("--tty"))
        #expect(!help.contains("--uid"))
        #expect(!help.contains("--ulimit"))
        #expect(!help.contains("--workdir"))
    }
}
