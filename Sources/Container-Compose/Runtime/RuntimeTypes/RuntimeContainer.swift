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
