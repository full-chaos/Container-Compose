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

import ContainerAPIClient
import ContainerResource
import Foundation

// MARK: - AdoptionDecision

/// CHAOS-1492: per-service decision computed by `compose up`.
///
/// `compose up` previously stopped + removed every project container at the
/// top of every invocation, then recreated each from scratch. That is NOT
/// docker-compose semantics: docker-compose ADOPTS existing matching
/// containers and only recreates them when their spec has drifted (image,
/// env, ports, command) or when the user explicitly passes
/// `--force-recreate`. This enum drives the new per-service branch in
/// `ComposeUp.run()` and `ComposeUp.configService`.
public enum AdoptionDecision: Equatable, Sendable, Codable {
    /// No matching container exists for the service's effective name.
    /// Standard create + run path applies.
    case create
    /// Matching container is already running with the expected spec — keep
    /// it and skip the spawn step. `up` will still poll readiness via
    /// `waitUntilServiceIsRunning` (a fast no-op when the container is
    /// already running) and rebuild downstream env-var / DNS-zone state so
    /// peer services can resolve the adopted container by name.
    case adopt
    /// Matching container exists but diverges from the expected spec, OR
    /// the user passed `--force-recreate`. Stop + remove first, then go
    /// through the standard create + run path. The reason string is
    /// surfaced in the user-facing log line so divergence is auditable.
    case recreate(reason: String)
}

// MARK: - ComposeUp adoption helpers

extension ComposeUp {
    /// CHAOS-1492: Probe each service's effective container name and decide
    /// whether to adopt the existing container (`.adopt`), recreate it
    /// (`.recreate(reason:)`), or create a fresh one (`.create`).
    ///
    /// Decisions:
    ///   1. No existing container → `.create`
    ///   2. `--force-recreate` → `.recreate("--force-recreate")` (without
    ///      consulting `specDivergenceReason`)
    ///   3. Existing + diverging spec → `.recreate(reason)` from
    ///      `specDivergenceReason`
    ///   4. Existing + matching → `.adopt` (and emits "Adopting..." line)
    ///
    /// `internal` so the static suite's `ComposeUpAdoptionTests` can drive
    /// it directly without standing up the full `cmd.run()` pipeline.
    internal func resolveAdoption(
        _ services: [(serviceName: String, service: Service)],
        dockerCompose: DockerCompose? = nil
    ) async throws -> [String: AdoptionDecision] {
        guard let projectName else { return [:] }
        var decisions: [String: AdoptionDecision] = [:]
        let provider = ContainerClientEnvironment.current

        for (serviceName, service) in services {
            let containerName = effectiveContainerName(
                projectName: projectName,
                serviceName: serviceName,
                explicit: service.container_name
            )

            guard let existing = try? await provider.get(id: containerName) else {
                decisions[serviceName] = .create
                continue
            }

            if forceRecreate {
                decisions[serviceName] = .recreate(reason: "--force-recreate")
                continue
            }

            // CHAOS-1493 wave 3 / CHAOS-1495: precompute expected values for the
            // extended divergence checks so `specDivergenceReason` stays pure.
            // The canonical-name map is the source of truth — we derive the
            // network-name SET from it instead of iterating `service.networks`
            // twice with the same resolution rules.
            //
            // CHAOS-1494: when `service.networks` is nil and the project
            // synthesized an implicit default network, augment the canonical
            // map with `[implicit: implicit]` so both the expected-set and
            // the DNS-divergence lookup see the implicit attachment. The
            // implicit name is project-scoped and already canonical, so
            // raw==canonical for it.
            var serviceNetworkCanonicalNames = serviceNetworkCanonicalNamesMap(service, dockerCompose: dockerCompose)
            if service.networks == nil,
               let implicit = self.implicitDefaultNetworkName,
               service.network_mode == nil {
                serviceNetworkCanonicalNames[implicit] = implicit
            }
            let expectedNetworkNames = Set(serviceNetworkCanonicalNames.values)
            let expectedPublishedPorts = expectedPublishedPortsForService(service)
            let expectedEnvironment = expectedEnvironmentForService(service)
            let expectedCommand = service.command

            // CHAOS-1496: precompute expected fingerprint values for the new
            // label-primary divergence checks. Each is computed with the same
            // canonical form `LabelsArgs.fingerprintLabels` used at create
            // time, so a hash match implies byte-equal compose-spec content.
            let expectedImageLabel: String? = service.image.map {
                resolveVariable($0, with: environmentVariables)
            }
            let expectedEntrypointHash = ComposeUp.SpecFingerprint.canonicalEntrypointHash(
                entrypoint: service.entrypoint,
                command: service.command
            )
            // Use the (a)-only merge so the hash matches the label written at
            // create time. See `mergeServiceEnvForFingerprint` for why the
            // (b)-layer (containerIps rewrite) is intentionally excluded.
            let expectedFingerprintEnv = mergeServiceEnvForFingerprint(service)
            let expectedEnvHash: String? = expectedFingerprintEnv.isEmpty
                ? nil
                : ComposeUp.SpecFingerprint.canonicalEnvHash(expectedFingerprintEnv)
            let expectedPortsHash = ComposeUp.SpecFingerprint.canonicalPortsHash(
                service.ports,
                environmentVariables: environmentVariables
            )
            let expectedNetworksHash = ComposeUp.SpecFingerprint.canonicalNetworksHash(
                Array(expectedNetworkNames)
            )

            if let reason = Self.specDivergenceReason(
                existing: existing,
                expected: service,
                expectedSidecarIPs: self.dnsSidecar?.perNetworkIPs ?? [:],
                expectedNetworkNames: expectedNetworkNames,
                expectedPublishedPorts: expectedPublishedPorts,
                expectedEnvironment: expectedEnvironment,
                expectedCommand: expectedCommand,
                serviceNetworkCanonicalNames: serviceNetworkCanonicalNames,
                implicitDefaultNetwork: self.implicitDefaultNetworkName,
                expectedImageLabel: expectedImageLabel,
                expectedEntrypointHash: expectedEntrypointHash,
                expectedEnvHash: expectedEnvHash,
                expectedPortsHash: expectedPortsHash,
                expectedNetworksHash: expectedNetworksHash
            ) {
                decisions[serviceName] = .recreate(reason: reason)
                continue
            }

            decisions[serviceName] = .adopt
            print("Adopting existing container: \(containerName)")
        }

        return decisions
    }

