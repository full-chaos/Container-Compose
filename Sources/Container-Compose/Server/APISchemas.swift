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

// MARK: - Error envelope (CHAOS-1357)

/// Unified error envelope for all 4xx/5xx responses.
/// Wire shape: `{"error":"<code>","message":"<human>","code":"<E_NNN>","requestId":"<id>"}`.
/// All route handlers should migrate from `APIErrorResponse` to this shape.
public struct APIErrorEnvelope: Codable, Sendable, Hashable, ResponseEncodable {
    /// Machine-readable error key (e.g. `"not_found"`, `"conflict"`).
    public let error: String
    /// Human-readable description safe to show in client UIs. Never leaks
    /// Swift error internals.
    public let message: String
    /// Short error code suitable for log indexing (e.g. `"E_404"`).
    public let code: String
    /// Correlates with `X-Request-Id` response header for log tracing.
    public let requestId: String

    public init(error: String, message: String, code: String, requestId: String) {
        self.error = error
        self.message = message
        self.code = code
        self.requestId = requestId
    }
}

public extension APIErrorEnvelope {
    /// Migration convenience — matches the status-oriented call sites across
    /// all route files. `code` defaults to `"E_<statusCode>"` when nil.
    static func legacy(
        _ status: HTTPResponse.Status,
        message: String,
        code: String? = nil,
        requestId: String
    ) -> APIErrorEnvelope {
        let resolvedCode = code ?? "E_\(status.code)"
        let errorKey: String
        switch status.code {
        case 400: errorKey = "bad_request"
        case 401: errorKey = "unauthorized"
        case 403: errorKey = "forbidden"
        case 404: errorKey = "not_found"
        case 408: errorKey = "request_timeout"
        case 409: errorKey = "conflict"
        case 501: errorKey = "not_supported"
        case 500: errorKey = "internal_error"
        default:  errorKey = "error"
        }
        return APIErrorEnvelope(error: errorKey, message: message, code: resolvedCode, requestId: requestId)
    }
}

// MARK: - Error envelope (legacy — deprecated)

/// Retained for source compatibility. Migrate call sites to `APIErrorEnvelope`.
@available(*, deprecated, message: "Use APIErrorEnvelope")
public struct APIErrorResponse: Codable, Sendable, Hashable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - Resource CRUD Schemas (CHAOS-1353)

// MARK: POST /networks

/// Request body for `POST /networks`. `subnet` and `gateway` are optional
/// CIDR/IP strings; if omitted the backend assigns them automatically.
/// Advanced IPAM (subnet pools, multiple subnets) is out of scope per CHAOS-1353.
public struct APICreateNetworkRequest: Codable, Sendable, Hashable {
    public let name: String
    public let driver: String?
    public let subnet: String?
    public let gateway: String?
    public let labels: [String: String]?

    public init(
        name: String,
        driver: String? = nil,
        subnet: String? = nil,
        gateway: String? = nil,
        labels: [String: String]? = nil
    ) {
        self.name = name
        self.driver = driver
        self.subnet = subnet
        self.gateway = gateway
        self.labels = labels
    }
}

/// Response body for `POST /networks` (201 Created).
public struct APICreateNetworkResponse: Codable, Sendable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: GET /volumes

public struct APIVolumeSummary: Codable, Sendable, Hashable {
    public let name: String
    public let driver: String
    public let labels: [String: String]
    public let createdAt: Date?

    public init(
        name: String,
        driver: String,
        labels: [String: String],
        createdAt: Date?
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
        self.createdAt = createdAt
    }
}

/// Envelope for `GET /volumes` to allow future addition of `warnings` /
/// `filters` fields without breaking the response shape.
public struct APIVolumeListResponse: Codable, Sendable, Hashable {
    public let volumes: [APIVolumeSummary]

    public init(volumes: [APIVolumeSummary]) {
        self.volumes = volumes
    }
}

// MARK: POST /volumes

public struct APICreateVolumeRequest: Codable, Sendable, Hashable {
    public let name: String
    public let driver: String?
    public let labels: [String: String]?

    public init(
        name: String,
        driver: String? = nil,
        labels: [String: String]? = nil
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
    }
}

// MARK: GET /secrets

public struct APISecretSummary: Codable, Sendable, Hashable {
    public let name: String
    public let labels: [String: String]
    public let createdAt: Date?

    public init(
        name: String,
        labels: [String: String],
        createdAt: Date?
    ) {
        self.name = name
        self.labels = labels
        self.createdAt = createdAt
    }
}

// MARK: POST /secrets

