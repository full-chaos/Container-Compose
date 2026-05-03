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

            // --network … (list or map form of service-level networks)
            if let serviceNetworks = ctx.service.networks {
                for (name, config) in serviceNetworks.entries {
                    let resolved = resolveVariable(name, with: ctx.environmentVariables)
                    // Prefer the explicit name from the top-level definition if set.
                    let networkToConnect = ctx.dockerCompose.networks?[name]??.name ?? resolved
                    args.append(contentsOf: ["--network", networkToConnect])
                    // Aliases: parsed, but Apple container does not expose --alias
                    // on `container run`.
                    if let aliases = config.aliases, !aliases.isEmpty {
                        warnUnsupportedRuntimeFieldOnce(
                            "service.networks.aliases",
                            "Note: 'networks.<name>.aliases' for service networks is parsed but not supported by Apple container; ignored."
                        )
                    }
                    // ipv4_address: parsed, but Apple container does not expose
                    // standalone --ip on `container run`.
                    if config.ipv4_address != nil {
                        warnUnsupportedRuntimeFieldOnce("service.networks.ipv4_address", "Note: 'networks.<name>.ipv4_address' is parsed but not supported by Apple container; ignored.")
                    }
                    // ipv6_address: parsed, but Apple container does not expose
                    // standalone --ip6 on `container run`.
                    if config.ipv6_address != nil {
                        warnUnsupportedRuntimeFieldOnce("service.networks.ipv6_address", "Note: 'networks.<name>.ipv6_address' is parsed but not supported by Apple container; ignored.")
                    }
                }
            }

            // apple/container does not accept --hostname (verified Tier 0 R2 audit).
            if ctx.service.hostname != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.hostname",
                    "Note: 'hostname' is parsed but not supported by Apple container; ignored."
                )
            }

            // --dns ADDR (per item)
            if let dns = ctx.service.dns {
                for addr in dns {
                    let resolved = resolveVariable(addr, with: ctx.environmentVariables)
                    args.append(contentsOf: ["--dns", resolved])
                }
            }

            // --dns-option OPT (per item)
            if let dnsOpts = ctx.service.dns_opt {
                for opt in dnsOpts {
                    let resolved = resolveVariable(opt, with: ctx.environmentVariables)
                    args.append(contentsOf: ["--dns-option", resolved])
                }
            }

            // --dns-search DOMAIN (per item)
            if let dnsSearch = ctx.service.dns_search {
                for domain in dnsSearch {
                    let resolved = resolveVariable(domain, with: ctx.environmentVariables)
                    args.append(contentsOf: ["--dns-search", resolved])
                }
            }

            // extra_hosts: parsed, but Apple container does not expose --add-host
            // on `container run`.
            if let extraHosts = ctx.service.extra_hosts {
                if !extraHosts.isEmpty {
                    warnUnsupportedRuntimeFieldOnce(
                        "service.extra_hosts",
                        "Note: 'extra_hosts' is parsed but not supported by Apple container; ignored."
                    )
                }
            }

            // apple/container does not accept --domainname (verified Tier 0 R2 audit).
            if ctx.service.domainname != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.domainname",
                    "Note: 'domainname' is parsed but not supported by Apple container; ignored."
                )
            }

            // apple/container does not accept --expose (verified Tier 0 R2 audit).
            if let expose = ctx.service.expose, !expose.isEmpty {
                warnUnsupportedRuntimeFieldOnce(
                    "service.expose",
                    "Note: 'expose' is parsed but not supported by Apple container; ignored."
                )
            }

            // mac_address: parsed, but Apple container does not expose standalone
            // --mac-address on `container run`.
            if ctx.service.mac_address != nil {
                warnUnsupportedRuntimeFieldOnce("service.mac_address", "Note: 'mac_address' is parsed but not supported by Apple container; ignored.")
            }

            // --network MODE (network_mode overrides; distinct from the networks list above)
            if let networkMode = ctx.service.network_mode {
                let resolved = resolveVariable(networkMode, with: ctx.environmentVariables)
                args.append(contentsOf: ["--network", resolved])
            }

            // ipc: parsed, but Apple container does not expose --ipc on `container run`.
            if ctx.service.ipc != nil {
                warnUnsupportedRuntimeFieldOnce("service.ipc", "Note: 'ipc' is parsed but not supported by Apple container; ignored.")
            }

            // pid: parsed, but Apple container does not expose --pid on `container run`.
            if ctx.service.pid != nil {
                warnUnsupportedRuntimeFieldOnce("service.pid", "Note: 'pid' is parsed but not supported by Apple container; ignored.")
            }

            // uts: parsed, but Apple container does not expose --uts on `container run`.
            if ctx.service.uts != nil {
                warnUnsupportedRuntimeFieldOnce("service.uts", "Note: 'uts' is parsed but not supported by Apple container; ignored.")
            }

            return args
        }
    }
}
