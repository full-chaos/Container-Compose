//===----------------------------------------------------------------------===//
// Copyright © 2026 Container-Compose project authors. All rights reserved.
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

@Suite("Network create --plugin args (CHAOS-1327)")
struct NetworkCreatePluginArgsTests {

    @Test("nil driver emits no --plugin")
    func nilDriverEmitsNoPlugin() {
        #expect(ComposeUp.networkPluginArgs(for: nil) == [])
    }

    @Test("empty driver emits no --plugin")
    func emptyDriverEmitsNoPlugin() {
        #expect(ComposeUp.networkPluginArgs(for: "") == [])
    }

    @Test("'bridge' (Docker default) emits no --plugin so runtime defaults to vmnet")
    func bridgeDriverEmitsNoPlugin() {
        #expect(ComposeUp.networkPluginArgs(for: "bridge") == [])
    }

    @Test("explicit non-bridge driver passes through")
    func explicitDriverPassesThrough() {
        #expect(
            ComposeUp.networkPluginArgs(for: "container-network-vmnet")
                == ["--plugin", "container-network-vmnet"]
        )
    }

    @Test("custom plugin name passes through")
    func customPluginPassesThrough() {
        #expect(
            ComposeUp.networkPluginArgs(for: "my-custom-plugin")
                == ["--plugin", "my-custom-plugin"]
        )
    }
}
