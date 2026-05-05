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
import Hummingbird
import Testing
@testable import ContainerComposeCore

/// CHAOS-1421: regression coverage for `DaemonClient.probeUnixSocket`, which
/// replaces the legacy connect-and-immediately-close `UnixSocketProbe`.
/// The legacy probe triggered `NIOFcntlFailedError` noise in the daemon's
/// accept loop because Hummingbird tried to fcntl an fd that the client had
/// already torn down. The HTTP probe gives Hummingbird a real request to
/// process, eliminating the race.
@Suite(.serialized)
struct DaemonClientUnixSocketTests {

    private static func temporaryShortSocketPath() -> String {
        URL(fileURLWithPath: "/tmp")
            .appending(path: "container-compose-probe-test-\(UUID().uuidString)")
            .appending(path: "api.sock")
            .path
    }

    private static func removeTemporaryTree(for path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
    }

    private static func createParentDirectory(for path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    @Test("probe(.unix) returns .error when the socket file does not exist")
    func probeReturnsErrorWhenSocketMissing() async {
        let nonexistent = "/tmp/container-compose-probe-test-nonexistent-\(UUID().uuidString).sock"
        let result = await DaemonClient.probe(address: .unix(path: nonexistent))
        if case .error = result {
            // Expected: connection refused / no such file
        } else {
            Issue.record("Expected .error for missing socket, got \(result)")
        }
    }

    @Test("probeUnixSocket returns .error for an obviously invalid path")
    func probeRejectsInvalidPath() async {
        // Empty path — URL(httpURLWithSocketPath:) should reject or produce an
        // unreachable URL. Either way, the probe must surface as .error.
        let result = await DaemonClient.probeUnixSocket(path: "")
        if case .error = result {
            // Expected.
        } else {
            Issue.record("Expected .error for empty path, got \(result)")
        }
    }

    @Test("probe(.unix) returns .alive against a real Hummingbird daemon on a unix socket")
    func probeReturnsAliveAgainstRealDaemon() async throws {
        let path = Self.temporaryShortSocketPath()
        defer { Self.removeTemporaryTree(for: path) }
        try Self.createParentDirectory(for: path)

        let router = Router()
        ServeDaemon.registerCoreRoutes(router: router)
        let app = Application(
            router: router,
            configuration: .init(address: .unixDomainSocket(path: path))
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await app.runService()
            }

            // Give the server a moment to bind. The probe itself has a 5s
            // timeout so this small sleep is just to avoid a guaranteed race
            // on the first call.
            try await Task.sleep(for: .milliseconds(150))

            let result = await DaemonClient.probe(address: .unix(path: path))

            // Tear down the server task. cancelAll() wakes runService() out
            // of its accept loop.
            group.cancelAll()

            switch result {
            case .alive(let elapsedMs):
                #expect(elapsedMs >= 0)
            case .unexpectedResponse(let status):
                Issue.record("Expected .alive, got .unexpectedResponse(\(status))")
            case .error(let msg):
                Issue.record("Expected .alive, got .error(\(msg))")
            }
        }
    }
}
