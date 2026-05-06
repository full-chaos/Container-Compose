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

// MARK: - RuntimeCreateNetworkSpec (CHAOS-1353)

/// Spec used to create a new network via `Runtime.createNetwork(spec:)`.
/// IPAM and driver metadata are optional; if omitted the backend assigns
/// defaults. The shape intentionally mirrors the subset of network-create flags
/// exposed by the full-chaos/container fork for compose-spec parity.
public struct RuntimeCreateNetworkSpec: Sendable, Equatable {
    public let name: String
    public let driver: String
    public let subnet: String?
    public let gateway: String?
    public let ipRange: String?
    public let auxAddresses: [String: String]
    public let driverOptions: [String: String]
    public let attachable: Bool
    public let enableIPv6: Bool
    public let isInternal: Bool
    public let labels: [String: String]

    public init(
        name: String,
        driver: String = "bridge",
        subnet: String? = nil,
        gateway: String? = nil,
        ipRange: String? = nil,
        auxAddresses: [String: String] = [:],
        driverOptions: [String: String] = [:],
        attachable: Bool = false,
        enableIPv6: Bool = false,
        isInternal: Bool = false,
        labels: [String: String] = [:]
    ) {
        self.name = name
        self.driver = driver
        self.subnet = subnet
        self.gateway = gateway
        self.ipRange = ipRange
        self.auxAddresses = auxAddresses
        self.driverOptions = driverOptions
        self.attachable = attachable
        self.enableIPv6 = enableIPv6
        self.isInternal = isInternal
        self.labels = labels
    }
}
