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

// MARK: - ListenAddress

/// A URL-shaped listen address for `container-compose serve --listen`.
///
/// Supports three schemes:
/// - `unix:///path` — Unix domain socket (default for local use)
/// - `tcp://host:port` — plain TCP (requires `--insecure` on non-localhost)
/// - `tls://host:port` — TLS-wrapped TCP (requires `--cert` + `--key`)
///
/// CHAOS-1359 (Phase 9 — TCP transport + TLS)
public enum ListenAddress: Sendable, Equatable {
    case unix(path: String)
    case tcp(host: String, port: Int)
    case tls(host: String, port: Int)

    // MARK: Parsing

    public static func parse(_ raw: String) throws -> ListenAddress {
        guard let url = URL(string: raw), let scheme = url.scheme else {
            throw ListenAddressError.malformed(raw)
        }
        switch scheme {
        case "unix":
            // URL(string:) parses unix:// URIs in different ways depending on form:
            //   unix:///abs/path    → host = nil,  path = "/abs/path"
            //   unix://~/.../path   → host = "~",  path = "/.../path"
            //   unix://~/path       → host = "~",  path = "/path"
            // We reconstruct the raw path from host + path components.
            let rawPath: String
            if let host = url.host, !host.isEmpty {
                // Re-join: host was probably part of the tilde prefix
                rawPath = host + url.path
            } else if !url.path.isEmpty {
                rawPath = url.path
            } else {
                // Fallback: strip the scheme prefix manually
                rawPath = String(raw.dropFirst("unix://".count))
            }
            let expanded = (rawPath as NSString).expandingTildeInPath
            return .unix(path: expanded)

        case "tcp", "tls":
            guard let host = url.host, !host.isEmpty, let port = url.port else {
                throw ListenAddressError.missingHostOrPort(raw)
            }
            return scheme == "tcp" ? .tcp(host: host, port: port) : .tls(host: host, port: port)

        default:
            throw ListenAddressError.unsupportedScheme(scheme)
        }
    }

    // MARK: Hummingbird BindAddress

    /// The `Hummingbird.BindAddress` corresponding to this listen address.
    public var bindAddress: BindAddress {
        switch self {
        case .unix(let p):
            return .unixDomainSocket(path: p)
        case .tcp(let h, let p), .tls(let h, let p):
            return .hostname(h, port: p)
        }
    }

    // MARK: Helpers

    public var requiresTLS: Bool {
        if case .tls = self { return true }
        return false
    }

    /// Returns `true` for Unix sockets and for TCP/TLS addresses bound to
    /// loopback addresses (`localhost`, `127.0.0.1`, `::1`).
    public var isLocalhost: Bool {
        switch self {
        case .unix:
            return true
        case .tcp(let h, _), .tls(let h, _):
            return h == "localhost" || h == "127.0.0.1" || h == "::1"
        }
    }

    // MARK: Display

    public var description: String {
        switch self {
        case .unix(let p): return "unix://\(p)"
        case .tcp(let h, let p): return "tcp://\(h):\(p)"
        case .tls(let h, let p): return "tls://\(h):\(p)"
        }
    }
}

// MARK: - ListenAddressError

public enum ListenAddressError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case missingHostOrPort(String)
    case unsupportedScheme(String)

    public var description: String {
        switch self {
        case .malformed(let raw):
            return "malformed listen address: '\(raw)' — expected unix:///path, tcp://host:port, or tls://host:port"
        case .missingHostOrPort(let raw):
            return "listen address '\(raw)' is missing host or port — expected tcp://host:port or tls://host:port"
        case .unsupportedScheme(let scheme):
            return "unsupported scheme '\(scheme)' in listen address — supported: unix, tcp, tls"
        }
    }
}
