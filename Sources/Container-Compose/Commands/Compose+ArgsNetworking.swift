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
                    // ipv4_address: emit --ip if present.
                    if let ipv4 = config.ipv4_address {
                        let resolvedIP = resolveVariable(ipv4, with: ctx.environmentVariables)
                        print("Warning: ipv4_address for service-network '\(name)' may not be honored by Apple container; --ip flag emitted regardless.")
                        args.append(contentsOf: ["--ip", resolvedIP])
                    }
                    // ipv6_address: emit --ip6 if present.
                    if let ipv6 = config.ipv6_address {
                        let resolvedIP = resolveVariable(ipv6, with: ctx.environmentVariables)
                        print("Warning: ipv6_address for service-network '\(name)' may not be honored by Apple container; --ip6 flag emitted regardless.")
                        args.append(contentsOf: ["--ip6", resolvedIP])
                    }
                }
            }

            // --hostname
            if let hostname = ctx.service.hostname {
                let resolved = resolveVariable(hostname, with: ctx.environmentVariables)
                args.append(contentsOf: ["--hostname", resolved])
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

            // --domainname NAME
            if let domainname = ctx.service.domainname {
                let resolved = resolveVariable(domainname, with: ctx.environmentVariables)
                args.append(contentsOf: ["--domainname", resolved])
            }

            // --expose PORT/PROTO (per item)
            if let expose = ctx.service.expose {
                for port in expose {
                    let resolved = resolveVariable(port, with: ctx.environmentVariables)
                    args.append(contentsOf: ["--expose", resolved])
                }
            }

            // --mac-address MAC
            if let macAddress = ctx.service.mac_address {
                let resolved = resolveVariable(macAddress, with: ctx.environmentVariables)
                args.append(contentsOf: ["--mac-address", resolved])
            }

            // --network MODE (network_mode overrides; distinct from the networks list above)
            if let networkMode = ctx.service.network_mode {
                let resolved = resolveVariable(networkMode, with: ctx.environmentVariables)
                args.append(contentsOf: ["--network", resolved])
            }

            // --ipc MODE
            if let ipc = ctx.service.ipc {
                let resolved = resolveVariable(ipc, with: ctx.environmentVariables)
                args.append(contentsOf: ["--ipc", resolved])
            }

            // --pid MODE
            if let pid = ctx.service.pid {
                let resolved = resolveVariable(pid, with: ctx.environmentVariables)
                args.append(contentsOf: ["--pid", resolved])
            }

            // --uts MODE
            if let uts = ctx.service.uts {
                let resolved = resolveVariable(uts, with: ctx.environmentVariables)
                args.append(contentsOf: ["--uts", resolved])
            }

            return args
        }
    }
}
