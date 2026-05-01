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
import HTTPTypes

/// CHAOS-1350 stats route reservation for `GET /containers/{id}/stats`.
/// Always returns 501 until Phase 3 wires the polling loop to
/// `Runtime.statistics(for:)` and the real backend statistics source.
public enum StatsRoutes {
    public static func register(router: Router<BasicRequestContext>) {
        router.get("/containers/:id/stats") { request, context -> Response in
            try EditedResponse(
                status: .notImplemented,
                headers: [.containerComposeDeferral: "stats-backend"],
                response: APIStatsErrorResponse(
                    error: "Not Implemented",
                    message: "Stats backend deferred to Phase 3",
                    deferralPhase: "Phase 3"
                )
            ).response(from: request, context: context)
        }
    }
}

extension HTTPField.Name {
    static let containerComposeDeferral = Self("X-ContainerCompose-Deferral")!
}
