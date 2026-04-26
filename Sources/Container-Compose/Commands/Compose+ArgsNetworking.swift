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
    /// Networking, DNS, and host/port flags: ports, networks (string list
    /// form), hostname. Phase 2C / 3B add dns / dns_opt / dns_search /
    /// extra_hosts / domainname / expose / mac_address / network_mode / ipc /
    /// pid / uts and the service-level networks object form with aliases.
    enum NetworkingArgs {
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []

            // -p ports
            if let ports = ctx.service.ports {
                for port in ports {
                    let resolved = resolveVariable(port, with: ctx.environmentVariables)
                    args.append(contentsOf: ["-p", composePortToRunArg(resolved)])
                }
            }

            // --network … (list form: a service-level networks: [foo, bar] entry)
            if let serviceNetworks = ctx.service.networks {
                for network in serviceNetworks {
                    let resolved = resolveVariable(network, with: ctx.environmentVariables)
                    // Prefer the explicit name from the top-level definition if set.
                    let networkToConnect = ctx.dockerCompose.networks?[network]??.name ?? resolved
                    args.append(contentsOf: ["--network", networkToConnect])
                }
            }

            // --hostname
            if let hostname = ctx.service.hostname {
                let resolved = resolveVariable(hostname, with: ctx.environmentVariables)
                args.append(contentsOf: ["--hostname", resolved])
            }

            return args
        }
    }
}
