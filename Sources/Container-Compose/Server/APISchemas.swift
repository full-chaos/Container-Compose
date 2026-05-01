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

/// Hand-written Codable request/response types for the Container REST API
/// native server (CHAOS-1347). These shapes stay manual rather than generated
/// from OpenAPI per `docs/plans/native-api-server.md` so the server surface can
/// evolve with the codebase.

// MARK: - GET /version

public struct APIVersionResponse: Codable, Sendable, Hashable {
    public let apiVersion: String
    public let version: String
    public let serverName: String
    public let runtimeBackend: String
    public let arch: String

    public init(
        apiVersion: String,
        version: String,
        serverName: String,
        runtimeBackend: String,
        arch: String
    ) {
        self.apiVersion = apiVersion
        self.version = version
        self.serverName = serverName
        self.runtimeBackend = runtimeBackend
        self.arch = arch
    }
}

// MARK: - GET /info

public struct APIInfoResponse: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let containerCount: Int
    public let containersRunning: Int
    public let containersPaused: Int
    public let containersStopped: Int
    public let serverVersion: String
    public let runtimeBackend: String
    public let uptimeNanoseconds: Int64

    public init(
        id: String,
        name: String,
        containerCount: Int,
        containersRunning: Int,
        containersPaused: Int,
        containersStopped: Int,
        serverVersion: String,
        runtimeBackend: String,
        uptimeNanoseconds: Int64
    ) {
        self.id = id
        self.name = name
        self.containerCount = containerCount
        self.containersRunning = containersRunning
        self.containersPaused = containersPaused
        self.containersStopped = containersStopped
        self.serverVersion = serverVersion
        self.runtimeBackend = runtimeBackend
        self.uptimeNanoseconds = uptimeNanoseconds
    }
}

// MARK: - GET /containers (list)

public struct APIContainerSummary: Codable, Sendable, Hashable {
    public let id: String
    public let names: [String]
    public let image: String
    public let state: String
    public let status: String
    public let createdAt: Date
    public let startedAt: Date?
    public let ports: [APIPortMapping]
    public let labels: [String: String]

    public init(
        id: String,
        names: [String],
        image: String,
        state: String,
        status: String,
        createdAt: Date,
        startedAt: Date?,
        ports: [APIPortMapping],
        labels: [String: String]
    ) {
        self.id = id
        self.names = names
        self.image = image
        self.state = state
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.ports = ports
        self.labels = labels
    }
}

public struct APIPortMapping: Codable, Sendable, Hashable {
    public let privatePort: Int
    public let publicPort: Int?
    public let proto: String
    public let ip: String?

    public init(
        privatePort: Int,
        publicPort: Int?,
        proto: String,
        ip: String?
    ) {
        self.privatePort = privatePort
        self.publicPort = publicPort
        self.proto = proto
        self.ip = ip
    }
}

// MARK: - GET /containers/{id} (inspect)

public struct APIContainerInspect: Codable, Sendable, Hashable {
    public let id: String
    public let created: Date
    public let name: String
    public let image: String
    public let state: APIContainerState
    public let config: APIContainerConfig
    public let networkSettings: APINetworkSettings

    public init(
        id: String,
        created: Date,
        name: String,
        image: String,
        state: APIContainerState,
        config: APIContainerConfig,
        networkSettings: APINetworkSettings
    ) {
        self.id = id
        self.created = created
        self.name = name
        self.image = image
        self.state = state
        self.config = config
        self.networkSettings = networkSettings
    }
}

public struct APIContainerState: Codable, Sendable, Hashable {
    public let status: String
    public let running: Bool
    public let exitCode: Int32?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let health: String?

    public init(
        status: String,
        running: Bool,
        exitCode: Int32?,
        startedAt: Date?,
        finishedAt: Date?,
        health: String?
    ) {
        self.status = status
        self.running = running
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.health = health
    }
}

public struct APIContainerConfig: Codable, Sendable, Hashable {
    public let hostname: String
    public let env: [String]
    public let cmd: [String]
    public let workingDir: String
    public let labels: [String: String]

    public init(
        hostname: String,
        env: [String],
        cmd: [String],
        workingDir: String,
        labels: [String: String]
    ) {
        self.hostname = hostname
        self.env = env
        self.cmd = cmd
        self.workingDir = workingDir
        self.labels = labels
    }
}

public struct APINetworkSettings: Codable, Sendable, Hashable {
    public let ipAddress: String?
    public let ports: [APIPortMapping]

    public init(ipAddress: String?, ports: [APIPortMapping]) {
        self.ipAddress = ipAddress
        self.ports = ports
    }
}

