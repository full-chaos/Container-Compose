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

import Foundation

extension ComposeUp {
    /// Emits `--label key=value` flags for each entry in `service.labels`.
    ///
    /// Labels are sorted by key so that the generated argv is deterministic
    /// across runs (important for tests and idempotent tooling).
    ///
    /// CHAOS-1493: also emits synthetic `compose.dns.resolvers.<network>=<ip>`
    /// labels recording which embedded-DNS sidecar IP this service container
    /// was created against, per network attachment. `specDivergenceReason`
    /// reads these on a subsequent `up` to detect sidecar-IP drift and force a
    /// service recreate so `/etc/resolv.conf` doesn't end up pointing at a dead
    /// resolver. Network names route through `resolveCanonicalNetworkName(_:dockerCompose:environmentVariables:)`
    /// (CHAOS-1495) so label keys, `--dns` lookup, divergence-read sets, and the
    /// sidecar's `perNetworkIPs` keys all agree on the same canonical string.
    ///
    /// CHAOS-1494: when a service has no `service.networks`, mirror the
    /// implicit-default-network attachment from `NetworkingArgs.build` and
    /// emit a `compose.dns.resolvers.<implicit>=<ip>` label so divergence
    /// detection works for implicit-network services on re-runs. The
    /// implicit name (`<projectName>-default`) is already canonical, so it
    /// does NOT need to route through `resolveCanonicalNetworkName`.
    enum LabelsArgs {
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []
            if let labels = ctx.service.labels {
                for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
                    args.append(contentsOf: ["--label", "\(key)=\(value)"])
                }
            }
            if let dnsSidecar = ctx.dnsSidecar {
                var dnsLabels: [(network: String, ip: String)] = []
                if let serviceNetworks = ctx.service.networks {
                    for (name, _) in serviceNetworks.entries {
                        // CHAOS-1495: route through the shared canonical resolver so
                        // label keys agree with `--dns` lookup, divergence-read sets,
                        // and the sidecar's `perNetworkIPs` keys.
                        let networkToConnect = resolveCanonicalNetworkName(
                            name,
                            dockerCompose: ctx.dockerCompose,
                            environmentVariables: ctx.environmentVariables
                        )
                        if let sidecarIP = dnsSidecar.perNetworkIPs[networkToConnect] {
                            dnsLabels.append((networkToConnect, sidecarIP))
                        }
                    }
                } else if let implicitNetwork = ctx.implicitDefaultNetwork,
                          ctx.service.network_mode == nil {
                    // CHAOS-1494: mirror the implicit-network attachment in
                    // NetworkingArgs so the divergence detector can match the
                    // sidecar IP across re-runs for services that omit
                    // `service.networks`. The implicit name is project-scoped
                    // (`<projectName>-default`) and synthesized in
                    // `ComposeUp.run()`, so it's already canonical and does not
                    // route through `resolveCanonicalNetworkName`.
                    if let sidecarIP = dnsSidecar.perNetworkIPs[implicitNetwork] {
                        dnsLabels.append((implicitNetwork, sidecarIP))
                    }
                }
                for (network, ip) in dnsLabels.sorted(by: { $0.network < $1.network }) {
                    args.append(contentsOf: ["--label", "compose.dns.resolvers.\(network)=\(ip)"])
                }
            }
            return args
        }
    }
}
