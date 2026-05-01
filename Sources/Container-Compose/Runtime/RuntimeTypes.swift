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

// MARK: - RuntimeListFilters

/// Selection criteria for `Runtime.list(filters:)`. Phase 1 surface is just
/// `.all`; Phase 2 extends with project / status / id-prefix filters as more
/// commands migrate off `ContainerClientProvider`.
public struct RuntimeListFilters: Sendable, Equatable {
    public static let all = RuntimeListFilters()
    public init() {}
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

    public static let `default` = RuntimeLogOptions(follow: false, tail: nil, since: nil)

    public init(follow: Bool, tail: Int?, since: Date?) {
        self.follow = follow
        self.tail = tail
        self.since = since
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

// MARK: - RuntimeCreateConfiguration

/// Minimum container creation surface needed to round-trip a Compose service
/// definition through the `Runtime` protocol. Phase 1 defines the shape so
/// `AppleContainerizationRuntime.create(...)` can be exercised by tests; Phase
/// 2 wires `compose up` through it.
public struct RuntimeCreateConfiguration: Sendable, Equatable {
    public let imageReference: String
    public let cpus: Int
    public let memoryInBytes: UInt64
    public let hostname: String?
    public let environment: [String]
    public let command: [String]
    public let workingDirectory: String?
    public let publishedPorts: [RuntimePublishedPort]

    public init(
        imageReference: String,
        cpus: Int = 1,
        memoryInBytes: UInt64 = 256 * 1024 * 1024,
        hostname: String? = nil,
        environment: [String] = [],
        command: [String] = [],
        workingDirectory: String? = nil,
        publishedPorts: [RuntimePublishedPort] = []
    ) {
        self.imageReference = imageReference
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
        self.hostname = hostname
        self.environment = environment
        self.command = command
        self.workingDirectory = workingDirectory
        self.publishedPorts = publishedPorts
    }
}
