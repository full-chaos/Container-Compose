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

// MARK: - Streaming deferral envelope

/// CHAOS-1350 501 response envelope for streaming routes whose backend is
/// intentionally deferred (currently stats, and runtime-specific events gaps).
@available(*, deprecated, message: "Use APIErrorEnvelope")
public struct APIStatsErrorResponse: Codable, Sendable, Hashable {
    public let error: String
    public let message: String
    public let deferralPhase: String

    public init(error: String, message: String, deferralPhase: String) {
        self.error = error
        self.message = message
        self.deferralPhase = deferralPhase
    }
}

// MARK: - GET /containers/{id}/stats  NDJSON streaming frame (CHAOS-1358)

/// Per-line NDJSON frame emitted by `GET /containers/{id}/stats` polling stream.
/// One frame per polling interval, encoded as ISO-8601 timestamps to match
/// `APIEventFrame` and `APILogFrame` wire conventions (Decision #7).
/// Replaces the 501 stub from Phase 2.B when the real backend wires in Phase 4.
public struct APIStatsFrame: Codable, Sendable, Hashable {
    public let id: String
    public let sampledAt: Date
    public let cpuUsageMicroseconds: UInt64?
    public let memoryUsageBytes: UInt64?
    public let memoryLimitBytes: UInt64?
    public let oomKillCount: UInt64?
    public let networks: [APIStatsNetworkFrame]

    public init(
        id: String,
        sampledAt: Date,
        cpuUsageMicroseconds: UInt64?,
        memoryUsageBytes: UInt64?,
        memoryLimitBytes: UInt64?,
        oomKillCount: UInt64?,
        networks: [APIStatsNetworkFrame]
    ) {
        self.id = id
        self.sampledAt = sampledAt
        self.cpuUsageMicroseconds = cpuUsageMicroseconds
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.oomKillCount = oomKillCount
        self.networks = networks
    }
}

public struct APIStatsNetworkFrame: Codable, Sendable, Hashable {
    public let interface: String
    public let receivedBytes: UInt64
    public let transmittedBytes: UInt64

    public init(interface: String, receivedBytes: UInt64, transmittedBytes: UInt64) {
        self.interface = interface
        self.receivedBytes = receivedBytes
        self.transmittedBytes = transmittedBytes
    }
}

// MARK: - GET /containers/{id}/stats  (legacy schema — retained for compatibility)

public struct APIStatistics: Codable, Sendable, Hashable {
    public let id: String
    public let sampledAt: Date
    public let cpuUsageMicroseconds: Int64
    public let memoryUsageBytes: Int64
    public let memoryLimitBytes: Int64
    public let oomKillCount: Int
    public let networkUsage: [String: APIInterfaceStats]

    public init(
        id: String,
        sampledAt: Date,
        cpuUsageMicroseconds: Int64,
        memoryUsageBytes: Int64,
        memoryLimitBytes: Int64,
        oomKillCount: Int,
        networkUsage: [String: APIInterfaceStats]
    ) {
        self.id = id
        self.sampledAt = sampledAt
        self.cpuUsageMicroseconds = cpuUsageMicroseconds
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.oomKillCount = oomKillCount
        self.networkUsage = networkUsage
    }
}

public struct APIInterfaceStats: Codable, Sendable, Hashable {
    public let rxBytes: Int64
    public let txBytes: Int64

    public init(rxBytes: Int64, txBytes: Int64) {
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }
}
