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
    /// resolver. Network names mirror `NetworkingArgs.build`'s resolution
    /// (env-substitution + top-level `name:` override) so label keys and
    /// `dnsSidecar.perNetworkIPs` keys agree.
    enum LabelsArgs {
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []
            if let labels = ctx.service.labels {
                for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
                    args.append(contentsOf: ["--label", "\(key)=\(value)"])
                }
            }
            if let dnsSidecar = ctx.dnsSidecar, let serviceNetworks = ctx.service.networks {
                var dnsLabels: [(network: String, ip: String)] = []
                for (name, _) in serviceNetworks.entries {
                    let resolved = resolveVariable(name, with: ctx.environmentVariables)
                    let networkToConnect = ctx.dockerCompose.networks?[name]??.name ?? resolved
                    if let sidecarIP = dnsSidecar.perNetworkIPs[networkToConnect] {
                        dnsLabels.append((networkToConnect, sidecarIP))
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