    /// CHAOS-1495: Resolves the SET of network names this service is expected
    /// to attach to. Mirrors all other `service.networks`-resolution sites by
    /// routing through `resolveCanonicalNetworkName(_:dockerCompose:environmentVariables:)`.
    /// Returns an empty set when `service.networks` is nil so the downstream
    /// check skips silently.
    ///
    /// CHAOS-1494: when `service.networks` is nil and `service.network_mode`
    /// is also nil, fall back to the project's synthesized implicit default
    /// network (when present). This mirrors the implicit-attachment branch
    /// in `NetworkingArgs.build` so the divergence detector sees the same
    /// expected set the create path emits.
    ///
    /// Internal but kept for the unit tests in `ComposeUpAdoptionTests`. Real
    /// callers in `resolveAdoption` go through `serviceNetworkCanonicalNamesMap`
    /// and derive the set from `.values` to avoid iterating twice.
    internal func expectedNetworkNamesForService(
        _ service: Service,
        dockerCompose: DockerCompose?,
        implicitDefaultNetwork: String? = nil
    ) -> Set<String> {
        var names = Set(serviceNetworkCanonicalNamesMap(service, dockerCompose: dockerCompose).values)
        if service.networks == nil,
           let implicit = implicitDefaultNetwork,
           service.network_mode == nil {
            names.insert(implicit)
        }
        return names
    }

    /// CHAOS-1495: Builds the per-service canonical-name map that downstream
    /// divergence checks (DNS in particular) use to look up sidecar IPs and
    /// label keys. Maps each raw `services.<svc>.networks` key to the canonical
    /// network name that apple/container, the sidecar, the label-write path,
    /// and the `--network` argv all agree on.
    ///
    /// Returns an empty map when `service.networks` is nil. Callers treat the
    /// empty map as "no DNS divergence check possible for this service" — the
    /// CHAOS-1494 implicit-network case is handled by the caller (it augments
    /// the map with `[implicit: implicit]`).
    internal func serviceNetworkCanonicalNamesMap(
        _ service: Service,
        dockerCompose: DockerCompose?
    ) -> [String: String] {
        guard let serviceNetworks = service.networks else { return [:] }
        var map: [String: String] = [:]
        for (name, _) in serviceNetworks.entries {
            map[name] = resolveCanonicalNetworkName(
                name,
                dockerCompose: dockerCompose,
                environmentVariables: environmentVariables
            )
        }
        return map
    }

