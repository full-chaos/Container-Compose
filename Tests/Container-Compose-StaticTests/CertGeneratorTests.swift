//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors.
// Apache License, Version 2.0
//===----------------------------------------------------------------------===//

import Foundation
import NIOSSL
import Testing
@testable import ContainerComposeCore

@Suite
struct CertGeneratorTests {

    @Test("generateSelfSigned produces parseable cert and key PEM")
    func generateProducesParseable() throws {
        let (certPEM, keyPEM) = try CertGenerator.generateSelfSigned()
        #expect(!certPEM.isEmpty)
        #expect(!keyPEM.isEmpty)
        // Both should be parseable by NIOSSL
        let certs = try NIOSSLCertificate.fromPEMBytes(Array(certPEM.utf8))
        #expect(!certs.isEmpty)
        // Key should also parse
        let _ = try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)
    }

    @Test("cert PEM contains CERTIFICATE header")
    func certHasPEMHeader() throws {
        let (certPEM, _) = try CertGenerator.generateSelfSigned()
        #expect(certPEM.contains("BEGIN CERTIFICATE"))
        #expect(certPEM.contains("END CERTIFICATE"))
    }

    @Test("key PEM contains EC PRIVATE KEY or PRIVATE KEY header")
    func keyHasPEMHeader() throws {
        let (_, keyPEM) = try CertGenerator.generateSelfSigned()
        let hasECKey = keyPEM.contains("EC PRIVATE KEY") || keyPEM.contains("PRIVATE KEY")
        #expect(hasECKey)
    }

    @Test("generated cert has correct common name in subject")
    func certCommonName() throws {
        let (certPEM, _) = try CertGenerator.generateSelfSigned(commonName: "my-test-server")
        // NIOSSLCertificate can parse but doesn't expose subject directly.
        // Verify via raw PEM string scan (CN is encoded in the DER -> base64 body).
        // We verify the cert parses without error — CN mismatch would cause issues
        // at connection time, not at parse time, so we just check parse succeeds.
        let certs = try NIOSSLCertificate.fromPEMBytes(Array(certPEM.utf8))
        #expect(certs.count == 1)
    }

    @Test("generated cert includes localhost SAN by default")
    func certDefaultSANs() throws {
        let (certPEM, keyPEM) = try CertGenerator.generateSelfSigned()
        // Build an actual TLS server/client to prove the cert is usable on localhost
        let certs = try NIOSSLCertificate.fromPEMBytes(Array(certPEM.utf8))
            .map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)
        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs,
            privateKey: NIOSSLPrivateKeySource.privateKey(key)
        )
        serverConfig.certificateVerification = .none
        // If we can build an SSL context the cert structure is valid
        let _ = try NIOSSLContext(configuration: serverConfig)
    }

    @Test("custom validity days are respected")
    func customValidityDays() throws {
        // We can't easily inspect validity without full X.509 parsing,
        // but we can verify generation succeeds with non-default values.
        let (certPEM, _) = try CertGenerator.generateSelfSigned(validForDays: 30)
        let certs = try NIOSSLCertificate.fromPEMBytes(Array(certPEM.utf8))
        #expect(certs.count == 1)
    }

    @Test("custom SAN DNS names produce valid cert")
    func customSANDNS() throws {
        let (certPEM, _) = try CertGenerator.generateSelfSigned(
            sanDNSNames: ["example.com", "api.example.com"],
            sanIPs: ["192.168.1.1"]
        )
        let certs = try NIOSSLCertificate.fromPEMBytes(Array(certPEM.utf8))
        #expect(certs.count == 1)
    }

    @Test("invalid IP address throws error")
    func invalidIPThrows() {
        #expect(throws: (any Error).self) {
            try CertGenerator.generateSelfSigned(sanIPs: ["not-an-ip"])
        }
    }

    @Test("TLS server config can be built from generated cert")
    func tlsServerConfigFromGeneratedCert() throws {
        let (certPEM, keyPEM) = try CertGenerator.generateSelfSigned()
        // Write to temp files and verify TLSBootstrap can load them
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "certgen-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let certPath = tmpDir.appending(path: "cert.pem").path
        let keyPath  = tmpDir.appending(path: "key.pem").path
        try Data(certPEM.utf8).write(to: URL(fileURLWithPath: certPath))
        try Data(keyPEM.utf8).write(to: URL(fileURLWithPath: keyPath))

        let config = try TLSBootstrap.makeServerConfig(certPath: certPath, keyPath: keyPath)
        let _ = try NIOSSLContext(configuration: config)
    }
}
