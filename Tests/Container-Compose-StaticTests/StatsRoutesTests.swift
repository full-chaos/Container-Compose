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

@Suite("Container REST routes - GET /containers/{id}/stats")
struct StatsRoutesTests {
    @Test("GET /containers/{id}/stats reserves the route with a Phase 3 deferral response")
    func statsReturnsDeferral501() async throws {
        let router = Router()
        StatsRoutes.register(router: router)
        let app = Application(router: router)

        try await app.test(.router) { client in
            try await client.execute(uri: "/containers/web/stats", method: .get) { response in
                #expect(response.status == .notImplemented)
                #expect(response.headers[.containerComposeDeferral] == "stats-backend")
                let body = try Self.decode(APIStatsErrorResponse.self, from: response)
                #expect(body.error == "Not Implemented")
                #expect(body.message == "Stats backend deferred to Phase 3")
                #expect(body.deferralPhase == "Phase 3")
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
        let data = Data(String(buffer: response.body).utf8)
        return try JSONDecoder().decode(type, from: data)
    }
}
