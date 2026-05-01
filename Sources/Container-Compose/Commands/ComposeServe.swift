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
import Hummingbird
import Logging
import ServiceLifecycle

#if canImport(Darwin)
import Darwin
#endif

// MARK: - ComposeServe

/// `container-compose serve` — long-running HTTP daemon exposing the Container
/// REST API over a Unix domain socket.
///
/// CHAOS-1349 ships the lifecycle skeleton: socket bind / unlink, idempotence
/// detection, signal-safe graceful shutdown, and a single `/_ping` route as
/// proof-of-life. CHAOS-1347 (Phase 2) plugs the remaining routes into this
/// skeleton.
///
/// Daemon model is **manual** (Decision #5 in `docs/plans/native-api-server.md`):
/// users start the daemon explicitly; it does not auto-spawn from `compose up`,
/// and a launchd LaunchAgent is a deferred follow-up. Foreground only — Ctrl-C
/// or `kill -TERM <pid>` triggers graceful shutdown.
public struct ComposeServe: AsyncParsableCommand {
    public static let configuration: CommandConfiguration = .init(
        commandName: "serve",
        abstract: "Start the container-compose HTTP API daemon over a Unix domain socket"
    )

    @Option(
        name: .customLong("socket"),
        help: "Path to the Unix domain socket. Default: ~/.container-compose/api.sock"
    )
    var socketPath: String?

    public init() {}

    public func run() async throws {
        let resolved = ServeDaemon.resolveSocketPath(override: socketPath)

        if ServeDaemon.isAlreadyServing(at: resolved) {
            print("container-compose daemon already running on \(resolved)")
            return
        }

        try ServeDaemon.cleanupStaleSocketIfNeeded(at: resolved)
        try ServeDaemon.ensureParentDirectory(for: resolved)

        try await ServeDaemon.run(socketPath: resolved)
    }
}

// MARK: - ServeDaemon

/// Lifecycle implementation extracted from `ComposeServe` for testability.
/// Pure helpers (path resolution, stale-socket cleanup, idempotence detection)
/// are exercised by `DaemonLifecycleTests` without binding a real socket; the
/// HTTP route surface is exercised by `Application(.testing)`.
public enum ServeDaemon {

    // MARK: - Defaults

    /// Default socket path: `~/.container-compose/api.sock`. Co-located with
    /// the Phase 1 registry (`~/.container-compose/registry.json`) so all
    /// daemon state lives in one user-owned directory — easier to debug,
    /// easier to reset (`rm -rf ~/.container-compose`).
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".container-compose")
            .appending(path: "api.sock")
            .path
    }

    public static func resolveSocketPath(override: String?) -> String {
        guard let override, !override.isEmpty else {
            return defaultSocketPath
        }
        return (override as NSString).expandingTildeInPath
    }

    // MARK: - Idempotence + stale-socket detection

    /// Returns `true` iff a daemon is currently bound to `socketPath` and
    /// accepting connections. False covers both "no socket file" and
    /// "leftover stale file from a crashed daemon".
    ///
    /// Uses BSD socket connect(2) directly rather than HTTP layer to keep
    /// the check cheap and dependency-light: a dead-but-bound socket would
    /// also report as alive at the HTTP layer, which is the right answer
    /// for idempotence ("don't try to bind again").
    public static func isAlreadyServing(at socketPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        return UnixSocketProbe.canConnect(to: socketPath)
    }

    /// Remove a leftover socket file iff it exists and nothing is bound to it.
    /// Caller must invoke `isAlreadyServing` FIRST and only proceed when it
    /// returns false.
    public static func cleanupStaleSocketIfNeeded(at socketPath: String) throws {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        try FileManager.default.removeItem(atPath: socketPath)
    }

    public static func ensureParentDirectory(for socketPath: String) throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Run

    /// Build the Hummingbird `Application` + `ServiceGroup` and run until
    /// SIGTERM/SIGINT. A sibling `SocketCleanupService` unlinks the socket
    /// file on graceful shutdown after Hummingbird drains its requests.
    public static func run(socketPath: String) async throws {
        let logger = Logger(label: "container-compose.serve")

        let router = Router()
        registerCoreRoutes(router: router)

        let app = Application(
            router: router,
            configuration: .init(
                address: .unixDomainSocket(path: socketPath),
                serverName: "container-compose"
            ),
            logger: logger
        )

        let cleanup = SocketCleanupService(socketPath: socketPath, logger: logger)

        let appConfig = ServiceGroupConfiguration.ServiceConfiguration(
            service: app,
            successTerminationBehavior: .gracefullyShutdownGroup,
            failureTerminationBehavior: .gracefullyShutdownGroup
        )
        let cleanupConfig = ServiceGroupConfiguration.ServiceConfiguration(service: cleanup)

        let group = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: [appConfig, cleanupConfig],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: logger
            )
        )

        print("container-compose daemon listening on \(socketPath)")
        print("(send SIGTERM or Ctrl-C for graceful shutdown)")

        try await group.run()
    }

    // MARK: - Routes

    /// Register the lifecycle-only routes that ship in Phase 2.0. Phase 2
    /// (CHAOS-1347) extends this with the rest of the Container REST API.
    public static func registerCoreRoutes(router: Router<BasicRequestContext>) {
        router.get("/_ping") { _, _ in
            PingResponse(
                ok: true,
                server: "container-compose",
                version: Main.version
            )
        }
    }
}

