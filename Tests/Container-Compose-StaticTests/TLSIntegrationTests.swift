//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors.
// Apache License, Version 2.0
//===----------------------------------------------------------------------===//

import Foundation
import Hummingbird
import HummingbirdTLS
import HummingbirdTesting
import NIOSSL
import Testing
@testable import ContainerComposeCore
import TestHelpers

@Suite(.serialized)
struct TLSIntegrationTests {

    // MARK: - Helpers

    private func writeTmpCert() throws -> (certPath: String, keyPath: String, dir: URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "tls-int-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let (certPEM, keyPEM) = try CertGenerator.generateSelfSigned()
        let certPath = tmpDir.appending(path: "cert.pem").path
        let keyPath  = tmpDir.appending(path: "key.pem").path
        try Data(certPEM.utf8).write(to: URL(fileURLWithPath: certPath))
        try Data(keyPEM.utf8).write(to: URL(fileURLWithPath: keyPath))
        return (certPath, keyPath, tmpDir)
    }

    // MARK: - Tests

    @Test("TLS server responds 200 to /_ping via .ahc(.https)")
    func tlsServerPingRoute() async throws {
        let (certPath, keyPath, tmpDir) = try writeTmpCert()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tlsConfig = try TLSBootstrap.makeServerConfig(certPath: certPath, keyPath: keyPath)

        let router = Router()
        ServeDaemon.registerCoreRoutes(router: router)

        let app = Application(
            router: router,
            server: try .tls(.http1(), tlsConfiguration: tlsConfig),
            configuration: .init(serverName: "container-compose")
        )

        try await app.test(.ahc(.https)) { client in
            let response = try await client.execute(uri: "/_ping", method: .get)
            #expect(response.status == .ok)
        }
    }

    @Test("TLS server responds 200 to /version via .ahc(.https)")
    func tlsServerVersionRoute() async throws {
        let (certPath, keyPath, tmpDir) = try writeTmpCert()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tlsConfig = try TLSBootstrap.makeServerConfig(certPath: certPath, keyPath: keyPath)

        let router = Router()
        ServeDaemon.registerCoreRoutes(router: router)

        let app = Application(
            router: router,
            server: try .tls(.http1(), tlsConfiguration: tlsConfig),
            configuration: .init(serverName: "container-compose")
        )

        try await RuntimeEnvironment.$current.withValue(RecordingRuntime()) {
            try await app.test(.ahc(.https)) { client in
                let response = try await client.execute(uri: "/version", method: .get)
                #expect(response.status == .ok)
            }
        }
    }
}
