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

// MARK: POST /networks  (CHAOS-1353)

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
