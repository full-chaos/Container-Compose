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

/// CHAOS-1357 — tests for `GET /openapi.yaml` (bundled OpenAPI 3.1 spec).
@Suite("GET /openapi.yaml — OpenAPI spec route (CHAOS-1357)")
struct OpenAPIRouteTests {

    private func makeApp() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        OpenAPIRoute.register(router: router)
        return Application(router: router)
    }

    // MARK: - Status and Content-Type

    @Test("GET /openapi.yaml returns 200")
    func openAPIReturns200() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/openapi.yaml", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("GET /openapi.yaml Content-Type is application/yaml")
    func openAPIContentType() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/openapi.yaml", method: .get) { response in
                #expect(response.headers[.contentType] == "application/yaml")
            }
        }
    }

    // MARK: - Content validity

    @Test("GET /openapi.yaml body starts with 'openapi:' (OpenAPI 3.x header)")
    func openAPIBodyStartsWithOpenAPIKey() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/openapi.yaml", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.hasPrefix("openapi:"))
            }
        }
    }

    @Test("GET /openapi.yaml body contains version '3.1'")
    func openAPIBodyContainsVersion31() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/openapi.yaml", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.contains("3.1"))
            }
        }
    }

    @Test("GET /openapi.yaml body is non-empty")
    func openAPIBodyNonEmpty() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/openapi.yaml", method: .get) { response in
                #expect(response.body.readableBytes > 0)
            }
        }
    }

    @Test("GET /openapi.yaml body mentions /containers path")
    func openAPIBodyMentionsContainersPath() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/openapi.yaml", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(body.contains("/containers"))
            }
        }
    }
}
