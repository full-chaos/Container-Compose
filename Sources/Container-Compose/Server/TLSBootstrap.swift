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

import NIOSSL

// MARK: - TLSBootstrap

/// Builds `TLSConfiguration` objects for the Hummingbird TLS server.
///
/// CHAOS-1359 (Phase 9 — TCP transport + TLS)
enum TLSBootstrap {

    /// Build a server-side `TLSConfiguration` from PEM files on disk.
    ///
    /// - Parameters:
    ///   - certPath: Path to the PEM-encoded server certificate (chain).
    ///   - keyPath: Path to the PEM-encoded private key.
    ///   - clientCAPath: Optional path to a CA certificate for mutual TLS client
    ///     verification. When `nil`, client certificate verification is disabled.
    static func makeServerConfig(
        certPath: String,
        keyPath: String,
        clientCAPath: String? = nil
    ) throws -> TLSConfiguration {
        let certs = try NIOSSLCertificate.fromPEMFile(certPath)
            .map { NIOSSLCertificateSource.certificate($0) }
        let key = NIOSSLPrivateKeySource.privateKey(
            try NIOSSLPrivateKey(file: keyPath, format: .pem)
        )
        var cfg = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs,
            privateKey: key
        )
        if let ca = clientCAPath {
            cfg.certificateVerification = .fullVerification
            let caCerts = try NIOSSLCertificate.fromPEMFile(ca)
            cfg.additionalTrustRoots = [.certificates(caCerts)]
        } else {
            cfg.certificateVerification = .none
        }
        return cfg
    }
}
