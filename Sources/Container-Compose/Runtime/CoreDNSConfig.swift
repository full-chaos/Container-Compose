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

    public static func validateProjectName(_ projectName: String) throws {
        try validateLabel(projectName, error: .invalidProjectName(projectName))
    }

    public static func makeCorefile(projectName: String, upstreamDNS: [String] = ["8.8.8.8", "1.1.1.1"]) throws -> String {
        try validateProjectName(projectName)
        for ip in upstreamDNS {
            try validateIPv4(ip)
        }

        let zoneName = zoneDomain(for: projectName)
        let upstream = upstreamDNS.joined(separator: " ")

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
        try validateProjectName(projectName)

        let zoneName = zoneDomain(for: projectName)
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

    private static func zoneDomain(for projectName: String) -> String {
        "\(projectName).test"
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
