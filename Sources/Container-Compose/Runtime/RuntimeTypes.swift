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

// MARK: - RuntimeContainer

/// A container as observed by the `Runtime` abstraction. CHAOS-1346 Phase 1:
/// this type intentionally does NOT leak any apple/containerization
/// (`LinuxContainer`) or apple/container (`ContainerSnapshot`) types into the
/// public surface. Conformers translate their backend's representation into
/// this neutral shape so call sites stay portable across runtime backends.
///
/// Field set is the minimum required by `compose ps` (NAME / IMAGE / STATUS /
/// PORTS) plus enough state to support `compose ls` and event correlation.
/// Phase 2/3 will extend this as more commands migrate.
public struct RuntimeContainer: Sendable, Hashable, Codable {
    public let id: String
    public let imageReference: String
    public let status: RuntimeContainerStatus
    public let publishedPorts: [RuntimePublishedPort]
    public let createdAt: Date?
    public let startedAt: Date?
    public let lastExitCode: Int32?

    public init(
        id: String,
        imageReference: String,
        status: RuntimeContainerStatus,
        publishedPorts: [RuntimePublishedPort] = [],
        createdAt: Date? = nil,
        startedAt: Date? = nil,
        lastExitCode: Int32? = nil
    ) {
        self.id = id
        self.imageReference = imageReference
        self.status = status
        self.publishedPorts = publishedPorts
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.lastExitCode = lastExitCode
    }
}

// MARK: - RuntimeContainerStatus

/// Lifecycle status reported by a `Runtime` conformer. Mirrors the upstream
/// `ContainerResource.RuntimeStatus` cases (unknown / stopped / running /
/// stopping) plus `created` and `exited` which the bridge cannot distinguish
/// today but `AppleContainerizationRuntime` can synthesize from
/// `ContainerLifecycleState`.
public enum RuntimeContainerStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case unknown
    case created
    case running
    case stopping
    case stopped
    case exited
}

// MARK: - RuntimePublishedPort

/// Host → container port forwarding declaration. Matches the four fields the
/// `compose ps` output table renders.
public struct RuntimePublishedPort: Sendable, Hashable, Codable {
    public let hostAddress: String
    public let hostPort: UInt16
    public let containerPort: UInt16
    public let proto: RuntimePortProtocol
    public let count: UInt16

    public init(
        hostAddress: String,
        hostPort: UInt16,
        containerPort: UInt16,
        proto: RuntimePortProtocol,
        count: UInt16 = 1
    ) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
        self.count = count
    }
}

public enum RuntimePortProtocol: String, Sendable, Hashable, Codable, CaseIterable {
    case tcp
    case udp
}

// MARK: - RuntimeVersion

/// Backend-neutral version payload returned by `Runtime.version()`. CHAOS-1347
/// Phase 2 route handlers use this as the runtime-side source of truth for the
/// Container REST API version endpoint while keeping HTTP response DTOs separate
/// from runtime metadata.
///
/// `apiVersion` and `serverName` are container-compose API constants;
/// `daemonVersion`, `backendDescription`, and `arch` are supplied by each
/// conformer so clients can distinguish the bridge backend from the native
/// apple/containerization backend without importing backend packages.
public struct RuntimeVersion: Sendable, Hashable, Codable {
    public let apiVersion: String
    public let daemonVersion: String
    public let serverName: String
    public let backendDescription: String
    public let arch: String

    public init(
        apiVersion: String,
        daemonVersion: String,
        serverName: String,
        backendDescription: String,
        arch: String
    ) {
        self.apiVersion = apiVersion
        self.daemonVersion = daemonVersion
        self.serverName = serverName
        self.backendDescription = backendDescription
        self.arch = arch
    }
}

// MARK: - RuntimeNetwork

