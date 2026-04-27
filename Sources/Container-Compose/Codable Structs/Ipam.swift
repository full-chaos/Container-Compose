//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
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

//
//  Ipam.swift
//  container-compose-app
//
//  Created as part of Phase 5B — Network IPAM and Volume driver pass-through.
//

/// A single IPAM configuration block (subnet, ip_range, gateway, aux_addresses).
public struct IpamConfig: Codable, Hashable {
    /// Subnet in CIDR notation, e.g. "10.0.0.0/24"
    public let subnet: String?
    /// IP range within the subnet, e.g. "10.0.0.128/25"
    public let ip_range: String?
    /// Gateway address for the subnet, e.g. "10.0.0.1"
    public let gateway: String?
    /// Auxiliary addresses (host → IP) reserved in this subnet
    public let aux_addresses: [String: String]?

    public init(
        subnet: String? = nil,
        ip_range: String? = nil,
        gateway: String? = nil,
        aux_addresses: [String: String]? = nil
    ) {
        self.subnet = subnet
        self.ip_range = ip_range
        self.gateway = gateway
        self.aux_addresses = aux_addresses
    }
}

/// Top-level IPAM block for a network definition.
public struct Ipam: Codable, Hashable {
    /// IPAM driver name (e.g. "default")
    public let driver: String?
    /// List of IPAM configuration entries
    public let config: [IpamConfig]?
    /// Driver-specific options
    public let options: [String: String]?

    public init(
        driver: String? = nil,
        config: [IpamConfig]? = nil,
        options: [String: String]? = nil
    ) {
        self.driver = driver
        self.config = config
        self.options = options
    }
}