/// Request body for `POST /secrets`.
///
/// Secret body shape decision (CHAOS-1353 PR note):
/// - `value` is an inline UTF-8 string. The caller is responsible for reading
///   the file when `secret.file:` is specified in a Compose document and passing
///   the contents as `value`. The server does NOT accept a `filePath` parameter —
///   file I/O on the server side would require the daemon to have access to the
///   client's local filesystem, which is not guaranteed in production deployments.
///   This matches how Docker handles `POST /secrets` (value-in-body only).
/// - `labels` is optional metadata for secret grouping / filtering.
public struct APICreateSecretRequest: Codable, Sendable, Hashable {
    public let name: String
    public let value: String
    public let labels: [String: String]?

    public init(
        name: String,
        value: String,
        labels: [String: String]? = nil
    ) {
        self.name = name
        self.value = value
        self.labels = labels
    }
}

/// Response body for `POST /secrets` (201 Created).
/// The secret `value` is intentionally omitted — it is never echoed back.
public struct APICreateSecretResponse: Codable, Sendable, Hashable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

// MARK: - Project Lifecycle Schemas (CHAOS-1360)

// MARK: POST /projects/{name}/up

/// Request body for `POST /projects/{name}/up`.
/// All fields are optional; `detached` defaults to `true` (run services in the
/// background — the standard compose up mode). `profiles` filters which services
/// participate. `build` rebuilds images before starting. `pull` controls the
/// pull policy.
public struct APIProjectUpRequest: Codable, Sendable, Hashable {
    /// When `true` (default) services start detached; the route returns once all
    /// containers reach the `.running` state. When `false` the caller is expected
    /// to stream logs separately; the route still returns 200 once containers are
    /// running (no indefinite block — a separate logs follow-up is needed).
    public let detached: Bool?
    /// Compose profiles to activate. Nil means activate no profiles (only
    /// services without `profiles:` declarations start).
    public let profiles: [String]?
    /// When `true`, rebuild images before starting (equivalent to `--build`).
    public let build: Bool?
    /// Pull policy: `"always"`, `"missing"`, `"never"`. Nil uses the service's
    /// declared `pull_policy` (or `"missing"` as the built-in default).
    public let pull: String?

    public init(
        detached: Bool? = nil,
        profiles: [String]? = nil,
        build: Bool? = nil,
        pull: String? = nil
    ) {
        self.detached = detached
        self.profiles = profiles
        self.build = build
        self.pull = pull
    }
}

/// Per-service state entry in `APIProjectUpResponse`.
public struct APIProjectServiceState: Codable, Sendable, Hashable {
    public let service: String
    public let containerId: String
    public let status: String

    public init(service: String, containerId: String, status: String) {
        self.service = service
        self.containerId = containerId
        self.status = status
    }
}

/// Response body for `POST /projects/{name}/up` (200 OK).
public struct APIProjectUpResponse: Codable, Sendable, Hashable {
    public let project: String
    public let services: [APIProjectServiceState]

    public init(project: String, services: [APIProjectServiceState]) {
        self.project = project
        self.services = services
    }
}

// MARK: POST /projects/{name}/down

/// Request body for `POST /projects/{name}/down`.
public struct APIProjectDownRequest: Codable, Sendable, Hashable {
    /// When `true`, also remove named volumes declared in the compose file.
    /// Defaults to `false`.
    public let removeVolumes: Bool?
    /// When `true` (default), stop and remove containers not declared in the
    /// compose file but sharing the project name prefix.
    public let removeOrphans: Bool?
    /// Seconds to wait for each container to stop gracefully before SIGKILL.
    public let timeout: Int?

    public init(removeVolumes: Bool? = nil, removeOrphans: Bool? = nil, timeout: Int? = nil) {
        self.removeVolumes = removeVolumes
        self.removeOrphans = removeOrphans
        self.timeout = timeout
    }
}

/// Response body for `POST /projects/{name}/down` (200 OK).
public struct APIProjectDownResponse: Codable, Sendable, Hashable {
    public let project: String
    public let stopped: [String]
    public let removed: [String]

    public init(project: String, stopped: [String], removed: [String]) {
        self.project = project
        self.stopped = stopped
        self.removed = removed
    }
}

// MARK: POST /projects/{name}/restart

/// Request body for `POST /projects/{name}/restart`.
public struct APIProjectRestartRequest: Codable, Sendable, Hashable {
    /// Restrict restart to named services. Nil or empty means restart all
    /// services in the project.
    public let services: [String]?
    /// Seconds to wait for each container to stop gracefully before SIGKILL.
    public let timeout: Int?

    public init(services: [String]? = nil, timeout: Int? = nil) {
        self.services = services
        self.timeout = timeout
    }
}

/// Response body for `POST /projects/{name}/restart` (200 OK).
public struct APIProjectRestartResponse: Codable, Sendable, Hashable {
    public let project: String
    public let restarted: [String]

    public init(project: String, restarted: [String]) {
        self.project = project
        self.restarted = restarted
    }
}