/// Minimal runtime-side network representation returned by
/// `Runtime.listNetworks()`. The HTTP API layer owns richer response mapping;
/// this type only records the identity and attachment details that can be
/// shared across the bridge and native backends during CHAOS-1347 Phase 2.
///
/// IPAM fields (`subnet`, `gateway`) are carried here so that post-create
/// round-trip assertions are possible in tests and route handlers. Both real
/// conformers (`BridgeContainerClientRuntime`, `AppleContainerizationRuntime`)
/// currently throw `.notSupported` for `createNetwork`, so these fields are
/// populated only by `MockRuntime` in Phase 1. When a real conformer wires
/// network creation it should plumb the IPAM values from the upstream response;
/// if the upstream API does not expose them the fields should remain `nil` and
/// the limitation documented as an abstraction leak. (CHAOS-1409)
public struct RuntimeNetwork: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let driver: String
    /// IPv4 subnet in CIDR notation (e.g. `"172.20.0.0/16"`). `nil` when the
    /// backend assigns the subnet automatically or when the upstream API does not
    /// surface IPAM details in the inspect/list response.
    public let subnet: String?
    /// IPv4 gateway address (e.g. `"172.20.0.1"`). `nil` under the same
    /// conditions as `subnet`.
    public let gateway: String?
    public let labels: [String: String]
    public let attachedContainerIds: [String]

    public init(
        id: String,
        name: String,
        driver: String,
        subnet: String? = nil,
        gateway: String? = nil,
        labels: [String: String] = [:],
        attachedContainerIds: [String] = []
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.subnet = subnet
        self.gateway = gateway
        self.labels = labels
        self.attachedContainerIds = attachedContainerIds
    }
}

// MARK: - RuntimeListFilters

/// Selection criteria for `Runtime.list(filters:)`. Phase 1 surface is just
/// `.all`; CHAOS-1347 Phase 2 adds status and name-prefix filters for route
/// handlers migrating off `ContainerClientProvider`.
///
/// Empty `status` arrays and empty `namePrefix` strings are normalized as no
/// filter by conformers, preserving `.all` semantics for callers that construct
/// filters from optional query parameters.
public struct RuntimeListFilters: Sendable, Equatable {
    public static let all = RuntimeListFilters()
    public let status: [RuntimeContainerStatus]?
    public let namePrefix: String?

    public init(
        status: [RuntimeContainerStatus]? = nil,
        namePrefix: String? = nil
    ) {
        self.status = status
        self.namePrefix = namePrefix
    }

    public func matches(_ container: RuntimeContainer) -> Bool {
        if let status, !status.isEmpty, !status.contains(container.status) {
            return false
        }
        if let namePrefix, !namePrefix.isEmpty, !container.id.hasPrefix(namePrefix) {
            return false
        }
        return true
    }
}

// MARK: - RuntimeStopOptions

public struct RuntimeStopOptions: Sendable, Equatable {
    public let signal: Int32
    public let timeoutSeconds: Int

    public static let `default` = RuntimeStopOptions(signal: 15, timeoutSeconds: 10)

    public init(signal: Int32, timeoutSeconds: Int) {
        self.signal = signal
        self.timeoutSeconds = timeoutSeconds
    }
}

// MARK: - RuntimeExitStatus

public struct RuntimeExitStatus: Sendable, Hashable, Codable {
    public let exitCode: Int32
    public let exitedAt: Date

    public init(exitCode: Int32, exitedAt: Date) {
        self.exitCode = exitCode
        self.exitedAt = exitedAt
    }
}

// MARK: - RuntimeContainerEvent

/// Synthesized lifecycle event emitted by `Runtime` conformers at create /
/// start / stop / kill / wait / remove call sites. The upstream
/// `apple/containerization` library has no native event stream; the
/// `AppleContainerizationRuntime` conformer wraps every lifecycle entry point
/// to produce these. The bridge conformer (Phase 1) does not emit these
/// natively but will forward upstream `ContainerEvent` translations in Phase 2
/// when more lifecycle paths migrate.
public enum RuntimeContainerEvent: Sendable, Hashable {
    case created(id: String, at: Date)
    case started(id: String, at: Date)
    case stopped(id: String, exitCode: Int32, at: Date)
    case killed(id: String, signal: Int32, at: Date)
    case oomKilled(id: String, at: Date)
    case removed(id: String, at: Date)
}

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

// MARK: - RuntimeLogOptions / RuntimeLogFrame

public struct RuntimeLogOptions: Sendable, Equatable {
    public let follow: Bool
    public let tail: Int?
    public let since: Date?
    public let timestamps: Bool

    public static let `default` = RuntimeLogOptions(follow: false, tail: nil, since: nil, timestamps: false)

    public init(follow: Bool, tail: Int?, since: Date?, timestamps: Bool = false) {
        self.follow = follow
        self.tail = tail
        self.since = since
        self.timestamps = timestamps
    }
}

