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

import Testing
@testable import ContainerComposeCore

@Suite("Remote flag parsing")
struct RemoteFlagParsingTests {

    @Test("remote flag is stripped and parsed before the subcommand")
    func remoteFlagExtraction() throws {
        let input = [
            "--remote", "tls://localhost:8443",
            "--token", "cc_v1_token",
            "ps",
            "--quiet"
        ]

        let result = try RemoteRuntimeFlagParser.extract(from: input)

        #expect(result.remainder == ["ps", "--quiet"])
        #expect(result.configuration?.address == .tls(host: "localhost", port: 8443))
        #expect(result.configuration?.token == "cc_v1_token")
    }

    @Test("remote flag accepts equals form")
    func remoteEqualsForm() throws {
        let result = try RemoteRuntimeFlagParser.extract(from: [
            "--remote=unix:///tmp/container-compose.sock",
            "version"
        ])

        #expect(result.remainder == ["version"])
        #expect(result.configuration?.address == .unix(path: "/tmp/container-compose.sock"))
    }

    @Test("non-remote args are preserved")
    func nonRemoteArgsRemain() throws {
        let result = try RemoteRuntimeFlagParser.extract(from: [
            "--file", "compose.yml",
            "up"
        ])

        #expect(result.remainder == ["--file", "compose.yml", "up"])
        #expect(result.configuration == nil)
    }

    @Test("invalid remote address throws instead of falling back to local runtime")
    func invalidRemoteThrows() throws {
        #expect(throws: ListenAddressError.unsupportedScheme("ssh")) {
            _ = try RemoteRuntimeFlagParser.extract(from: [
                "--remote", "ssh://localhost:8443",
                "ps"
            ])
        }
    }
}