    /// CHAOS-1493: Canonicalize each compose-spec port string (`service.ports[i]`)
    /// via `composePortToRunArg`. The result is the SAME canonical string format
    /// that `canonicalPortSpec(_:)` produces from an apple/container `PublishPort`,
    /// so SET equality between expected and existing is meaningful. Returns an
    /// empty set when `service.ports` is nil.
    private func expectedPublishedPortsForService(_ service: Service) -> Set<String> {
        guard let ports = service.ports else { return [] }
        var canonical: Set<String> = []
        for portSpec in ports {
            let resolved = resolveVariable(portSpec, with: environmentVariables)
            canonical.insert(composePortToRunArg(resolved))
        }
        return canonical
    }

    /// CHAOS-1493: Compute the env this `up` would emit for the service. Routes
    /// through `mergeAndExpandServiceEnv` so the merge order matches what
    /// `assembleRunArgs` produces today. Empty result (no env declared) skips
    /// the divergence check.
    private func expectedEnvironmentForService(_ service: Service) -> [String: String] {
        return mergeAndExpandServiceEnv(service)
    }

    /// CHAOS-1492: Walk the decision map and stop+remove any container
    /// flagged `.recreate`, leaving `.create` (no existing container) and
    /// `.adopt` (matching existing) untouched.
    ///
    /// Replaces the blanket `stopOldStuff(services, remove: true)`
    /// previously invoked unconditionally at the top of `run()`.
    /// `internal` so `ComposeUpAdoptionTests` can drive it directly.
    internal func applyRecreations(
        _ services: [(serviceName: String, service: Service)],
        decisions: [String: AdoptionDecision]
    ) async throws {
        guard let projectName else { return }
        let provider = ContainerClientEnvironment.current

        for (serviceName, service) in services {
            guard case .recreate(let reason) = decisions[serviceName] else { continue }
            let containerName = effectiveContainerName(
                projectName: projectName,
                serviceName: serviceName,
                explicit: service.container_name
            )
            print("Recreating container: \(containerName) (reason: \(reason))")
            do {
                try await provider.stop(id: containerName, opts: .default)
            } catch {
                print("Error Stopping Container: \(error)")
            }
            do {
                try await provider.delete(id: containerName, force: false)
            } catch {
                print("Error Removing Container: \(error)")
            }
        }
    }

