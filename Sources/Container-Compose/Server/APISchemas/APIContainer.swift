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

// MARK: - POST /containers/create  (CHAOS-1352 v2 — shipped)

/// Request body for `POST /containers/create`. All fields except `image` are
/// optional; sensible defaults are applied by `RuntimeCreateConfiguration`.
///
/// `publishedPorts` accepts host→container port mappings that are forwarded to
/// `RuntimeCreateConfiguration.publishedPorts`. The `proto` field defaults to
/// `"tcp"` when omitted.
///
/// Decision #9 v2: the body covers the minimal Compose-driven field set.
/// Labels, networks, and volumes are deliberately omitted from Phase 6:
/// - labels: no label-passing surface on `RuntimeContainer` yet (Phase 3 TODO)
/// - networks: created/attached separately via POST /networks (CHAOS-1353)
/// - volumes: bound separately via POST /volumes (CHAOS-1353)
public struct APICreateContainerRequest: Codable, Sendable, Hashable {
    public let image: String
    public let name: String?
    public let cpus: Int?
    public let memoryBytes: UInt64?
    public let hostname: String?
    public let env: [String]?
    public let cmd: [String]?
    public let workingDir: String?
    /// Port mappings to publish. Each entry becomes a `RuntimePublishedPort` in
    /// `RuntimeCreateConfiguration.publishedPorts`.
    public let publishedPorts: [APICreatePortMapping]?

    public init(
        image: String,
        name: String? = nil,
        cpus: Int? = nil,
        memoryBytes: UInt64? = nil,
        hostname: String? = nil,
        env: [String]? = nil,
        cmd: [String]? = nil,
        workingDir: String? = nil,
        publishedPorts: [APICreatePortMapping]? = nil
    ) {
        self.image = image
        self.name = name
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.hostname = hostname
        self.env = env
        self.cmd = cmd
        self.workingDir = workingDir
        self.publishedPorts = publishedPorts
    }
}

/// Port mapping entry in `APICreateContainerRequest.publishedPorts`.
/// `proto` defaults to `"tcp"` when absent; `hostAddress` defaults to `"0.0.0.0"`.
public struct APICreatePortMapping: Codable, Sendable, Hashable {
    public let hostPort: UInt16
    public let containerPort: UInt16
    public let proto: String?
    public let hostAddress: String?

    public init(
        hostPort: UInt16,
        containerPort: UInt16,
        proto: String? = nil,
        hostAddress: String? = nil
    ) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
        self.hostAddress = hostAddress
    }
}

public struct APICreateContainerResponse: Codable, Sendable, Hashable {
    public let id: String
    public let warnings: [String]

    public init(id: String, warnings: [String] = []) {
        self.id = id
        self.warnings = warnings
    }
}
