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

@Suite
struct SystemRoutesTests {
    @Test("GET /version returns APIVersionResponse")
    func versionRoute() async throws {
        let router = Router()
        SystemRoutes.register(router: router)
        let app = Application(router: router)

        try await RuntimeEnvironment.$current.withValue(RecordingRuntime()) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/version", method: .get) { response in
                    #expect(response.status == .ok)
                    let data = Data(String(buffer: response.body).utf8)
                    let body = try JSONDecoder().decode(APIVersionResponse.self, from: data)
                    #expect(body.serverName == "container-compose")
                    #expect(body.apiVersion == "v1")
                    #expect(!body.version.isEmpty)
                    #expect(!body.runtimeBackend.isEmpty)
                    #expect(body.arch == "arm64" || body.arch == "x86_64")
                }
            }
        }
    }

    @Test("GET /info returns counts + version")
    func infoRoute() async throws {
        let router = Router()
        SystemRoutes.register(router: router)
        let app = Application(router: router)

        try await RuntimeEnvironment.$current.withValue(RecordingRuntime()) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/info", method: .get) { response in
                    #expect(response.status == .ok)
                    let data = Data(String(buffer: response.body).utf8)
                    let body = try JSONDecoder().decode(APIInfoResponse.self, from: data)
                    #expect(body.id == ProcessInfo.processInfo.hostName)
                    #expect(body.name == ProcessInfo.processInfo.hostName)
                    #expect(body.containerCount == 0)
                    #expect(body.containersRunning == 0)
                    #expect(body.containersPaused == 0)
                    #expect(body.containersStopped == 0)
                    #expect(body.serverVersion == Main.versionString)
                    #expect(body.runtimeBackend == "recording-runtime")
                    #expect(body.uptimeNanoseconds > 0)
                }
            }
        }
    }
}