    /// CHAOS-1492 / 1493 / 1496 divergence detection.
    ///
    /// Returns a non-nil reason string when the existing container's spec has
    /// drifted from what `compose up` would launch today, in which case the
    /// caller (`resolveAdoption`) flips the decision from `.adopt` to `.recreate`.
    ///
    /// Check order (Oracle Q3 ranking — highest user-impact first):
    ///   1. Image label (CHAOS-1496) PRIMARY → image string (CHAOS-1492 v1) FALLBACK.
    ///   2. DNS resolver IPs (CHAOS-1493) — sidecar IP drift kills `/etc/resolv.conf`.
    ///   3. Networks hash (CHAOS-1496) PRIMARY → network attachments SET (CHAOS-1493 wave 3) FALLBACK.
    ///   4. Ports hash (CHAOS-1496) PRIMARY → published ports SET (CHAOS-1493 wave 3) FALLBACK.
    ///   5. Env hash (CHAOS-1496) PRIMARY → environment SUBSET (CHAOS-1493 wave 3) FALLBACK.
    ///   6. Entrypoint hash (CHAOS-1496) PRIMARY → command (CHAOS-1493 wave 3) FALLBACK.
    ///
    /// CHAOS-1496 PRIMARY checks read `compose.spec.*` labels written by
    /// `LabelsArgs.fingerprintLabels` at create time. When a label is absent
    /// (pre-CHAOS-1496 container), the primary check returns nil and the
    /// existing snapshot-based FALLBACK runs unchanged — no spurious recreate
    /// for upgraded containers. When a label is present and matches, no
    /// divergence is signaled by the primary; the fallback still runs as a
    /// belt-and-suspenders sanity check (the two should agree by construction
    /// for any container created post-CHAOS-1496). When a label is present
    /// and mismatches, the primary returns a clear reason and the fallback is
    /// skipped (we already know the spec drifted).
    ///
    /// Build-only services (no `image:` field) skip the image checks — their
    /// effective image reference comes from the build pipeline, not the
    /// compose file. They still get the other drift checks below.
    ///
    /// `expectedSidecarIPs` is the current sidecar's per-network resolver
    /// IP map (`SidecarHandle.perNetworkIPs`). Pass an empty map (the default)
    /// when no embedded DNS sidecar is in play this `up` — the DNS check is
    /// then skipped silently. Existing CHAOS-1492/1493 unit tests of this
    /// function rely on the defaults and stay backward-compatible.
    ///
    /// CHAOS-1495: `serviceNetworkCanonicalNames` carries the raw→canonical
    /// mapping built by `serviceNetworkCanonicalNamesMap`. Required so DNS
    /// divergence finds the right sidecar IP for env-substituted / aliased
    /// network names. Default empty map preserves backward-compat for unit
    /// tests that pass simple network names.
    ///
    /// CHAOS-1494: `implicitDefaultNetwork` carries the project's synthesized
    /// implicit default network name (when applicable) so DNS divergence can
    /// emit a CHAOS-1494-specific upgrade message for pre-1494 containers
    /// that were never attached to a project network at all.
    internal static func specDivergenceReason(
        existing: ContainerSnapshot,
        expected: Service,
        expectedSidecarIPs: [String: String] = [:],
        expectedNetworkNames: Set<String> = [],
        expectedPublishedPorts: Set<String> = [],
        expectedEnvironment: [String: String] = [:],
        expectedCommand: [String]? = nil,
        serviceNetworkCanonicalNames: [String: String] = [:],
        implicitDefaultNetwork: String? = nil,
        expectedImageLabel: String? = nil,
        expectedEntrypointHash: String? = nil,
        expectedEnvHash: String? = nil,
        expectedPortsHash: String? = nil,
        expectedNetworksHash: String? = nil
    ) -> String? {
        // 1A. Image label (CHAOS-1496) — PRIMARY
        if let reason = imageLabelDivergence(existing: existing, expectedImageLabel: expectedImageLabel) {
            return reason
        }
        // 1B. Image string (CHAOS-1492 v1) — FALLBACK
        if let expectedRaw = expected.image {
            let existingImage = existing.configuration.image.reference
            let expectedQualified = qualifyImageReference(expectedRaw)
            if existingImage != expectedQualified {
                return "image changed: \(existingImage) -> \(expectedQualified)"
            }
        }

        // 2. DNS resolver drift (CHAOS-1493 v1 fix; CHAOS-1495 canonical-name
        // plumbing; CHAOS-1494 implicit-network coverage).
        if let reason = dnsDivergenceReason(
            existing: existing,
            expected: expected,
            expectedSidecarIPs: expectedSidecarIPs,
            serviceNetworkCanonicalNames: serviceNetworkCanonicalNames,
            implicitDefaultNetwork: implicitDefaultNetwork
        ) {
            return reason
        }

        // 3A. Networks hash (CHAOS-1496) — PRIMARY
        if let reason = networksHashDivergence(existing: existing, expectedNetworksHash: expectedNetworksHash) {
            return reason
        }

        // 3B. Network attachments SET (CHAOS-1493 wave 3) — FALLBACK
        if let reason = networkDivergenceReason(
            existing: existing,
            expectedNetworkNames: expectedNetworkNames
        ) {
            return reason
        }

        // 4A. Ports hash (CHAOS-1496) — PRIMARY
        if let reason = portsHashDivergence(existing: existing, expectedPortsHash: expectedPortsHash) {
            return reason
        }

        // 4B. Published ports SET (CHAOS-1493 wave 3) — FALLBACK
        if let reason = portsDivergenceReason(
            existing: existing,
            expectedPublishedPorts: expectedPublishedPorts
        ) {
            return reason
        }

        // 5A. Env hash (CHAOS-1496) — PRIMARY
        if let reason = envHashDivergence(existing: existing, expectedEnvHash: expectedEnvHash) {
            return reason
        }

        // 5B. Environment SUBSET (CHAOS-1493 wave 3) — FALLBACK
        if let reason = envDivergenceReason(
            existing: existing,
            expectedEnvironment: expectedEnvironment
        ) {
            return reason
        }

        // 6A. Entrypoint hash (CHAOS-1496) — PRIMARY
        if let reason = entrypointHashDivergence(existing: existing, expectedEntrypointHash: expectedEntrypointHash) {
            return reason
        }

        // 6B. Command (CHAOS-1493 wave 3) — FALLBACK
        if let reason = commandDivergenceReason(
            existing: existing,
            expectedCommand: expectedCommand,
            expectedEntrypoint: expected.entrypoint
        ) {
            return reason
        }

        return nil
    }

