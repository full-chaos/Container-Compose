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

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite("Container REST routes - GET /networks")
struct NetworkRoutesTests {

    @Test("GET /networks returns empty array when no networks")
    func returnsEmptyArray() async throws {
        let router = Router()
        NetworkRoutes.register(router: router)
        let app = Application(router: router)

        let runtime = RecordingRuntime(stubbedNetworks: [])
        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/networks", method: .get) { response in
                    #expect(response.status == .ok)
                    let data = Data(String(buffer: response.body).utf8)
                    let body = try JSONDecoder().decode([APINetworkSummary].self, from: data)
                    #expect(body.isEmpty)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.listNetworks])
    }

    @Test("GET /networks maps RuntimeNetwork to APINetworkSummary")
    func mapsNetworks() async throws {
        let router = Router()
        NetworkRoutes.register(router: router)
        let app = Application(router: router)

        let runtime = RecordingRuntime(stubbedNetworks: [
            RuntimeNetwork(
                id: "net-1",
                name: "bridge",
                driver: "bridge",
                labels: ["owner": "compose"],
                attachedContainerIds: ["c-1", "c-2"]
            ),
            RuntimeNetwork(
                id: "net-2",
                name: "isolated",
                driver: "macvlan",
                labels: [:],
                attachedContainerIds: []
            )
        ])

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/networks", method: .get) { response in
                    #expect(response.status == .ok)
                    let data = Data(String(buffer: response.body).utf8)
                    let body = try JSONDecoder().decode([APINetworkSummary].self, from: data)

                    #expect(body.count == 2)
                    #expect(body[0].id == "net-1")
                    #expect(body[0].name == "bridge")
                    #expect(body[0].driver == "bridge")
                    #expect(body[0].labels == ["owner": "compose"])
                    #expect(Set(body[0].containers.keys) == Set(["c-1", "c-2"]))
                    #expect(body[0].containers["c-1"]?.endpointID == "")
                    #expect(body[0].containers["c-1"]?.macAddress == "")
                    #expect(body[0].containers["c-1"]?.ipv4Address == "")

                    #expect(body[1].id == "net-2")
                    #expect(body[1].name == "isolated")
                    #expect(body[1].driver == "macvlan")
                    #expect(body[1].labels.isEmpty)
                    #expect(body[1].containers.isEmpty)
                }
            }
        }

        #expect(await runtime.entriesSnapshot() == [.listNetworks])
    }
}