// MARK: - POST /containers/create  (DEFERRED in PR-A; schema reserved for v2)

/// Reserved for a future PR that ships POST /containers/create. Defined now
/// so the schema file is the single source of truth for all endpoint shapes,
/// even those not wired yet.
public struct APICreateContainerRequest: Codable, Sendable, Hashable {
    public let image: String
    public let name: String?
    public let cpus: Int?
    public let memoryBytes: UInt64?
    public let hostname: String?
    public let env: [String]?
    public let cmd: [String]?
    public let workingDir: String?

    public init(
        image: String,
        name: String?,
        cpus: Int?,
        memoryBytes: UInt64?,
        hostname: String?,
        env: [String]?,
        cmd: [String]?,
        workingDir: String?
    ) {
        self.image = image
        self.name = name
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.hostname = hostname
        self.env = env
        self.cmd = cmd
        self.workingDir = workingDir
    }
}

public struct APICreateContainerResponse: Codable, Sendable, Hashable {
    public let id: String
    public let warnings: [String]

    public init(id: String, warnings: [String]) {
        self.id = id
        self.warnings = warnings
    }
}

// MARK: - GET /networks

public struct APINetworkSummary: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let driver: String
    public let labels: [String: String]
    public let containers: [String: APIAttachedContainer]

    public init(
        id: String,
        name: String,
        driver: String,
        labels: [String: String],
        containers: [String: APIAttachedContainer]
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.labels = labels
        self.containers = containers
    }
}

public struct APIAttachedContainer: Codable, Sendable, Hashable {
    public let endpointID: String
    public let macAddress: String
    public let ipv4Address: String

    public init(endpointID: String, macAddress: String, ipv4Address: String) {
        self.endpointID = endpointID
        self.macAddress = macAddress
        self.ipv4Address = ipv4Address
    }
}

// MARK: - GET /events

/// CHAOS-1350 NDJSON lifecycle-event frame emitted by `GET /events`.
/// The wire shape stays intentionally flat so clients do not observe Swift enum
/// associated-value encoding details from `RuntimeContainerEvent`.
public struct APIEventFrame: Codable, Sendable, Hashable {
    public let type: String
    public let id: String
    public let timestamp: Date
    public let exitCode: Int32?
    public let signal: Int32?

    public init(
        type: String,
        id: String,
        timestamp: Date,
        exitCode: Int32?,
        signal: Int32?
    ) {
        self.type = type
        self.id = id
        self.timestamp = timestamp
        self.exitCode = exitCode
        self.signal = signal
    }
}

// MARK: - GET /events  (legacy Phase 2.A schema reservation)

public struct APIEvent: Codable, Sendable, Hashable {
    public let type: String
    public let action: String
    public let id: String
    public let time: Date
    public let attributes: [String: String]

    public init(
        type: String,
        action: String,
        id: String,
        time: Date,
        attributes: [String: String]
    ) {
        self.type = type
        self.action = action
        self.id = id
        self.time = time
        self.attributes = attributes
    }
}

// MARK: - GET /containers/{id}/logs

/// CHAOS-1350 NDJSON log frame emitted by `GET /containers/{id}/logs`.
/// `line` is UTF-8 text decoded from `RuntimeLogFrame.data`; `stream` is
/// derived from the runtime frame source (`stdout` / `stderr`).
public struct APILogFrame: Codable, Sendable, Hashable {
    public let stream: String
    public let timestamp: Date
    public let line: String

    public init(stream: String, timestamp: Date, line: String) {
        self.stream = stream
        self.timestamp = timestamp
        self.line = line
    }
}

// MARK: - Streaming deferral envelope

/// CHAOS-1350 501 response envelope for streaming routes whose backend is
/// intentionally deferred (currently stats, and runtime-specific events gaps).
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

// MARK: - GET /projects  (Compose-aware extension)

public struct APIProjectSummary: Codable, Sendable, Hashable {
    public let name: String
    public let serviceCount: Int
    public let runningCount: Int
    public let createdAt: Date?

    public init(name: String, serviceCount: Int, runningCount: Int, createdAt: Date?) {
        self.name = name
        self.serviceCount = serviceCount
        self.runningCount = runningCount
        self.createdAt = createdAt
    }
}

// MARK: - GET /projects/{name}/services  (Compose-aware extension)

public struct APIServiceSummary: Codable, Sendable, Hashable {
    public let project: String
    public let name: String
    public let container: APIContainerSummary

    public init(project: String, name: String, container: APIContainerSummary) {
        self.project = project
        self.name = name
        self.container = container
    }
}

// MARK: - Error envelope

public struct APIErrorResponse: Codable, Sendable, Hashable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}