    /// CHAOS-1493 / CHAOS-1495 DNS divergence helper.
    ///
    /// For each network the service is attached to that has a sidecar IP
    /// (`expectedSidecarIPs[canonical]` non-nil), verify the existing container's
    /// recorded resolver agrees with the current sidecar IP. Sources, in order:
    ///   1. Per-network label `compose.dns.resolvers.<canonical>` written by
    ///      `LabelsArgs.build` at create time. Authoritative — disambiguates
    ///      multi-network projects where the flat snapshot `dns.nameservers`
    ///      array can't tell us which IP belongs to which network.
    ///   2. Snapshot `configuration.dns.nameservers` SET-membership. A
    ///      belt-and-suspenders sanity check: every expected sidecar IP MUST
    ///      appear in the snapshot's nameservers. If any expected IP is
    ///      missing, the snapshot disagrees with the current sidecar regardless
    ///      of label state.
    ///   3. Conservative fallback: when neither labels nor snapshot dns are
    ///      available, force a one-time recreate so the next `up` has labels
    ///      to compare against. Only fires for containers created before this
    ///      fix landed.
    ///
    /// CHAOS-1495: `serviceNetworkCanonicalNames` is the caller-supplied raw→canonical
    /// mapping. The previous implementation iterated `service.networks.entries`
    /// and looked up `expectedSidecarIPs[rawNetworkName]` directly, which silently
    /// missed for env-substituted (`${PROJECT_NET}`) or aliased
    /// (`networks: { foo: { name: bar } }`) networks because those sites resolve
    /// to a different canonical key than the raw YAML key. Empty map falls back
    /// to identity (raw==canonical) for legacy callers — safe whenever no env or
    /// alias indirection is in play, which is the assumption of the existing
    /// CHAOS-1492/1493 unit tests.
    ///
    /// CHAOS-1494: when a service omits `service.networks` and the project
    /// synthesized an implicit default network, treat the implicit network as
    /// the single attachment for divergence purposes — mirroring the
    /// implicit-attachment branches in `NetworkingArgs.build` and
    /// `LabelsArgs.build`. Pre-CHAOS-1494 containers won't have the implicit
    /// label and produce a specific upgrade message so the recreate is
    /// auditable.
    private static func dnsDivergenceReason(
        existing: ContainerSnapshot,
        expected: Service,
        expectedSidecarIPs: [String: String],
        serviceNetworkCanonicalNames: [String: String] = [:],
        implicitDefaultNetwork: String? = nil
    ) -> String? {
        guard !expectedSidecarIPs.isEmpty else { return nil }

        // CHAOS-1494: build the iteration set. When `service.networks` is
        // declared, walk it and resolve raw→canonical via the supplied map
        // (or identity fallback). Otherwise fall back to the implicit default
        // network (when synthesized AND no `network_mode` overrides
        // attachment), matching `NetworkingArgs.build` and `LabelsArgs.build`.
        let iterationItems: [(rawName: String, canonical: String)]
        let isImplicitOnly: Bool
        if let serviceNetworks = expected.networks {
            iterationItems = serviceNetworks.entries.map { entry in
                let canonical = serviceNetworkCanonicalNames[entry.name] ?? entry.name
                return (entry.name, canonical)
            }
            isImplicitOnly = false
        } else if let implicit = implicitDefaultNetwork, expected.network_mode == nil {
            // Implicit name is project-scoped and already canonical
            // (`<projectName>-default`); raw==canonical.
            iterationItems = [(implicit, implicit)]
            isImplicitOnly = true
        } else {
            return nil
        }

        let labels = existing.configuration.labels
        let snapshotNameservers = existing.configuration.dns?.nameservers ?? []
        let snapshotNameserverSet = Set(snapshotNameservers)

        for (_, canonical) in iterationItems {
            // Sidecar only serves networks it actually attached to; if no IP is
            // recorded for this canonical name, the network is out of scope for
            // DNS divergence (e.g. service attached to a non-sidecar network).
            guard let expectedIP = expectedSidecarIPs[canonical] else { continue }

            // 1. Per-network label — authoritative.
            let labelKey = "compose.dns.resolvers.\(canonical)"
            if let labelIP = labels[labelKey] {
                if labelIP != expectedIP {
                    return "DNS resolver IP for network '\(canonical)' changed: \(labelIP) -> \(expectedIP)"
                }
                continue
            }

            // 2. Snapshot nameservers SET-membership — sanity check.
            if !snapshotNameserverSet.isEmpty {
                if !snapshotNameserverSet.contains(expectedIP) {
                    return "DNS resolver IP for network '\(canonical)' (\(expectedIP)) not in container's nameservers \(snapshotNameservers.sorted())"
                }
                continue
            }

            // 3. Conservative fallback — first `up` after upgrading.
            // CHAOS-1494: distinct message when the missing label is the
            // implicit-network one so reviewers can tell pre-1493 (had
            // explicit `service.networks` but no labels) from pre-1494
            // (had no `service.networks`, never attached to a project net).
            if isImplicitOnly {
                return "upgrading from pre-CHAOS-1494 container — recreating to attach to implicit project default network '\(canonical)' for DNS resolution"
            }
            return "upgrading from pre-CHAOS-1493 container — recreating to attach DNS resolver metadata for network '\(canonical)'"
        }

        return nil
    }

