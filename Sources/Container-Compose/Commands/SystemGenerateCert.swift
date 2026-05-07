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

import ArgumentParser
import Foundation
import SystemPackage

// MARK: - SystemGenerateCert

/// `container-compose system generate-cert` — generate a self-signed P-256
/// TLS certificate + key pair for use with `serve --listen tls://...`.
///
/// CHAOS-1359 (Phase 9 — TCP transport + TLS)
public struct SystemGenerateCert: AsyncParsableCommand {
    public static let configuration: CommandConfiguration = .init(
        commandName: "generate-cert",
        abstract: "Generate a self-signed TLS certificate and private key"
    )

    @Option(
        name: .customLong("out-dir"),
        help: "Directory to write cert.pem and key.pem. Default: ~/.container-compose"
    )
    var outDir: String = "~/.container-compose"

    @Option(
        name: .customLong("cn"),
        help: "Certificate common name. Default: container-compose"
    )
    var commonName: String = "container-compose"

    @Option(
        name: .customLong("days"),
        help: "Certificate validity in days. Default: 365"
    )
    var days: Int = 365

    @Option(
        name: .customLong("san-dns"),
        help: "DNS SAN entry (repeatable). Default: localhost"
    )
    var sanDNS: [String] = []

    @Option(
        name: .customLong("san-ip"),
        help: "IP SAN entry (repeatable). Default: 127.0.0.1, ::1"
    )
    var sanIP: [String] = []

    @Flag(
        name: .customLong("force"),
        help: "Overwrite existing cert.pem and key.pem"
    )
    var force: Bool = false

    public init() {}

    public func run() async throws {
        try RuntimeModeSupport.requireLocalOnly(operation: "system generate-cert")

        let expandedDir = (outDir as NSString).expandingTildeInPath
        let certPath = FilePath(expandedDir).appending("cert.pem").string
        let keyPath  = FilePath(expandedDir).appending("key.pem").string

        // Check for existing files
        let certExists = FileManager.default.fileExists(atPath: certPath)
        let keyExists  = FileManager.default.fileExists(atPath: keyPath)
        if (certExists || keyExists) && !force {
            let existing = [certExists ? certPath : nil, keyExists ? keyPath : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
            throw ExitError("Files already exist: \(existing). Use --force to overwrite.")
        }

        // Resolve SAN lists — fall back to defaults when not provided
        let dnsNames = sanDNS.isEmpty ? ["localhost"] : sanDNS
        let ipNames  = sanIP.isEmpty  ? ["127.0.0.1", "::1"] : sanIP

        // Generate cert + key
        let (certPEM, keyPEM) = try CertGenerator.generateSelfSigned(
            commonName: commonName,
            validForDays: days,
            sanDNSNames: dnsNames,
            sanIPs: ipNames
        )

        // Ensure output directory exists
        try FileManager.default.createDirectory(
            atPath: expandedDir,
            withIntermediateDirectories: true
        )

        // Write files with correct permissions
        // cert.pem: 0644 (world-readable — clients need it for trust anchor)
        // key.pem:  0600 (owner-only — private key must stay secret)
        try write(string: certPEM, to: certPath, mode: 0o644)
        try write(string: keyPEM,  to: keyPath,  mode: 0o600)

        print("Certificate: \(certPath)")
        print("Private key: \(keyPath)")
        print()
        print("To use, run:")
        print("  container-compose serve --listen tls://localhost:8443 --cert \(certPath) --key \(keyPath)")
    }

    // MARK: - Helpers

    private func write(string: String, to path: String, mode: mode_t) throws {
        let data = Data(string.utf8)
        try data.write(to: URL(filePath: path), options: .atomic)
        // Set permissions explicitly — Data.write uses umask
        guard chmod(path, mode) == 0 else {
            throw ExitError("Failed to set file permissions on \(path): \(String(cString: strerror(errno)))")
        }
    }
}

// MARK: - ExitError

/// A simple ValidationError-shaped type that exits with message + code 1.
private struct ExitError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

extension ExitError: LocalizedError {
    var errorDescription: String? { description }
}
