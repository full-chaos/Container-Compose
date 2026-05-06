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

// MARK: - RuntimeStatistics

/// Polled statistics snapshot. `apple/containerization` returns this via a
/// single vsock round-trip; for streaming, the runtime conformer maintains a
/// polling loop. Phase 1 declares the shape; Phase 2 wires the polling loop
/// into the Container REST API server.
public struct RuntimeStatistics: Sendable, Hashable, Codable {
    public let id: String
    public let cpuUsageUsec: UInt64?
    public let memoryUsageBytes: UInt64?
    public let memoryLimitBytes: UInt64?
    public let oomKillCount: UInt64?
    public let networks: [Network]
    public let sampledAt: Date

    public struct Network: Sendable, Hashable, Codable {
        public let interface: String
        public let receivedBytes: UInt64
        public let transmittedBytes: UInt64

        public init(interface: String, receivedBytes: UInt64, transmittedBytes: UInt64) {
            self.interface = interface
            self.receivedBytes = receivedBytes
            self.transmittedBytes = transmittedBytes
        }
    }

    public init(
        id: String,
        cpuUsageUsec: UInt64? = nil,
        memoryUsageBytes: UInt64? = nil,
        memoryLimitBytes: UInt64? = nil,
        oomKillCount: UInt64? = nil,
        networks: [Network] = [],
        sampledAt: Date = Date()
    ) {
        self.id = id
        self.cpuUsageUsec = cpuUsageUsec
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.oomKillCount = oomKillCount
        self.networks = networks
        self.sampledAt = sampledAt
    }
}