    /// CHAOS-1493 wave 3: network attachments divergence.
    ///
    /// Compares the SET of expected network names against the existing
    /// container's `configuration.networks` attachments. Both ordering and
    /// duplicates are normalized away by `Set` semantics. When `expectedNetworkNames`
    /// is empty (the default, used by CHAOS-1492 unit tests and projects with
    /// no top-level networks), the check is skipped silently.
    private static func networkDivergenceReason(
        existing: ContainerSnapshot,
        expectedNetworkNames: Set<String>
    ) -> String? {
        guard !expectedNetworkNames.isEmpty else { return nil }
        let existingNetworkNames = Set(existing.configuration.networks.map(\.network))
        if existingNetworkNames != expectedNetworkNames {
            let added = expectedNetworkNames.subtracting(existingNetworkNames).sorted()
            let removed = existingNetworkNames.subtracting(expectedNetworkNames).sorted()
            var diff: [String] = []
            if !added.isEmpty { diff.append("add " + added.joined(separator: ",")) }
            if !removed.isEmpty { diff.append("remove " + removed.joined(separator: ",")) }
            return "network attachments diverged: " + diff.joined(separator: "; ")
        }
        return nil
    }

    /// CHAOS-1493 wave 3: published ports divergence.
    ///
    /// Compares the SET of canonicalized expected port specs (one entry per
    /// `service.ports[i]` after running through `composePortToRunArg`) against
    /// the SET of canonicalized existing `PublishPort` entries. Order-insensitive.
    /// Empty expected set (default) skips the check.
    private static func portsDivergenceReason(
        existing: ContainerSnapshot,
        expectedPublishedPorts: Set<String>
    ) -> String? {
        guard !expectedPublishedPorts.isEmpty else { return nil }
        let existingPortSpecs = Set(existing.configuration.publishedPorts.map(canonicalPortSpec))
        if existingPortSpecs != expectedPublishedPorts {
            let added = expectedPublishedPorts.subtracting(existingPortSpecs).sorted()
            let removed = existingPortSpecs.subtracting(expectedPublishedPorts).sorted()
            var diff: [String] = []
            if !added.isEmpty { diff.append("add " + added.joined(separator: ",")) }
            if !removed.isEmpty { diff.append("remove " + removed.joined(separator: ",")) }
            return "published ports diverged: " + diff.joined(separator: "; ")
        }
        return nil
    }

    /// Canonicalize an apple/container `PublishPort` to the same string format
    /// `composePortToRunArg` produces from a compose-spec port string, so both
    /// sides of `portsDivergenceReason` can be compared as plain strings.
    /// Mirrors `RecordingContainerClientProvider.publishArg` and the production
    /// argv builders.
    private static func canonicalPortSpec(_ port: PublishPort) -> String {
        let hostPortStr: String
        let containerPortStr: String
        if port.count > 1 {
            hostPortStr = "\(port.hostPort)-\(port.hostPort + port.count - 1)"
            containerPortStr = "\(port.containerPort)-\(port.containerPort + port.count - 1)"
        } else {
            hostPortStr = "\(port.hostPort)"
            containerPortStr = "\(port.containerPort)"
        }
        let protoSuffix = port.proto == .udp ? "/udp" : ""
        return "\(port.hostAddress):\(hostPortStr):\(containerPortStr)\(protoSuffix)"
    }

