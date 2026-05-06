//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
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

import ContainerAPIClient
import Foundation

// Shared helpers for `RemoteRuntime` argv preparation, consumed by
// `ComposeUp`, `ComposeCreate`, and `ComposeRun`. The `imageAndEntrypointTail`
// signature accepts a `cliCommand` override (default empty) so that
// `compose run`'s positional-arg-suppresses-entrypoint semantics can flow
// through the same canonical implementation.
extension ComposeCommand {
    /// Merge per-service environment over a base environment dictionary
    /// (typically the command's accumulated env-file/CLI variables) and emit
    /// a sorted `KEY=VALUE` list ready for `RemoteRuntime` argv handoff.
    func remoteEnvironment(for service: Service, baseEnvironment: [String: String]) -> [String] {
        var merged = baseEnvironment
        for (key, value) in service.environment ?? [:] {
            merged[key] = value
        }
        return merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// Parse `service.ports` strings into structured `RuntimePublishedPort`
    /// values for the remote runtime. Drops malformed entries; the
    /// host-address always defaults to `0.0.0.0` since the remote runtime
    /// binds via the daemon's public interface.
    func remotePublishedPorts(for service: Service) -> [RuntimePublishedPort] {
        (service.ports ?? []).compactMap { raw in
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let hostPart = String(parts[parts.count - 2])
            let containerPart = String(parts[parts.count - 1])
            guard
                let hostPort = UInt16(hostPart),
                let containerPort = UInt16(containerPart.split(separator: "/").first ?? "")
            else { return nil }
            let proto = containerPart.hasSuffix("/udp") ? RuntimePortProtocol.udp : .tcp
            return RuntimePublishedPort(
                hostAddress: "0.0.0.0",
                hostPort: hostPort,
                containerPort: containerPort,
                proto: proto
            )
        }
    }

    /// Build the trailing argv fragment for a `container run`/`container create`
    /// invocation: `[--entrypoint <first>?, <image>, <remaining entrypoint>…, <command>…]`.
    ///
    /// `cliCommand` (default empty) honors `compose run`'s positional override:
    /// when a non-empty CLI command is supplied, the service entrypoint and
    /// command are both suppressed and the CLI tokens become positional args
    /// after the image. With an empty `cliCommand`, the function reduces to
    /// the standard `compose up` / `compose create` shape:
    /// - `entrypoint: [a, b, c]`, `command: [d, e]` → `[--entrypoint, a, <image>, b, c, d, e]`
    /// - `entrypoint: [/app/foo.sh]`, no command   → `[--entrypoint, /app/foo.sh, <image>]`
    /// - no entrypoint, `command: [d, e]`          → `[<image>, d, e]`
    /// - neither                                    → `[<image>]`
    static func imageAndEntrypointTail(
        image: String,
        cliCommand: [String] = [],
        entrypoint: [String]?,
        command: [String]?
    ) -> [String] {
        // `compose run [--] CMD…` overrides both entrypoint and command.
        if !cliCommand.isEmpty {
            return [image] + cliCommand
        }

        var tail: [String] = []
        var positional: [String] = []

        if let entrypoint, let first = entrypoint.first {
            tail.append("--entrypoint")
            tail.append(first)
            // Remaining entrypoint tokens are positional args to the entrypoint
            // and must appear *after* the image.
            positional.append(contentsOf: entrypoint.dropFirst())
        }

        tail.append(image)
        tail.append(contentsOf: positional)

        // `command` is appended after entrypoint args per the compose spec.
        if let command {
            tail.append(contentsOf: command)
        }

        return tail
    }
}
