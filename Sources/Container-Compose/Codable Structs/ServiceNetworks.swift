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

import Foundation

/// Per-network configuration for a service attachment.
///
/// Corresponds to the object form of a service's `networks:` entry:
/// ```yaml
/// networks:
///   mynet:
///     aliases: [a1, a2]
///     ipv4_address: 1.2.3.4
/// ```
public struct ServiceNetworkConfig: Codable, Hashable {
    /// DNS aliases for the container on this network.
    public let aliases: [String]?
    /// Static IPv4 address to assign.
    public let ipv4_address: String?
    /// Static IPv6 address to assign.
    public let ipv6_address: String?
    /// MAC address for the container on this network.
    public let mac_address: String?
    /// Network attach priority (higher = preferred).
    public let priority: Int?

    public init(
        aliases: [String]? = nil,
        ipv4_address: String? = nil,
        ipv6_address: String? = nil,
        mac_address: String? = nil,
        priority: Int? = nil
    ) {
        self.aliases = aliases
        self.ipv4_address = ipv4_address
        self.ipv6_address = ipv6_address
        self.mac_address = mac_address
        self.priority = priority
    }
}

/// The union type for `service.networks`, supporting both the list form
/// (`networks: [foo, bar]`) and the map/object form
/// (`networks: { foo: { aliases: [a1] } }`).
///
/// Ordering note: The list form preserves YAML declaration order.
/// The map form decodes into a dictionary and then sorts keys
/// alphabetically for deterministic output.
public struct ServiceNetworks: Codable, Hashable {
    /// Ordered network entries: (network name, optional config).
    public let entries: [(name: String, config: ServiceNetworkConfig)]

    /// Ordered list of network names (convenience accessor).
    public var names: [String] { entries.map(\.name) }

    /// Number of network entries — enables `.networks?.count` callsites.
    public var count: Int { entries.count }

    /// Returns true if `name` is in this collection — enables
    /// `.networks?.contains("foo")` callsites.
    public func contains(_ name: String) -> Bool {
        entries.contains(where: { $0.name == name })
    }

    public init(entries: [(name: String, config: ServiceNetworkConfig)]) {
        self.entries = entries
    }

    /// Convenience factory: construct from a plain list of names (empty config).
    public static func list(_ names: [String]) -> ServiceNetworks {
        ServiceNetworks(entries: names.map { ($0, ServiceNetworkConfig()) })
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        // Attempt 1: plain list of strings — `networks: [foo, bar]`
        if let names = try? decoder.singleValueContainer().decode([String].self) {
            entries = names.map { ($0, ServiceNetworkConfig()) }
            return
        }

        // Attempt 2: keyed map — `networks: { foo: { aliases: [...] } }`
        // Nil values (e.g., `foo:` with no sub-keys) are decoded as empty config.
        let keyed = try decoder.singleValueContainer().decode([String: ServiceNetworkConfig?].self)
        // Sort alphabetically for deterministic ordering.
        // keyed[key] is Optional<Optional<ServiceNetworkConfig>>:
        //   outer Optional = key presence, inner Optional = nil YAML value.
        // Flatten both nil cases to an empty config.
        entries = keyed.keys.sorted().map { key in
            (key, keyed[key].flatMap { $0 } ?? ServiceNetworkConfig())
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Encode as the map form for round-trip fidelity.
        var container = encoder.singleValueContainer()
        var dict: [String: ServiceNetworkConfig?] = [:]
        for (name, config) in entries {
            dict[name] = config
        }
        try container.encode(dict)
    }

    // MARK: - Hashable (tuples are not automatically Hashable)

    public static func == (lhs: ServiceNetworks, rhs: ServiceNetworks) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        return zip(lhs.entries, rhs.entries).allSatisfy { l, r in
            l.name == r.name && l.config == r.config
        }
    }

    public func hash(into hasher: inout Hasher) {
        for (name, config) in entries {
            hasher.combine(name)
            hasher.combine(config)
        }
    }
}