// MARK: POST /projects/{name}/build  (NDJSON streaming)

/// Request body for `POST /projects/{name}/build`.
/// Response is NDJSON `APIProjectBuildFrame` lines, `Content-Type: application/x-ndjson`.
public struct APIProjectBuildRequest: Codable, Sendable, Hashable {
    /// Restrict build to named services. Nil or empty means build all services
    /// with a `build:` block.
    public let services: [String]?
    /// Skip the layer cache.
    public let noCache: Bool?
    /// Pull fresh base images before building.
    public let pull: Bool?

    public init(services: [String]? = nil, noCache: Bool? = nil, pull: Bool? = nil) {
        self.services = services
        self.noCache = noCache
        self.pull = pull
    }
}

/// One NDJSON line emitted by `POST /projects/{name}/build`.
public struct APIProjectBuildFrame: Codable, Sendable, Hashable {
    /// The service being built.
    public let service: String
    /// Log line from the build output (stdout/stderr merged).
    public let line: String
    /// ISO-8601 timestamp.
    public let timestamp: Date
    /// `"log"` during the build, `"done"` on success, `"error"` on failure.
    public let type: String

    public init(service: String, line: String, timestamp: Date, type: String) {
        self.service = service
        self.line = line
        self.timestamp = timestamp
        self.type = type
    }
}

// MARK: POST /projects/{name}/pull  (NDJSON streaming)

/// Request body for `POST /projects/{name}/pull`.
/// Response is NDJSON `APIProjectPullFrame` lines.
public struct APIProjectPullRequest: Codable, Sendable, Hashable {
    /// Restrict pull to named services. Nil or empty means pull all services.
    public let services: [String]?
    /// When `true`, continue pulling other services even if one fails.
    public let ignoreFailures: Bool?

    public init(services: [String]? = nil, ignoreFailures: Bool? = nil) {
        self.services = services
        self.ignoreFailures = ignoreFailures
    }
}

/// One NDJSON line emitted by `POST /projects/{name}/pull`.
public struct APIProjectPullFrame: Codable, Sendable, Hashable {
    /// The service whose image is being pulled.
    public let service: String
    /// Image reference being pulled.
    public let image: String
    /// Timestamp of this frame.
    public let timestamp: Date
    /// `"pulling"` while in progress, `"done"` on success, `"error"` on failure.
    public let type: String
    /// Optional progress or error message.
    public let message: String?

    public init(service: String, image: String, timestamp: Date, type: String, message: String? = nil) {
        self.service = service
        self.image = image
        self.timestamp = timestamp
        self.type = type
        self.message = message
    }
}

// MARK: POST /projects/{name}/services/{service}/scale

/// Request body for `POST /projects/{name}/services/{service}/scale`.
public struct APIProjectScaleRequest: Codable, Sendable, Hashable {
    /// Desired number of replicas for the service.
    public let replicas: Int

    public init(replicas: Int) {
        self.replicas = replicas
    }
}

/// Response body for `POST /projects/{name}/services/{service}/scale` (200 OK).
public struct APIProjectScaleResponse: Codable, Sendable, Hashable {
    public let project: String
    public let service: String
    public let replicas: Int
    /// Container IDs now running for this service.
    public let containers: [String]

    public init(project: String, service: String, replicas: Int, containers: [String]) {
        self.project = project
        self.service = service
        self.replicas = replicas
        self.containers = containers
    }
}

// MARK: - Lifecycle Schemas (CHAOS-1354)

/// Request body for `POST /containers/{id}/stop`.
/// All fields are optional; omitted fields fall back to `RuntimeStopOptions.default`
/// (signal 15 / SIGTERM, 10 s timeout).
public struct APIStopRequest: Codable, Sendable, Hashable {
    /// POSIX signal number to send before force-killing. Defaults to 15 (SIGTERM).
    public let signal: Int32?
    /// Seconds to wait for the container to stop gracefully before SIGKILL. Defaults to 10.
    public let timeoutSeconds: Int?

    public init(signal: Int32?, timeoutSeconds: Int?) {
        self.signal = signal
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Request body for `POST /containers/{id}/kill`.
/// If omitted the body defaults to signal 9 (SIGKILL).
public struct APIKillRequest: Codable, Sendable, Hashable {
    /// POSIX signal number to deliver. Defaults to 9 (SIGKILL).
    public let signal: Int32?

    public init(signal: Int32?) {
        self.signal = signal
    }
}

/// Response body for `POST /containers/{id}/wait`.
/// Returns the exit code and the time the container exited.
public struct APIWaitResponse: Codable, Sendable, Hashable {
    public let exitCode: Int32
    public let exitedAt: Date

    public init(exitCode: Int32, exitedAt: Date) {
        self.exitCode = exitCode
        self.exitedAt = exitedAt
    }
}