    /// CHAOS-1493 wave 3: environment divergence (SUBSET semantics).
    ///
    /// Base-image-injected env (`PATH`, `HOME`, `USER`, `LANG`, ...) appears in
    /// the existing container's `initProcess.environment` but is never set by
    /// us. Equality would always show divergence. Right semantic: for every key
    /// WE intend to set (post-merge+expand), assert it exists in the existing
    /// env with the same value. Other existing keys are ignored.
    ///
    /// CHAOS-1499: Gated behind the `compose.spec.bootstrapped` sentinel so
    /// pre-1499 containers (which may have peer-IP env values baked at
    /// create-time on a prior `up` when `containerIps` was mid-flight) are
    /// adopted instead of spurious-recreated. The SUBSET check assumes the
    /// existing-env merge order matches the adoption-time merge order, which
    /// only holds for containers created post-CHAOS-1499. See
    /// `LabelsArgs.fingerprintLabels` for the sentinel write site and the
    /// rationale for letting pre-1499 containers migrate organically on
    /// their first non-env divergence.
    private static func envDivergenceReason(
        existing: ContainerSnapshot,
        expectedEnvironment: [String: String]
    ) -> String? {
        guard !expectedEnvironment.isEmpty else { return nil }
        // CHAOS-1499 bootstrap-sentinel gate. See doc comment + the write
        // site in `LabelsArgs.fingerprintLabels`.
        guard existing.configuration.labels["compose.spec.bootstrapped"] == "true" else {
            return nil
        }
        let existingEnv = parseEnvList(existing.configuration.initProcess.environment)
        for (key, expectedValue) in expectedEnvironment {
            guard let existingValue = existingEnv[key] else {
                return "env key '\(key)' missing in existing container (expected '\(expectedValue)')"
            }
            if existingValue != expectedValue {
                return "env key '\(key)' diverged: existing='\(existingValue)' expected='\(expectedValue)'"
            }
        }
        return nil
    }

