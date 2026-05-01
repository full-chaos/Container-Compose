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
import NIOSSL
import Testing
@testable import ContainerComposeCore

@Suite(.serialized)
struct TLSBootstrapClientCATests {

    private func writeTmpCerts() throws -> (certPath: String, keyPath: String, caPath: String, dir: URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "tls-client-ca-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let (certPEM, keyPEM) = try CertGenerator.generateSelfSigned()
        let certPath = tmpDir.appending(path: "cert.pem").path
        let keyPath = tmpDir.appending(path: "key.pem").path
        let caPath = tmpDir.appending(path: "ca.pem").path
        try Data(certPEM.utf8).write(to: URL(fileURLWithPath: certPath))
        try Data(keyPEM.utf8).write(to: URL(fileURLWithPath: keyPath))
        try Data(certPEM.utf8).write(to: URL(fileURLWithPath: caPath))
        return (certPath, keyPath, caPath, tmpDir)
    }

    @Test("clientCAPath enables full client certificate verification")
    func clientCAEnablesFullVerification() throws {
        let paths = try writeTmpCerts()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        let config = try TLSBootstrap.makeServerConfig(
            certPath: paths.certPath,
            keyPath: paths.keyPath,
            clientCAPath: paths.caPath
        )

        #expect(config.certificateVerification == .fullVerification)
        #expect(!config.additionalTrustRoots.isEmpty)
    }

    @Test("nil clientCAPath disables client certificate verification")
    func nilClientCADisablesVerification() throws {
        let paths = try writeTmpCerts()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        let config = try TLSBootstrap.makeServerConfig(
            certPath: paths.certPath,
            keyPath: paths.keyPath,
            clientCAPath: nil
        )

        #expect(config.certificateVerification == .none)
        #expect(config.additionalTrustRoots.isEmpty)
    }
}
