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

/// CHAOS-1347 network routes for `GET /networks`.
/// Phase 3 will wire endpoint/MAC/IPv4 attachment details into the runtime
/// model; for now those fields are stubbed as empty strings.
public enum NetworkRoutes {
    public static func register(router: Router<BasicRequestContext>) {
        router.get("/networks") { _, _ in
            let runtime = RuntimeEnvironment.current
            let networks = try await runtime.listNetworks()
            return networks.map(toSummary)
        }
    }

    private static func toSummary(_ n: RuntimeNetwork) -> APINetworkSummary {
        let attached = Dictionary(uniqueKeysWithValues: n.attachedContainerIds.map { id in
            (id, APIAttachedContainer(endpointID: "", macAddress: "", ipv4Address: ""))
        })

        return APINetworkSummary(
            id: n.id,
            name: n.name,
            driver: n.driver,
            labels: n.labels,
            containers: attached
        )
    }
}

extension APINetworkSummary: ResponseEncodable {}
