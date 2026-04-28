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

@Suite("Compose Top Parsing Tests")
struct ComposeTopParsingTests {

    @Test("ComposeTop command parses without arguments")
    func composeTopCommandParsesWithoutArguments() throws {
        let cmd = try ComposeTop.parse([])
        #expect(cmd.services.isEmpty)
    }

    @Test("single service name argument parses")
    func singleServiceNameArgumentParses() throws {
        let cmd = try ComposeTop.parse(["web"])
        #expect(cmd.services == ["web"])
    }

    @Test("multiple service name arguments parse")
    func multipleServiceNameArgumentsParse() throws {
        let cmd = try ComposeTop.parse(["web", "db", "worker"])
        #expect(cmd.services == ["web", "db", "worker"])
    }
}
