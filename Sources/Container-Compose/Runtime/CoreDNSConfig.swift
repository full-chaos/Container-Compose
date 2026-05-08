// v1 emits ONE zone per project. Aliases are project-wide. Per-network alias split is a v2 ticket.
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

public enum CoreDNSConfigError: Error, Equatable {
    case invalidProjectName(String)
    case invalidServiceName(String)
    case invalidAlias(String)
    case invalidIPAddress(String)
}

public enum CoreDNSConfig {
    public struct ServiceRecord: Hashable, Sendable, Codable {
        public let name: String
        public let ip: String
        public let aliases: [String]

        public init(name: String, ip: String, aliases: [String]) {
            self.name = name
            self.ip = ip
            self.aliases = aliases
        }
    }

    /// Derive a DNS-safe zone label from a compose project name (CHAOS-1475).
    ///
    /// Compose project names allow `[a-z0-9_-]` (with underscores), but DNS
    /// labels per RFC 1035 §2.3.1 only accept `[A-Za-z0-9-]` with no leading or
    /// trailing hyphen and at most 63 characters. This routine maps:
    ///   - non-allowed scalars → `-`
    ///   - lowercases the result (DNS labels are case-insensitive; lowercase is
    ///     the canonical zone-file form)
    ///   - collapses runs of `-` into a single `-`
    ///   - strips leading and trailing `-`
    ///   - clamps to 63 chars (re-stripping any trailing `-` exposed by the cut)
    ///
    /// Throws `invalidProjectName` only when the input contains zero
    /// characters that survive the mapping (e.g. "", "___", "...").
    public static func dnsZoneLabel(for projectName: String) throws -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(projectName.unicodeScalars.count)
        let hyphen: Unicode.Scalar = "-"
        for scalar in projectName.unicodeScalars {
            let v = scalar.value
            let isDigit = v >= 0x30 && v <= 0x39 // 0-9
            let isUpper = v >= 0x41 && v <= 0x5A // A-Z
            let isLower = v >= 0x61 && v <= 0x7A // a-z
            let isHyphen = v == 0x2D            // -
            scalars.append((isDigit || isUpper || isLower || isHyphen) ? scalar : hyphen)
        }
        var label = String(scalars).lowercased()
        while label.contains("--") {
            label = label.replacingOccurrences(of: "--", with: "-")
        }
        while label.hasPrefix("-") { label.removeFirst() }
        while label.hasSuffix("-") { label.removeLast() }
        if label.count > 63 {
            label = String(label.prefix(63))
            while label.hasSuffix("-") { label.removeLast() }
        }
        guard !label.isEmpty else {
            throw CoreDNSConfigError.invalidProjectName(projectName)
        }
        return label
    }

    /// Validate that `projectName` can produce a non-empty DNS-safe zone label.
    ///
    /// Permissive: accepts underscores, dots, slashes, mixed case — anything
    /// the compose project-name pipeline emits. Rejects only inputs that have
    /// no surviving alphanumerics (e.g. "", "___", "...").
    public static func validateProjectName(_ projectName: String) throws {
        _ = try dnsZoneLabel(for: projectName)
    }

    public static func makeCorefile(projectName: String, upstreamDNS: [String] = ["8.8.8.8", "1.1.1.1"]) throws -> String {
        let zoneLabel = try dnsZoneLabel(for: projectName)
        for ip in upstreamDNS {
            try validateIPv4(ip)
        }

        let zoneName = "\(zoneLabel).test"
        let upstream = upstreamDNS.joined(separator: " ")

        // Note: the on-disk zone file path keeps the raw compose project name
        // (`<projectName>.zone`) so the host filesystem layout matches what
        // EmbeddedDNSSidecar writes. The DNS-safe label only governs the zone
        // domain that CoreDNS serves and that other services resolve against.
        return [
            ". {",
            "    forward . \(upstream)",
            "    cache 30",
            "    log",
            "    errors",
            "}",
            "",
            "\(zoneName) {",
            "    file /etc/coredns/zones/\(projectName).zone {",
            "        reload 5s",
            "    }",
            "    log",
            "    errors",
            "}",
            ""
        ].joined(separator: "\n")
    }

    public static func makeZone(projectName: String, services: [ServiceRecord], serial: Int64) throws -> String {
        let zoneLabel = try dnsZoneLabel(for: projectName)

        let zoneName = "\(zoneLabel).test"
        var lines = [
            "$ORIGIN \(zoneName).",
            "$TTL 60",
            "@   IN SOA ns.\(zoneName). admin.\(zoneName). \(serial) 60 60 60 60",
            ""
        ]

        for service in services {
            try validateLabel(service.name, error: .invalidServiceName(service.name))
            try validateIPv4(service.ip)
            lines.append(recordLine(name: service.name, ip: service.ip))

            for alias in service.aliases {
                try validateLabel(alias, error: .invalidAlias(alias))
                lines.append(recordLine(name: alias, ip: service.ip, comment: "; alias of \(service.name)"))
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Returns the zone domain (`<dns-label>.test`) served by CoreDNS for the
    /// given compose project. Throws if the project name has no usable scalars.
    public static func zoneDomain(for projectName: String) throws -> String {
        let label = try dnsZoneLabel(for: projectName)
        return "\(label).test"
    }

    private static func recordLine(name: String, ip: String, comment: String? = nil) -> String {
        let paddedName = name.padding(toLength: 10, withPad: " ", startingAt: 0)
        var line = "\(paddedName) IN A   \(ip)"
        if let comment {
            line += "  \(comment)"
        }
        return line
    }

    private static func validateLabel(_ value: String, error: CoreDNSConfigError) throws {
        guard (1...63).contains(value.count) else {
            throw error
        }
        guard value.first != "-", value.last != "-" else {
            throw error
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw error
        }
    }

    private static func validateIPv4(_ value: String) throws {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            throw CoreDNSConfigError.invalidIPAddress(value)
        }

        for octet in octets {
            guard !octet.isEmpty, octet.allSatisfy({ $0.isNumber }), let number = Int(octet), (0...255).contains(number) else {
                throw CoreDNSConfigError.invalidIPAddress(value)
            }
        }
    }
}
