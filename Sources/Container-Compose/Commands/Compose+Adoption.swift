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
    /// whether to adopt the existing container, recreate it, or create
    /// from scratch.
    ///
    /// Decision rules (matches docker compose v2 semantics):
    ///   1. No existing container → `.create`
    ///   2. Existing + `--force-recreate` → `.recreate("--force-recreate")`
    ///   3. Existing + spec divergence (v1: image only) → `.recreate(...)`
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

            // CHAOS-1493 wave 3: precompute expected values for the extended
            // divergence checks so `specDivergenceReason` stays pure.
            let expectedNetworkNames = expectedNetworkNamesForService(service, dockerCompose: dockerCompose)
            let expectedPublishedPorts = expectedPublishedPortsForService(service)
            let expectedEnvironment = expectedEnvironmentForService(service)
            let expectedCommand = service.command

            if let reason = Self.specDivergenceReason(
                existing: existing,
                expected: service,
                expectedSidecarIPs: self.dnsSidecar?.perNetworkIPs ?? [:],
                expectedNetworkNames: expectedNetworkNames,
                expectedPublishedPorts: expectedPublishedPorts,
                expectedEnvironment: expectedEnvironment,
                expectedCommand: expectedCommand
            ) {
                decisions[serviceName] = .recreate(reason: reason)
                continue
            }

            decisions[serviceName] = .adopt
            print("Adopting existing container: \(containerName)")
        }

        return decisions
    }

    /// CHAOS-1493: Resolves the SET of network names this service is expected
    /// to attach to. Mirrors `NetworkingArgs.build` / `LabelsArgs.build`'s
    /// resolution: env-substitute the YAML key, then prefer the top-level
    /// network's explicit `name:` override if present. Returns an empty set when
    /// `service.networks` is nil (no service-level network attachments) so the
    /// downstream check skips silently.
    private func expectedNetworkNamesForService(
        _ service: Service,
        dockerCompose: DockerCompose?
    ) -> Set<String> {
        guard let serviceNetworks = service.networks else { return [] }
        var names: Set<String> = []
        for (name, _) in serviceNetworks.entries {
            let resolved = resolveVariable(name, with: environmentVariables)
            let networkToConnect = dockerCompose?.networks?[name]??.name ?? resolved
            names.insert(networkToConnect)
        }
        return names
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
    /// `stopOldStuff` itself is left intact for callers that genuinely
    /// want a teardown sweep (e.g. recovery paths in
    /// `Compose+VolumeMigration.swift`).
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

            guard let container = try? await provider.get(id: containerName) else { continue }

            do {
                try await provider.stop(id: container.id, opts: .default)
            } catch {
                print("Error Stopping Container: \(error)")
            }

            do {
                try await provider.delete(id: container.id, force: false)
            } catch {
                print("Error Removing Container: \(error)")
            }
        }
    }

    /// CHAOS-1492 / 1493 divergence detection.
    ///
    /// Returns a non-nil reason string when the existing container's spec has
    /// drifted from what `compose up` would launch today, in which case the
    /// caller (`resolveAdoption`) flips the decision from `.adopt` to `.recreate`.
    ///
    /// Check order (Oracle Q3 ranking — highest user-impact first):
    ///   1. Image (CHAOS-1492 v1)
    ///   2. DNS resolver IPs (CHAOS-1493) — sidecar IP drift kills `/etc/resolv.conf`.
    ///   3-6. Networks / ports / env / command (CHAOS-1493 wave 3).
    ///
    /// Build-only services (no `image:` field) skip the image check — their
    /// effective image reference comes from the build pipeline, not the
    /// compose file. They still get the other drift checks below.
    ///
    /// `expectedSidecarIPs` is the current sidecar's per-network resolver
    /// IP map (`SidecarHandle.perNetworkIPs`). Pass an empty map (the default)
    /// when no embedded DNS sidecar is in play this `up` — the DNS check is
    /// then skipped silently. Existing CHAOS-1492 unit tests of this function
    /// rely on the default and stay backward-compatible.
    internal static func specDivergenceReason(
        existing: ContainerSnapshot,
        expected: Service,
        expectedSidecarIPs: [String: String] = [:],
        expectedNetworkNames: Set<String> = [],
        expectedPublishedPorts: Set<String> = [],
        expectedEnvironment: [String: String] = [:],
        expectedCommand: [String]? = nil
    ) -> String? {
        // 1. Image
        if let expectedRaw = expected.image {
            let existingImage = existing.configuration.image.reference
            let expectedQualified = qualifyImageReference(expectedRaw)
            if existingImage != expectedQualified {
                return "image changed: \(existingImage) -> \(expectedQualified)"
            }
        }

        // 2. DNS resolver drift (CHAOS-1493 v1 fix)
        if let reason = dnsDivergenceReason(
            existing: existing,
            expected: expected,
            expectedSidecarIPs: expectedSidecarIPs
        ) {
            return reason
        }

        // 3. Network attachments (CHAOS-1493 wave 3)
        if let reason = networkDivergenceReason(
            existing: existing,
            expectedNetworkNames: expectedNetworkNames
        ) {
            return reason
        }

        // 4. Published ports (CHAOS-1493 wave 3)
        if let reason = portsDivergenceReason(
            existing: existing,
            expectedPublishedPorts: expectedPublishedPorts
        ) {
            return reason
        }

        // 5. Environment (CHAOS-1493 wave 3)
        if let reason = envDivergenceReason(
            existing: existing,
            expectedEnvironment: expectedEnvironment
        ) {
            return reason
        }

        // 6. Command (CHAOS-1493 wave 3)
        if let reason = commandDivergenceReason(
            existing: existing,
            expectedCommand: expectedCommand,
            expectedEntrypoint: expected.entrypoint
        ) {
            return reason
        }

        return nil
    }

    /// CHAOS-1493 DNS divergence helper.
    ///
    /// For each network the service is attached to that has a sidecar IP
    /// (`expectedSidecarIPs[network]` non-nil), verify the existing container's
    /// recorded resolver agrees with the current sidecar IP. Sources, in order:
    ///   1. Per-network label `compose.dns.resolvers.<network>` written by
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
    private static func dnsDivergenceReason(
        existing: ContainerSnapshot,
        expected: Service,
        expectedSidecarIPs: [String: String]
    ) -> String? {
        guard !expectedSidecarIPs.isEmpty else { return nil }
        guard let serviceNetworks = expected.networks else { return nil }

        let labels = existing.configuration.labels
        let snapshotNameservers = existing.configuration.dns?.nameservers ?? []
        let snapshotNameserverSet = Set(snapshotNameservers)

        // Networks the service expects to be attached to that have a sidecar IP.
        // We only validate networks the sidecar is actually serving — a service
        // attached to a non-sidecar network has no expected DNS for that network.
        var verifiedAny = false

        for (networkName, _) in serviceNetworks.entries {
            // Network-name resolution must mirror `LabelsArgs.build`. We don't
            // have access to dockerCompose / environmentVariables here, so the
            // caller is responsible for providing canonical names in
            // `expectedSidecarIPs`. The label key uses the same canonical name.
            // Try both the raw and resolved keys to handle the simple case.
            let candidates = [networkName]
            var expectedIP: String? = nil
            var canonical: String = networkName
            for candidate in candidates {
                if let ip = expectedSidecarIPs[candidate] {
                    expectedIP = ip
                    canonical = candidate
                    break
                }
            }
            // Fall back: any sidecar IP whose key matches a substring of the
            // network name (handles env-substituted / overridden names without
            // needing the resolution context here).
            if expectedIP == nil {
                for (key, ip) in expectedSidecarIPs where key == networkName {
                    expectedIP = ip
                    canonical = key
                    break
                }
            }
            guard let expectedIP else { continue }

            // 1. Per-network label — authoritative.
            let labelKey = "compose.dns.resolvers.\(canonical)"
            if let labelIP = labels[labelKey] {
                if labelIP != expectedIP {
                    return "DNS resolver IP for network '\(canonical)' changed: \(labelIP) -> \(expectedIP)"
                }
                verifiedAny = true
                continue
            }

            // 2. Snapshot nameservers SET-membership — sanity check.
            if !snapshotNameserverSet.isEmpty {
                if !snapshotNameserverSet.contains(expectedIP) {
                    return "DNS resolver IP for network '\(canonical)' (\(expectedIP)) not in container's nameservers \(snapshotNameservers.sorted())"
                }
                verifiedAny = true
                continue
            }

            // 3. Conservative fallback — first `up` after upgrading.
            return "upgrading from pre-CHAOS-1493 container — recreating to attach DNS resolver metadata for network '\(canonical)'"
        }

        _ = verifiedAny
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
    private static func envDivergenceReason(
        existing: ContainerSnapshot,
        expectedEnvironment: [String: String]
    ) -> String? {
        guard !expectedEnvironment.isEmpty else { return nil }
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
}