    /// Parse `["KEY=VALUE", ...]` (apple/container's `ProcessConfiguration.environment`
    /// shape) into a `[String: String]` map. Entries without `=` are ignored
    /// (they're malformed; comparing to them would always diverge spuriously).
    private static func parseEnvList(_ env: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in env {
            guard let equalsIndex = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equalsIndex])
            let value = String(entry[entry.index(after: equalsIndex)...])
            result[key] = value
        }
        return result
    }

    /// CHAOS-1493 wave 3: command divergence.
    ///
    /// Only checks when `service.command` is explicitly set in the compose file.
    /// When nil, the user is implicitly accepting the image's CMD/ENTRYPOINT,
    /// and comparing against the existing container would always show spurious
    /// divergence (existing reflects the image default).
    ///
    /// CHAOS-1493 post-QA fix: apple/container's `ContainerConfiguration.initProcess`
    /// splits the launch command into `executable: String` + `arguments: [String]`.
    /// For `container run image sh -c "…"`, the snapshot stores
    /// `executable="sh"` and `arguments=["-c", "…"]`. Comparing the compose
    /// `service.command` (full list) against just `existing.arguments` (the
    /// rest, sans executable) always spurious-recreated services with a
    /// `command:` field. Reconstruct the existing command correctly:
    ///   - When compose specifies `service.entrypoint`, the runtime's
    ///     `executable` came from the entrypoint override and is OUT of band;
    ///     the existing command corresponds to `arguments` ONLY.
    ///   - Otherwise the runtime's `executable` came from the image's CMD/ENTRYPOINT
    ///     parsing of the full compose `command:` list; the existing command
    ///     corresponds to `[executable] + arguments`.
    private static func commandDivergenceReason(
        existing: ContainerSnapshot,
        expectedCommand: [String]?,
        expectedEntrypoint: [String]?
    ) -> String? {
        guard let expectedCommand else { return nil }
        let existingExec = existing.configuration.initProcess.executable
        let existingArgs = existing.configuration.initProcess.arguments
        let existingCommand: [String] = expectedEntrypoint != nil
            ? existingArgs
            : [existingExec] + existingArgs
        if existingCommand != expectedCommand {
            return "command diverged: existing=\(existingCommand) expected=\(expectedCommand)"
        }
        return nil
    }

    // MARK: - CHAOS-1496 label-primary divergence helpers
    //
    // Each helper reads a `compose.spec.*` label from the existing container
    // and compares it to the corresponding expected fingerprint computed from
    // the current compose-spec content. Three outcomes:
    //
    //   - Label PRESENT and MATCHES expected   → return nil (no divergence).
    //   - Label PRESENT and MISMATCHES expected → return a clear reason string.
    //   - Label ABSENT (pre-CHAOS-1496 container or skip-condition triggered
    //     at create time) → return nil (caller falls through to the existing
    //     snapshot-based FALLBACK check, preserving CHAOS-1492/1493 semantics).
    //
    // The expected* parameter is also nil when the corresponding compose-spec
    // content is empty (`canonicalXxxHash` returned nil because there is
    // nothing to fingerprint). In that case the check simply returns nil and
    // the fallback runs.
    //
    // All helpers stay PURE (read-only) and depend only on the existing
    // snapshot's labels dict + the precomputed expected hash, mirroring the
    // pattern of the existing CHAOS-1493 `dnsDivergenceReason` helper.

    /// CHAOS-1496 image-label divergence (PRIMARY for image drift).
    ///
    /// Compares the resolved `service.image` reference against the
    /// `compose.spec.image` label written by `LabelsArgs.fingerprintLabels`
    /// at create time. Match → nil. Mismatch → reason. Absent → nil (caller
    /// falls through to the existing string-comparison + `qualifyImageReference`
    /// check from CHAOS-1492 v1).
    private static func imageLabelDivergence(
        existing: ContainerSnapshot,
        expectedImageLabel: String?
    ) -> String? {
        guard let expectedImageLabel else { return nil }
        guard let labelValue = existing.configuration.labels["compose.spec.image"] else { return nil }
        if labelValue != expectedImageLabel {
            return "compose.spec.image mismatch — image reference changed: \(labelValue) -> \(expectedImageLabel)"
        }
        return nil
    }

    /// CHAOS-1496 entrypoint-hash divergence (PRIMARY for entrypoint/command drift).
    ///
    /// Compares the SHA256 of the canonical `(entrypoint ?? []) + (command ?? [])`
    /// against the `compose.spec.entrypoint.hash` label. The hash collapses both
    /// fields into one string-equality check, replacing the existing
    /// `commandDivergenceReason`'s reconstruction-aware comparison for
    /// post-CHAOS-1496 containers. Absent → nil (caller falls through to the
    /// existing reconstruction logic).
    private static func entrypointHashDivergence(
        existing: ContainerSnapshot,
        expectedEntrypointHash: String?
    ) -> String? {
        guard let expectedEntrypointHash else { return nil }
        guard let labelValue = existing.configuration.labels["compose.spec.entrypoint.hash"] else { return nil }
        if labelValue != expectedEntrypointHash {
            return "compose.spec.entrypoint.hash mismatch — entrypoint or command changed"
        }
        return nil
    }

    /// CHAOS-1496 env-hash divergence (PRIMARY for env drift).
    ///
    /// Compares the SHA256 of the canonical user-declared env (post-`${VAR}`
    /// substitution, pre-`containerIps` rewrite) against the
    /// `compose.spec.env.hash` label. The (a)-only form is intentional —
    /// see `mergeServiceEnvForFingerprint` for why the (b)-layer must NOT
    /// be hashed (chicken-and-egg with `containerIps` populated only after
    /// `resolveAdoption` runs). Absent → nil (caller falls through to the
    /// existing SUBSET-semantics `envDivergenceReason`).
    private static func envHashDivergence(
        existing: ContainerSnapshot,
        expectedEnvHash: String?
    ) -> String? {
        guard let expectedEnvHash else { return nil }
        guard let labelValue = existing.configuration.labels["compose.spec.env.hash"] else { return nil }
        if labelValue != expectedEnvHash {
            return "compose.spec.env.hash mismatch — environment changed"
        }
        return nil
    }

    /// CHAOS-1496 ports-hash divergence (PRIMARY for published-ports drift).
    ///
    /// Compares the SHA256 of the sorted, `composePortToRunArg`-canonicalized
    /// `service.ports` list against the `compose.spec.ports.hash` label.
    /// Absent → nil (caller falls through to the existing SET-equality
    /// `portsDivergenceReason`).
    private static func portsHashDivergence(
        existing: ContainerSnapshot,
        expectedPortsHash: String?
    ) -> String? {
        guard let expectedPortsHash else { return nil }
        guard let labelValue = existing.configuration.labels["compose.spec.ports.hash"] else { return nil }
        if labelValue != expectedPortsHash {
            return "compose.spec.ports.hash mismatch — published ports changed"
        }
        return nil
    }

    /// CHAOS-1496 networks-hash divergence (PRIMARY for network-attachment drift).
    ///
    /// Compares the SHA256 of the sorted resolved network names against the
    /// `compose.spec.networks.hash` label. Resolved names mirror the inline
    /// formula at the label-write site (env-substitution + top-level
    /// `networks.<k>.name` override). Absent → nil (caller falls through to
    /// the existing SET-equality `networkDivergenceReason`).
    ///
    /// CHAOS-1495 will introduce `resolveCanonicalNetworkName` in
    /// `Helper Functions.swift`; until that lands the inline formula is used
    /// at both the write site (`LabelsArgs.fingerprintLabels`) and the read
    /// site (via `expectedNetworkNamesForService`).
    private static func networksHashDivergence(
        existing: ContainerSnapshot,
        expectedNetworksHash: String?
    ) -> String? {
        guard let expectedNetworksHash else { return nil }
        guard let labelValue = existing.configuration.labels["compose.spec.networks.hash"] else { return nil }
        if labelValue != expectedNetworksHash {
            return "compose.spec.networks.hash mismatch — network attachments changed"
        }
        return nil
    }
}