// MARK: - SocketCleanupService

/// Sibling `Service` that handles socket-file cleanup on graceful shutdown.
/// Hummingbird's `Application` (also in the ServiceGroup) drains in-flight
/// requests when shutdown is signaled; this service unlinks the socket file
/// after that drain completes. Registry persistence is already atomic on
/// every write (`ContainerRegistry.writeToDisk`) so no additional flush is
/// needed in Phase 2.0 — reserved for Phase 2 if in-memory caches grow.
struct SocketCleanupService: ServiceLifecycle.Service {
    let socketPath: String
    let logger: Logger

    func run() async throws {
        try await withGracefulShutdownHandler {
            try await Task.sleep(for: .seconds(60 * 60 * 24 * 365 * 100))
        } onGracefulShutdown: {
            do {
                if FileManager.default.fileExists(atPath: socketPath) {
                    try FileManager.default.removeItem(atPath: socketPath)
                    logger.info("Unlinked socket at \(socketPath)")
                }
            } catch {
                logger.warning("Failed to unlink socket at \(socketPath): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - PingResponse

/// Response body for `GET /_ping`. Identifies as `container-compose` —
/// never `Docker` — so ecosystem tooling that fingerprints `/version` cannot
/// mistake us for a Docker daemon (per Decision #3 in the architecture doc).
public struct PingResponse: Codable, Sendable, ResponseEncodable {
    public let ok: Bool
    public let server: String
    public let version: String

    public init(ok: Bool, server: String, version: String) {
        self.ok = ok
        self.server = server
        self.version = version
    }
}

// MARK: - UnixSocketProbe

/// BSD-socket connect probe used by `ServeDaemon.isAlreadyServing`.
/// Isolated here so the `sockaddr_un.sun_path` byte-tuple manipulation
/// (Swift's import of fixed-size C arrays) doesn't leak into the daemon
/// surface.
enum UnixSocketProbe {
    /// Attempts a single non-blocking-style `connect(2)` to a Unix domain
    /// socket. Returns true iff the connect succeeds. False covers
    /// ECONNREFUSED (stale socket), ENOENT (no file — caller should have
    /// checked first), and any path-too-long failure.
    static func canConnect(to path: String) -> Bool {
        let pathBytes = Array(path.utf8)
        var addr = sockaddr_un()
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxPathLen else { return false }

        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            let bytePtr = UnsafeMutableRawPointer(tuplePtr)
                .assumingMemoryBound(to: UInt8.self)
            for (i, byte) in pathBytes.enumerated() { bytePtr[i] = byte }
            bytePtr[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}