public struct RuntimeLogFrame: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case stdout
        case stderr
    }
    public let timestamp: Date
    public let source: Source
    public let data: Data

    public init(timestamp: Date, source: Source, data: Data) {
        self.timestamp = timestamp
        self.source = source
        self.data = data
    }
}

// MARK: - Build / Pull (CHAOS-1425, Leak #14)

/// Per-image input to `Runtime.pull(specs:ignoreFailures:)`. Carries the
/// service label that owns the image (so the route layer can attribute frames
/// back to a specific service), the image reference itself, and an optional
/// platform string. The platform mirrors the existing `pullImage()` helper's
/// `--platform` argument; nil falls back to `defaultRuntimePlatform()` inside
/// the conformer.
public struct RuntimePullSpec: Sendable, Hashable {
    public let service: String
    public let imageReference: String
    public let platform: String?

    public init(service: String, imageReference: String, platform: String? = nil) {
        self.service = service
        self.imageReference = imageReference
        self.platform = platform
    }
}

/// One frame emitted by `Runtime.pull(...)`. Coarse-grained — one `started`
/// and one `completed` (or `failed`) per spec — because the upstream
/// `ImagePull` is invoked via the in-process `.swiftAPI` seam and prints its
/// per-blob progress directly to host stdout (`ProgressBar`), bypassing
/// `RunCommandRunner`'s onStdout callback. Per-line progress is a CHAOS-1425
/// follow-up: it requires either bypassing `RunCommandRunner` to call
/// `ClientImage.pull(progressUpdate:)` directly, or capturing host stdout
/// while the in-process command runs. Neither is in scope for this PR.
public struct RuntimePullEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case started
        case completed
        case failed
    }
    public let timestamp: Date
    public let service: String
    public let imageReference: String
    public let kind: Kind
    /// Optional message — populated on `failed` (the error description) and
    /// nil-able on success frames for forward-compat extension.
    public let message: String?

    public init(
        timestamp: Date,
        service: String,
        imageReference: String,
        kind: Kind,
        message: String? = nil
    ) {
        self.timestamp = timestamp
        self.service = service
        self.imageReference = imageReference
        self.kind = kind
        self.message = message
    }
}

/// Per-service input to `Runtime.build(specs:)`. The daemon's container
/// registry does not track Dockerfile paths or build-context directories — a
/// `BuildCommand` invocation needs both. Until CHAOS-1426 (compose-file upload
/// via daemon API) lands, conformers throw `RuntimeError.notSupported(...)`
/// from `build(...)` even when this spec is constructed; the route layer
/// translates that to the existing "Build not supported via daemon API" frame.
public struct RuntimeBuildSpec: Sendable, Hashable {
    public let service: String
    public let imageTag: String?
    public let contextPath: String?
    public let dockerfile: String?
    public let noCache: Bool
    public let pullBaseImages: Bool

    public init(
        service: String,
        imageTag: String? = nil,
        contextPath: String? = nil,
        dockerfile: String? = nil,
        noCache: Bool = false,
        pullBaseImages: Bool = false
    ) {
        self.service = service
        self.imageTag = imageTag
        self.contextPath = contextPath
        self.dockerfile = dockerfile
        self.noCache = noCache
        self.pullBaseImages = pullBaseImages
    }
}

/// One frame emitted by `Runtime.build(...)`. Same coarse-grained shape as
/// `RuntimePullEvent` — see that doc comment for the `.swiftAPI` constraint.
public struct RuntimeBuildEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case started
        case completed
        case failed
        /// Emitted when the runtime cannot build (e.g., no build context
        /// available because compose-file upload — CHAOS-1426 — has not
        /// landed). The route layer maps this to the existing "Build not
        /// supported via daemon API — use CLI" frame for backward compat.
        case notSupported
    }
    public let timestamp: Date
    public let service: String
    public let kind: Kind
    public let message: String?

    public init(
        timestamp: Date,
        service: String,
        kind: Kind,
        message: String? = nil
    ) {
        self.timestamp = timestamp
        self.service = service
        self.kind = kind
        self.message = message
    }
}

// MARK: - Runtime command execution

public struct RuntimeExecOptions: Sendable, Hashable, Codable {
    public let detach: Bool
    public let interactive: Bool
    public let tty: Bool
    public let environment: [String]
    public let user: String?
    public let workingDirectory: String?

