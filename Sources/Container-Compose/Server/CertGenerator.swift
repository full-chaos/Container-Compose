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

import Crypto
import Foundation
import SwiftASN1
import X509

#if canImport(Darwin)
import Darwin
#endif

// MARK: - CertGenerator

/// Generates a self-signed P-256 TLS certificate + private key in PEM format.
///
/// The certificate includes:
/// - BasicConstraints (critical, not a CA)
/// - KeyUsage (digitalSignature + keyEncipherment)
/// - ExtendedKeyUsage (serverAuth)
/// - SubjectAlternativeNames (configurable DNS names + IP literals)
///
/// CHAOS-1359 (Phase 9 — TCP transport + TLS)
enum CertGenerator {

    // MARK: - Error

    enum CertGeneratorError: Error, CustomStringConvertible {
        case invalidIPAddress(String)

        var description: String {
            switch self {
            case .invalidIPAddress(let ip):
                return "invalid IP address for SAN: '\(ip)'"
            }
        }
    }

    // MARK: - Generation

    /// Generate a self-signed certificate and private key pair.
    ///
    /// - Parameters:
    ///   - commonName: The CN for the certificate's subject / issuer DN.
    ///   - validForDays: Validity duration in days from now.
    ///   - sanDNSNames: DNS name SAN entries (default: `["localhost"]`).
    ///   - sanIPs: IP literal SAN entries (default: `["127.0.0.1", "::1"]`).
    /// - Returns: A tuple of `(certPEM, keyPEM)` strings.
    static func generateSelfSigned(
        commonName: String = "container-compose",
        validForDays: Int = 365,
        sanDNSNames: [String] = ["localhost"],
        sanIPs: [String] = ["127.0.0.1", "::1"]
    ) throws -> (certPEM: String, keyPEM: String) {
        // 1. Generate P-256 key pair
        let p256Key = P256.Signing.PrivateKey()
        let issuerKey = Certificate.PrivateKey(p256Key)
        let pubKey    = Certificate.PublicKey(p256Key.publicKey)

        // 2. Build distinguished name
        let dn = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("container-compose")
        }

        // 3. Build SAN entries
        let dnsEntries: [GeneralName] = sanDNSNames.map { .dnsName($0) }
        let ipEntries: [GeneralName] = try sanIPs.map { ip in
            guard let bytes = ipBytes(ip) else {
                throw CertGeneratorError.invalidIPAddress(ip)
            }
            return .ipAddress(ASN1OctetString(contentBytes: bytes))
        }
        let san = SubjectAlternativeNames(dnsEntries + ipEntries)

        // 4. Build extensions
        let now = Date()
        let extensions = try Certificate.Extensions {
            Critical(
                BasicConstraints.notCertificateAuthority
            )
            Critical(
                KeyUsage(digitalSignature: true, keyEncipherment: true)
            )
            try ExtendedKeyUsage([.serverAuth])
            san
        }

        // 5. Build certificate (auto-selects ECDSA-SHA256 for P-256 key)
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: pubKey,
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(Double(validForDays) * 86_400),
            issuer: dn,
            subject: dn,
            extensions: extensions,
            issuerPrivateKey: issuerKey
        )

        // 6. Serialize to PEM
        let certPEM = try cert.serializeAsPEM().pemString
        let keyPEM  = try issuerKey.serializeAsPEM().pemString

        return (certPEM, keyPEM)
    }
}

// MARK: - IP byte packing helper

/// Pack an IPv4 or IPv6 literal string into its 4-byte or 16-byte wire form.
/// Returns `nil` on parse failure so callers can emit a proper error.
private func ipBytes(_ ip: String) -> ArraySlice<UInt8>? {
    var v4 = in_addr()
    if inet_pton(AF_INET, ip, &v4) == 1 {
        var bytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: v4) { src in
            for i in 0..<4 { bytes[i] = src[i] }
        }
        return ArraySlice(bytes)
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, ip, &v6) == 1 {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: v6) { src in
            for i in 0..<16 { bytes[i] = src[i] }
        }
        return ArraySlice(bytes)
    }
    return nil
}
