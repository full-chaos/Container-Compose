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

/// CHAOS-1347 system routes for `GET /version` and `GET /info`.
/// Response payloads are defined in `Server/APISchemas.swift`.
public enum SystemRoutes {
    public static func register(router: Router<BasicRequestContext>) {
        router.get("/version") { _, _ in
            let runtime = RuntimeEnvironment.current
            let v = try await runtime.version()
            return APIVersionResponse(
                apiVersion: v.apiVersion,
                version: v.daemonVersion,
                serverName: v.serverName,
                runtimeBackend: v.backendDescription,
                arch: v.arch
            )
        }

        router.get("/info") { _, _ in
            let runtime = RuntimeEnvironment.current
            let v = try await runtime.version()
            let containers = try await runtime.list(filters: .all)
            let counts = countByState(containers)
            let host = ProcessInfo.processInfo.hostName
            return APIInfoResponse(
                id: host,
                name: host,
                containerCount: containers.count,
                containersRunning: counts.running,
                containersPaused: 0,
                containersStopped: counts.stopped,
                serverVersion: Main.versionString,
                runtimeBackend: v.backendDescription,
                uptimeNanoseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            )
        }
    }

    private static func countByState(_ list: [RuntimeContainer]) -> (running: Int, stopped: Int) {
        var r = 0, s = 0
        for c in list {
            switch c.status {
            case .running:
                r += 1
            case .stopped, .exited:
                s += 1
            default:
                break
            }
        }
        return (r, s)
    }
}

extension APIVersionResponse: ResponseEncodable {}

extension APIInfoResponse: ResponseEncodable {}
