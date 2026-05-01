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
import NIOSSL

// MARK: - ComposeSystem

/// `container-compose system` — parent command for daemon lifecycle and
/// runtime-state inspection in CHAOS-1349.
///
/// Decision #5 keeps daemon startup manual: this command only groups the
/// lifecycle/status subcommands and shows help when invoked directly.
public struct ComposeSystem: AsyncParsableCommand {
    public static let configuration: CommandConfiguration = .init(
        commandName: "system",
        abstract: "Manage the container-compose daemon and runtime state",
        subcommands: [
            ComposeSystemStatus.self,
            SystemGenerateCert.self,
            SystemGenerateKey.self,
            SystemRevokeKey.self,
            SystemListKeys.self,
        ]
    )

    public init() {}
}

// MARK: - ComposeSystemStatus

/// `container-compose system status` — shell-friendly daemon liveness and
/// runtime-state probe for CHAOS-1349 / Decision #5.
///
/// The command exits 0 when the daemon is serving and 1 when it is not, so
/// scripts can branch on `container-compose system status` directly.
public struct ComposeSystemStatus: AsyncParsableCommand {
    public static let configuration: CommandConfiguration = .init(
        commandName: "status",
        abstract: "Report container-compose daemon liveness and runtime-state summary"
    )

    @Option(
        name: .customLong("socket"),
        help: "Path to the Unix domain socket. Default: ~/.container-compose/api.sock"
    )
    var socketPath: String?

    @Option(
        name: .customLong("address"),
        help: "Listen address to probe. Schemes: unix:///path, tcp://host:port, tls://host:port"
    )
    var addressURL: String?

    @Option(
        name: .customLong("cacert"),
        help: "CA certificate PEM file for TLS trust verification (used with tls:// addresses)"
    )
    var cacertPath: String?

    public init() {}

    public func run() async throws {
        // Resolve listen address — prefer --address, then --socket, then default unix socket
        let listen: ListenAddress
        if let rawURL = addressURL {
            listen = try ListenAddress.parse(rawURL)
        } else if let sock = socketPath {
            listen = .unix(path: ServeDaemon.resolveSocketPath(override: sock))
        } else {
            listen = .unix(path: ServeDaemon.defaultSocketPath)
        }

        let registryPath = ContainerRegistry.defaultStoragePath
        let registrySummary = await Self.registrySummary()

        switch listen {
        case .unix(let resolvedSocketPath):
            var daemonRunning = false
            let elapsed = ContinuousClock().measure {
                daemonRunning = ServeDaemon.isAlreadyServing(at: resolvedSocketPath)
            }

            if daemonRunning {
                print("Daemon:    running (connected in \(Self.milliseconds(for: elapsed))ms)")
                print("Socket:    \(resolvedSocketPath)")
                print("Registry:  \(registryPath) \(registrySummary)")
                print("Server:    \(Main.versionString)")
                return
            }

            let socketSuffix = FileManager.default.fileExists(atPath: resolvedSocketPath) ? " (stale)" : " (no file)"
            print("Daemon:    not running")
            print("Socket:    \(resolvedSocketPath)\(socketSuffix)")
            print("Registry:  \(registryPath) \(registrySummary)")
            print()
            print("To start the daemon: container-compose serve")
            throw ExitCode(1)

        case .tcp, .tls:
            let probeResult = await DaemonClient.probe(address: listen, cacertPath: cacertPath)
            switch probeResult {
            case .alive(let elapsedMs):
                print("Daemon:    running (responded to /_ping in \(elapsedMs)ms)")
                print("Address:   \(listen.description)")
                print("Registry:  \(registryPath) \(registrySummary)")
                print("Server:    \(Main.versionString)")
            case .unexpectedResponse(let status):
                print("Daemon:    unexpected response (HTTP \(status))")
                print("Address:   \(listen.description)")
                throw ExitCode(1)
            case .error(let message):
                print("Daemon:    not reachable — \(message)")
                print("Address:   \(listen.description)")
                throw ExitCode(1)
            }
        }
    }

    private static func milliseconds(for duration: Duration) -> Int {
        let components = duration.components
        let nanoseconds = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        return max(1, Int((Double(nanoseconds) / 1_000_000.0).rounded()))
    }

    private static func registrySummary() async -> String {
        do {
            let registry = try await ContainerRegistry()
            return "(\(await registry.list().count) containers)"
        } catch {
            return "(unreadable)"
        }
    }
}