    public init(
        detach: Bool = false,
        interactive: Bool = true,
        tty: Bool = true,
        environment: [String] = [],
        user: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.detach = detach
        self.interactive = interactive
        self.tty = tty
        self.environment = environment
        self.user = user
        self.workingDirectory = workingDirectory
    }
}

public struct RuntimeExecResult: Sendable, Hashable, Codable {
    public let stdout: [String]
    public let stderr: [String]
    public let exitCode: Int32

    public init(stdout: [String] = [], stderr: [String] = [], exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct RuntimeProcessList: Sendable, Hashable, Codable {
    public let containerId: String
    public let output: [String]

    public init(containerId: String, output: [String]) {
        self.containerId = containerId
        self.output = output
    }
}

public struct RuntimeImagePushResult: Sendable, Hashable, Codable {
    public let imageReference: String
    public let stdout: [String]
    public let stderr: [String]
    public let exitCode: Int32

    public init(imageReference: String, stdout: [String] = [], stderr: [String] = [], exitCode: Int32) {
        self.imageReference = imageReference
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

// MARK: - RuntimeVolume (CHAOS-1353)

/// Runtime-side volume representation for `Runtime.listVolumes()` /
/// `createVolume()` / `removeVolume(name:)`. Volume names are the canonical
/// key; no UUIDs are used (mirrors the Compose-spec where a volume is
/// identified by its name under `volumes:`). The `driver` field is `local` for
/// all volumes in Phase 8; other drivers are out of scope per the CHAOS-1353
/// ticket boundary.
public struct RuntimeVolume: Sendable, Hashable, Codable {
    public let name: String
    public let driver: String
    public let labels: [String: String]
    public let createdAt: Date?

    public init(
        name: String,
        driver: String = "local",
        labels: [String: String] = [:],
        createdAt: Date? = nil
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
        self.createdAt = createdAt
    }
}

/// Spec used to create a new volume via `Runtime.createVolume(spec:)`.
public struct RuntimeCreateVolumeSpec: Sendable, Equatable {
    public let name: String
    public let driver: String
    public let labels: [String: String]
    public let driverOptions: [String: String]

    public init(
        name: String,
        driver: String = "local",
        labels: [String: String] = [:],
        driverOptions: [String: String] = [:]
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
        self.driverOptions = driverOptions
    }
}

// MARK: - RuntimeSecret (CHAOS-1353)

/// Runtime-side secret representation for `Runtime.listSecrets()` /
/// `createSecret()` / `removeSecret(name:)`. The secret value is stored
/// only during creation (`RuntimeCreateSecretSpec.value`); subsequent
/// `listSecrets()` / `get` calls never reveal the value in the runtime model
/// (mirrors real secret stores). Phase 8 ships only the in-memory MockRuntime
/// implementation; a durable backend (keychain, file-based) is a follow-up.
public struct RuntimeSecret: Sendable, Hashable, Codable {
    public let name: String
    public let labels: [String: String]
    public let createdAt: Date?

    public init(
        name: String,
        labels: [String: String] = [:],
        createdAt: Date? = nil
    ) {
        self.name = name
        self.labels = labels
        self.createdAt = createdAt
    }
}

/// Spec used to create a new secret via `Runtime.createSecret(spec:)`.
/// The value is provided inline as a UTF-8 string. File-path sourcing
/// (Compose `secret.file:`) is the caller's responsibility — the route
/// handler reads the file and passes the content here.
public struct RuntimeCreateSecretSpec: Sendable, Equatable {
    public let name: String
    public let value: String
    public let labels: [String: String]

    public init(
        name: String,
        value: String,
        labels: [String: String] = [:]
    ) {
        self.name = name
        self.value = value
        self.labels = labels
    }
}

// MARK: - RuntimeNetworkSpec (CHAOS-1353)

/// Spec used to create a new network via `Runtime.createNetwork(spec:)`.
/// Subnet and gateway are optional; if omitted the backend assigns them
/// automatically. Advanced IPAM (subnet pools, multiple subnets) is out of
/// scope per the CHAOS-1353 ticket boundary.
public struct RuntimeCreateNetworkSpec: Sendable, Equatable {
    public let name: String
    public let driver: String
    public let subnet: String?
    public let gateway: String?
    public let labels: [String: String]

    public init(
        name: String,
        driver: String = "bridge",
        subnet: String? = nil,
        gateway: String? = nil,
        labels: [String: String] = [:]
    ) {
        self.name = name
        self.driver = driver
        self.subnet = subnet
        self.gateway = gateway
        self.labels = labels
    }
}

// MARK: - RuntimeCapabilities (CHAOS-1407)

/// Linux capability adjustments declared by a Compose service's `cap_add` /
/// `cap_drop` fields. Combined into a single optional value on
/// `RuntimeCreateConfiguration` so a nil means "no capability adjustment"
/// (the runtime uses its default set).
///
/// Conformers that cannot apply capabilities (e.g. the bridge backend in Phase
/// 1) ignore this field; a Phase 2 ticket wires it through the native API.
public struct RuntimeCapabilities: Sendable, Equatable {
    /// Capabilities to add beyond the runtime default set (e.g. `NET_ADMIN`).
    public let add: [String]
    /// Capabilities to drop from the runtime default set (e.g. `ALL`).
    public let drop: [String]

    public init(add: [String] = [], drop: [String] = []) {
        self.add = add
        self.drop = drop
    }
}

// MARK: - RuntimeCreateConfiguration

/// Minimum container creation surface needed to round-trip a Compose service
/// definition through the `Runtime` protocol. Phase 1 defines the shape so
/// `AppleContainerizationRuntime.create(...)` can be exercised by tests; Phase
/// 2 wires `compose up` through it.
///
/// Security fields added in CHAOS-1407 (`capabilities`, `securityOpt`,
/// `readOnly`, `user`, `groupAdd`, `privileged`) are spec-only for now —
/// conformers that cannot apply them ignore them gracefully. A follow-up
/// ticket wires them through the native-API and bridge runtime paths.
public struct RuntimeCreateConfiguration: Sendable, Equatable {
    public let imageReference: String
    public let cpus: Int
    public let memoryInBytes: UInt64
    public let hostname: String?
    public let environment: [String]
    public let command: [String]
    public let workingDirectory: String?
    public let publishedPorts: [RuntimePublishedPort]

    // MARK: Security fields (CHAOS-1407)

    /// Linux capability adjustments (`cap_add` / `cap_drop`). `nil` means no
    /// adjustment — use the runtime's default capability set.
    public let capabilities: RuntimeCapabilities?

    /// Security options passed via Compose `security_opt` (e.g.
    /// `"no-new-privileges:true"`). `nil` or empty means no overrides.
    ///
    /// Note: apple/container does not expose a `--security-opt` flag; the
    /// field is carried here so future backends can apply it.
    public let securityOpt: [String]?

    /// Mount the container's root filesystem read-only (`read_only: true`).
    /// `nil` and `false` both mean writable (current behaviour unchanged).
    public let readOnly: Bool?

    /// UID (or `user:group`) to run the container process as (`user:` field).
    /// `nil` means use the image default.
    public let user: String?

    /// Additional supplementary groups for the container user (`group_add`).
    /// `nil` or empty means no additions.
    ///
    /// Note: apple/container does not expose a `--group-add` flag; carried
    /// here for future backends.
    public let groupAdd: [String]?

    /// Run the container in privileged mode (`privileged: true`). `nil` and
    /// `false` both mean non-privileged.
    ///
    /// Note: apple/container does not expose a `--privileged` flag; carried
    /// here for future backends.
    public let privileged: Bool?

    public init(
        imageReference: String,
        cpus: Int = 1,
        memoryInBytes: UInt64 = 256 * 1024 * 1024,
        hostname: String? = nil,
        environment: [String] = [],
        command: [String] = [],
        workingDirectory: String? = nil,
        publishedPorts: [RuntimePublishedPort] = [],
        capabilities: RuntimeCapabilities? = nil,
        securityOpt: [String]? = nil,
        readOnly: Bool? = nil,
        user: String? = nil,
        groupAdd: [String]? = nil,
        privileged: Bool? = nil
    ) {
        self.imageReference = imageReference
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
        self.hostname = hostname
        self.environment = environment
        self.command = command
        self.workingDirectory = workingDirectory
        self.publishedPorts = publishedPorts
        self.capabilities = capabilities
        self.securityOpt = securityOpt
        self.readOnly = readOnly
        self.user = user
        self.groupAdd = groupAdd
        self.privileged = privileged
    }
}
