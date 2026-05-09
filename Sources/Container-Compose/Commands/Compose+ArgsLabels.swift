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
    ///
    /// CHAOS-1496: ALSO emits five generalized `compose.spec.*` fingerprint
    /// labels recording the canonical fingerprint of the spec content this
    /// container was created against:
    ///
    ///   - `compose.spec.image=<reference>`        — resolved (env-substituted)
    ///                                              `service.image` string;
    ///                                              skip when `service.image`
    ///                                              is nil (build-only).
    ///   - `compose.spec.entrypoint.hash=<sha256>`  — SHA256 of joined
    ///                                              `(entrypoint ?? []) +
    ///                                              (command ?? [])`; skip
    ///                                              when both are nil.
    ///   - `compose.spec.env.hash=<sha256>`         — SHA256 of canonical
    ///                                              merged env (sorted
    ///                                              `KEY=VALUE\n` lines);
    ///                                              skip when `mergedEnv`
    ///                                              is empty.
    ///   - `compose.spec.ports.hash=<sha256>`       — SHA256 of canonical
    ///                                              `composePortToRunArg`
    ///                                              specs sorted + joined
    ///                                              with `\n`; skip when
    ///                                              `service.ports` is
    ///                                              nil/empty.
    ///   - `compose.spec.networks.hash=<sha256>`    — SHA256 of resolved
    ///                                              network names sorted +
    ///                                              joined with `\n`. Covers
    ///                                              both explicit
    ///                                              `service.networks` (via
    ///                                              CHAOS-1495's
    ///                                              `resolveCanonicalNetworkName`)
    ///                                              AND CHAOS-1494's implicit
    ///                                              project-default-network
    ///                                              attachment. Skip only
    ///                                              when neither is present.
    ///
    /// `specDivergenceReason` reads these labels on subsequent `up` and
    /// reduces every drift dimension to string equality on labels (with the
    /// existing snapshot-based checks remaining as backwards-compat
    /// fallback for pre-CHAOS-1496 containers). See `Compose+SpecFingerprint`
    /// for the canonical hash forms.
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

            // CHAOS-1496: generalized create-spec fingerprint labels.
            // Each label is emitted only when its underlying compose-spec
            // content is non-empty ("appear when applicable; absent when
            // not"). Emitting after the dns-resolvers loop above keeps the
            // `compose.dns.*` and `compose.spec.*` namespaces visually
            // grouped in the resulting argv.
            args.append(contentsOf: fingerprintLabels(ctx))

            return args
        }

        /// CHAOS-1496: builds the `compose.spec.*` fingerprint label argv
        /// fragment. Split out from `build` so unit tests can target the
        /// fingerprint emission in isolation. Output is already in deterministic
        /// label-name order (image → entrypoint.hash → env.hash → ports.hash
        /// → networks.hash); each pair is `["--label", "compose.spec.X=..."]`.
        static func fingerprintLabels(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []
            let svc = ctx.service

            // 0. CHAOS-1499 bootstrap sentinel — unconditional. Written for
            // every container that goes through fingerprintLabels (i.e.
            // every post-CHAOS-1499 container). Consumed by
            // `envDivergenceReason` in `Compose+Adoption.swift` to gate the
            // snapshot-fallback SUBSET env check. Pre-1499 containers
            // (including all pre-1496 ones) lack this sentinel; their
            // baked env may include peer-IP values resolved at create-time
            // on a prior `up` (when `containerIps` was populated mid-flight
            // by the `configService` loop AFTER each service launched).
            // The expected env at adoption time has `containerIps` empty,
            // so peer-name env vars expand to the unrewritten name. Without
            // this gate the SUBSET check would spurious-recreate every
            // pre-1499 container with peer-name env vars (e.g.
            // `DB_HOST: postgres` resolves at create-time to
            // `DB_HOST=192.168.66.4`, then the next `up` recomputes
            // expected as `DB_HOST=postgres` and the SUBSET fails). The
            // first non-env divergence (image, ports, command, networks,
            // dns) forces a benign recreate that produces a post-1499
            // container with the sentinel; from then on
            // `envHashDivergence` (label-primary, byte-equal hash) is the
            // source of truth.
            args.append(contentsOf: ["--label", "compose.spec.bootstrapped=true"])

            // 1. compose.spec.image — resolved image reference. Skip for
            // build-only services where `service.image` is nil; the
            // post-build image reference comes from the build pipeline and
            // there is no static compose-spec value to fingerprint.
            if let imageRef = svc.image {
                let resolved = resolveVariable(imageRef, with: ctx.environmentVariables)
                args.append(contentsOf: ["--label", "compose.spec.image=\(resolved)"])
            }

            // 2. compose.spec.entrypoint.hash — hash of (entrypoint ?? []) +
            // (command ?? []) joined with `\u{1F}`. Skip when both nil so
            // services using the image's default CMD/ENTRYPOINT have no
            // spurious fingerprint to maintain.
            if let hash = SpecFingerprint.canonicalEntrypointHash(
                entrypoint: svc.entrypoint,
                command: svc.command
            ) {
                args.append(contentsOf: ["--label", "compose.spec.entrypoint.hash=\(hash)"])
            }

            // 3. compose.spec.env.hash — hash of canonical user-declared env
            // (post-${VAR} substitution, pre-containerIps rewrite). Uses
            // the (a)-layer dict pre-computed once by `assembleRunArgs` via
            // `mergeServiceEnvForFingerprint`. The (b)-layer (full) merge is
            // intentionally NOT hashed: `containerIps` is empty at
            // `resolveAdoption` time, so hashing the full form would
            // spuriously diverge every service whose env references a peer
            // service by name. Peer-IP drift is covered by the existing
            // CHAOS-1493 `dnsDivergenceReason`.
            // Skip when empty so trivial services / direct-init test
            // fixtures stay free of incidental fingerprint noise.
            if !ctx.fingerprintEnv.isEmpty {
                let hash = SpecFingerprint.canonicalEnvHash(ctx.fingerprintEnv)
                args.append(contentsOf: ["--label", "compose.spec.env.hash=\(hash)"])
            }

            // 4. compose.spec.ports.hash — hash of canonicalized port specs.
            // `canonicalPortsHash` returns nil when `service.ports` is
            // nil/empty, so the `if let` doubles as the skip-when-not-applicable
            // check.
            if let hash = SpecFingerprint.canonicalPortsHash(
                svc.ports,
                environmentVariables: ctx.environmentVariables
            ) {
                args.append(contentsOf: ["--label", "compose.spec.ports.hash=\(hash)"])
            }

            // 5. compose.spec.networks.hash — hash of resolved network names.
            // Covers BOTH explicit `service.networks` (routed through CHAOS-1495's
            // `resolveCanonicalNetworkName`) AND CHAOS-1494's implicit project-default-
            // network attachment (already canonical, does not route through the
            // helper). Mirrors the explicit-vs-implicit branching pattern from
            // the dns-resolvers loop above so the read-side divergence check
            // sees identical canonical names. Skip only when neither is present
            // (e.g. `network_mode: host` or build-only services).
            var canonicalNetworkNames: [String] = []
            if let serviceNetworks = svc.networks {
                for (name, _) in serviceNetworks.entries {
                    canonicalNetworkNames.append(resolveCanonicalNetworkName(
                        name,
                        dockerCompose: ctx.dockerCompose,
                        environmentVariables: ctx.environmentVariables
                    ))
                }
            } else if let implicitNetwork = ctx.implicitDefaultNetwork,
                      svc.network_mode == nil {
                canonicalNetworkNames.append(implicitNetwork)
            }
            if let hash = SpecFingerprint.canonicalNetworksHash(canonicalNetworkNames) {
                args.append(contentsOf: ["--label", "compose.spec.networks.hash=\(hash)"])
            }

            return args
        }
    }
}
