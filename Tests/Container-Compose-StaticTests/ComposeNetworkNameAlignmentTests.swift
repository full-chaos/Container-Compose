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

// CHAOS-1495: Network-name key alignment audit — env-substituted / aliased /
// external network references.
//
// CHAOS-1493 wrote per-network DNS labels (`compose.dns.resolvers.<X>=<ip>`)
// using the formula `dockerCompose.networks?[name]??.name ?? resolveVariable(name, env)`
// at the label-WRITE site. The matching label-READ site in `dnsDivergenceReason`
// looked up `expectedSidecarIPs[name]` and `labels["compose.dns.resolvers.\(name)"]`
// using the **raw** service-level YAML key. For env-substituted (`${PROJECT_NET}`)
// or aliased (`networks: { foo: { name: bar } }`) networks the raw and canonical
// strings differ, so the read silently missed → DNS drift undetected → adopted
// services kept stale `/etc/resolv.conf`.
//
// The fix:
//   1. Extract `resolveCanonicalNetworkName(_:dockerCompose:environmentVariables:)`
//      in `Helper Functions.swift` (a single source of truth).
//   2. Route LabelsArgs.build, NetworkingArgs.build, and
//      expectedNetworkNamesForService through the helper (pure refactor — same
//      formula).
//   3. Plumb a precomputed `serviceNetworkCanonicalNames: [raw: canonical]` map
//      through `specDivergenceReason → dnsDivergenceReason` so the read-side
//      uses the canonical string (the bug fix). Default-empty preserves
//      pre-CHAOS-1495 backward compatibility for callers/tests that don't
//      exercise env or alias indirection.
//
// This file pins:
//   - The four-site agreement (label key, --network argv, --dns lookup,
//     divergence-read set) for each of the three audited cases.
//   - The DNS-drift regression: with a stale label IP for a non-trivially-named
//     network, `specDivergenceReason` MUST return a recreate reason (was nil
//     before the fix).
//   - The helper itself (unit tests for the four resolution branches).

import Testing
import Foundation
@testable import Yams
import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
@testable import ContainerComposeCore
import TestHelpers

@Suite("Network name canonical resolution (CHAOS-1495)", .serialized)
struct ComposeNetworkNameAlignmentTests {

    // MARK: - Fixture helpers

    /// Decode a compose YAML literal into the canonical `DockerCompose` value
    /// the production code consumes.
    private func decode(yaml: String) throws -> DockerCompose {
        try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    /// Minimal sidecar handle pinning the per-network IP map. The test never
    /// touches the on-disk config root, so any path works.
    private func sidecar(perNetworkIPs: [String: String]) -> SidecarHandle {
        SidecarHandle.forCleanup(projectName: "cc-test-1495").asAdopted(perNetworkIPs: perNetworkIPs)
    }

    /// Build an `ArgsContext` for the four-site label/argv assertions.
    private func ctx(
        service: Service,
        dockerCompose: DockerCompose,
        environment: [String: String] = [:],
        dnsSidecar: SidecarHandle? = nil
    ) -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "cc-test-1495",
            containerName: "cc-test-1495-svc",
            detach: false,
            environmentVariables: environment,
            dockerCompose: dockerCompose,
            composeFilename: nil,
            dnsSidecar: dnsSidecar
        )
    }

    /// Build a snapshot for an existing container with the supplied DNS labels.
    /// Used to drive `specDivergenceReason` through the bug-fixed code path.
    private func snapshot(
        id: String,
        imageReference: String,
        labels: [String: String]
    ) -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [String](),
            workingDirectory: "/"
        )
        var config = ContainerConfiguration(
            id: id,
            image: ImageDescription(
                reference: imageReference,
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:\(String(repeating: "0", count: 64))",
                    size: 0
                )
            ),
            process: process
        )
        config.labels = labels
        return ContainerSnapshot(configuration: config, status: .running, networks: [])
    }

    // MARK: - Helper unit tests (resolveCanonicalNetworkName)

    @Test("helper: returns raw key when no override and no env reference")
    func helperRawKey() throws {
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
            networks:
              plain-net:
                driver: bridge
            """)
        #expect(resolveCanonicalNetworkName("plain-net", dockerCompose: cc, environmentVariables: [:]) == "plain-net")
    }

    @Test("helper: top-level name override wins over raw key")
    func helperAliasOverride() throws {
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
            networks:
              foo:
                name: bar
            """)
        #expect(resolveCanonicalNetworkName("foo", dockerCompose: cc, environmentVariables: [:]) == "bar")
    }

    @Test("helper: env-substituted reference resolves to current env value")
    func helperEnvSubstitution() throws {
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
            networks:
              default-net:
                driver: bridge
            """)
        let resolved = resolveCanonicalNetworkName(
            "${PROJECT_NET}",
            dockerCompose: cc,
            environmentVariables: ["PROJECT_NET": "default-net"]
        )
        #expect(resolved == "default-net")
    }

    @Test("helper: external + name override returns the override (canonical 3b form)")
    func helperExternalWithAlias() throws {
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
            networks:
              foo:
                external: true
                name: bar
            """)
        #expect(resolveCanonicalNetworkName("foo", dockerCompose: cc, environmentVariables: [:]) == "bar")
    }

    @Test("helper: external without override returns the raw key (canonical 3a form)")
    func helperExternalNoAlias() throws {
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
            networks:
              foo:
                external: true
            """)
        #expect(resolveCanonicalNetworkName("foo", dockerCompose: cc, environmentVariables: [:]) == "foo")
    }

    @Test("helper: nil dockerCompose falls through to env-only resolution")
    func helperNilDockerCompose() {
        #expect(resolveCanonicalNetworkName("plain", dockerCompose: nil, environmentVariables: [:]) == "plain")
        #expect(
            resolveCanonicalNetworkName(
                "${X}",
                dockerCompose: nil,
                environmentVariables: ["X": "expanded"]
            ) == "expanded"
        )
    }

    // MARK: - Case 1: env-substituted four-site agreement + DNS-drift regression

    @Test("Case 1 (env-substituted): all four sites agree on the env-resolved canonical name")
    func case1EnvSubstitutedFourSiteAgreement() throws {
        // YAML: top-level network is the literal `default-net`; the service
        // references it via `${PROJECT_NET}`. With env mapping to `default-net`,
        // every site MUST resolve to `default-net`.
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
                networks:
                  - ${PROJECT_NET}
            networks:
              default-net:
                driver: bridge
            """)
        let env = ["PROJECT_NET": "default-net"]
        let svc = try #require(cc.services["svc"] ?? nil)
        let sidecarIP = "10.0.0.5"
        let sh = sidecar(perNetworkIPs: ["default-net": sidecarIP])

        // Site A — label-write
        let labelArgs = ComposeUp.LabelsArgs.build(
            ctx(service: svc, dockerCompose: cc, environment: env, dnsSidecar: sh)
        )
        #expect(labelArgs.contains("compose.dns.resolvers.default-net=\(sidecarIP)"))
        #expect(labelArgs.allSatisfy { !$0.contains("${PROJECT_NET}") },
                "label key must NOT contain the unresolved env reference")

        // Site B — --network + --dns
        let netArgs = ComposeUp.NetworkingArgs.build(
            ctx(service: svc, dockerCompose: cc, environment: env, dnsSidecar: sh)
        )
        let networkPair = adjacentValues(in: netArgs, after: "--network")
        #expect(networkPair == ["default-net"], "--network must use canonical: \(networkPair)")
        let dnsValues = adjacentValues(in: netArgs, after: "--dns")
        #expect(dnsValues == [sidecarIP], "--dns lookup must hit perNetworkIPs[\"default-net\"]: \(dnsValues)")

        // Site C — divergence-read SET
        var cmd = try ComposeUp.parse([])
        cmd.projectName = "cc-test-1495-c1"
        let names = cmd.expectedNetworkNamesForService(svc, dockerCompose: cc, environment: env)
        #expect(names == Set(["default-net"]))

        // Site D regression — stale label IP MUST be detected
        let stale = snapshot(
            id: "cc-test-1495-c1-svc",
            imageReference: "docker.io/library/alpine:latest",
            labels: ["compose.dns.resolvers.default-net": "10.0.0.99"] // pre-drift IP
        )
        let canonicalMap = cmd.serviceNetworkCanonicalNamesMap(svc, dockerCompose: cc, environment: env)
        #expect(canonicalMap == ["${PROJECT_NET}": "default-net"])
        let reason = ComposeUp.specDivergenceReason(
            existing: stale,
            expected: svc,
            expectedSidecarIPs: ["default-net": sidecarIP],
            serviceNetworkCanonicalNames: canonicalMap
        )
        #expect(reason != nil, "DNS divergence MUST be detected for env-substituted networks (CHAOS-1495 regression)")
        #expect(reason?.contains("DNS resolver IP") == true)
        #expect(reason?.contains("default-net") == true)
    }

    @Test("Case 1 regression: pre-fix call without canonical map silently misses (identity fallback for legacy callers)")
    func case1LegacyIdentityFallback() throws {
        // Documents that the legacy call shape (no `serviceNetworkCanonicalNames`)
        // preserves the OLD behavior — raw=="${PROJECT_NET}" doesn't appear in
        // either the labels or the sidecar IP map, so divergence falls through
        // to the conservative pre-CHAOS-1493 fallback.
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
                networks:
                  - ${PROJECT_NET}
            networks:
              default-net:
                driver: bridge
            """)
        let svc = try #require(cc.services["svc"] ?? nil)
        let stale = snapshot(
            id: "cc-test-1495-c1-legacy-svc",
            imageReference: "docker.io/library/alpine:latest",
            labels: ["compose.dns.resolvers.default-net": "10.0.0.99"]
        )
        let reason = ComposeUp.specDivergenceReason(
            existing: stale,
            expected: svc,
            expectedSidecarIPs: ["default-net": "10.0.0.5"]
            // serviceNetworkCanonicalNames defaulted to [:] — identity fallback
        )
        // Identity fallback: raw "${PROJECT_NET}" → expectedSidecarIPs["${PROJECT_NET}"] = nil → skip.
        // No false positives, but no detection either. Real callers
        // (`resolveAdoption`) always pass the explicit map.
        #expect(reason == nil, "legacy callers (no canonical map) must not regress with false positives")
    }

    // MARK: - Case 2: aliased four-site agreement + DNS-drift regression

    @Test("Case 2 (aliased): all four sites agree on the top-level `name:` override")
    func case2AliasedFourSiteAgreement() throws {
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
                networks:
                  - foo
            networks:
              foo:
                name: bar
                driver: bridge
            """)
        let svc = try #require(cc.services["svc"] ?? nil)
        let sidecarIP = "10.0.0.7"
        let sh = sidecar(perNetworkIPs: ["bar": sidecarIP])

        // Site A — label key uses the alias `bar`, never `foo`.
        let labelArgs = ComposeUp.LabelsArgs.build(
            ctx(service: svc, dockerCompose: cc, dnsSidecar: sh)
        )
        #expect(labelArgs.contains("compose.dns.resolvers.bar=\(sidecarIP)"))
        #expect(!labelArgs.contains(where: { $0.hasPrefix("compose.dns.resolvers.foo") }),
                "label key must NOT use the raw YAML key when an alias is set")

        // Site B — argv uses the alias.
        let netArgs = ComposeUp.NetworkingArgs.build(
            ctx(service: svc, dockerCompose: cc, dnsSidecar: sh)
        )
        #expect(adjacentValues(in: netArgs, after: "--network") == ["bar"])
        #expect(adjacentValues(in: netArgs, after: "--dns") == [sidecarIP])

        // Site C — divergence set uses the alias.
        var cmd = try ComposeUp.parse([])
        cmd.projectName = "cc-test-1495-c2"
        let names = cmd.expectedNetworkNamesForService(svc, dockerCompose: cc)
        #expect(names == Set(["bar"]))

        // Site D regression.
        let stale = snapshot(
            id: "cc-test-1495-c2-svc",
            imageReference: "docker.io/library/alpine:latest",
            labels: ["compose.dns.resolvers.bar": "10.0.0.99"]
        )
        let canonicalMap = cmd.serviceNetworkCanonicalNamesMap(svc, dockerCompose: cc, environment: [:])
        #expect(canonicalMap == ["foo": "bar"])
        let reason = ComposeUp.specDivergenceReason(
            existing: stale,
            expected: svc,
            expectedSidecarIPs: ["bar": sidecarIP],
            serviceNetworkCanonicalNames: canonicalMap
        )
        #expect(reason != nil, "DNS divergence MUST be detected for aliased networks (CHAOS-1495 regression)")
        #expect(reason?.contains("'bar'") == true,
                "reason MUST reference the canonical name `bar`, not the raw key `foo`")
    }

    @Test("Case 2 regression: pre-fix legacy call (no canonical map) misses the drift silently")
    func case2LegacyIdentityFallback() throws {
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
                networks:
                  - foo
            networks:
              foo:
                name: bar
                driver: bridge
            """)
        let svc = try #require(cc.services["svc"] ?? nil)
        let stale = snapshot(
            id: "cc-test-1495-c2-legacy-svc",
            imageReference: "docker.io/library/alpine:latest",
            labels: ["compose.dns.resolvers.bar": "10.0.0.99"]
        )
        let reason = ComposeUp.specDivergenceReason(
            existing: stale,
            expected: svc,
            expectedSidecarIPs: ["bar": "10.0.0.7"]
        )
        // Identity fallback: raw "foo" → expectedSidecarIPs["foo"] = nil → skip.
        #expect(reason == nil, "legacy aliased call without canonical map preserves no-op identity behavior")
    }

    // MARK: - Case 3: external four-site agreement + DNS-drift regression

    @Test("Case 3a (external true): all four sites agree on the raw key when no override")
    func case3aExternalNoAlias() throws {
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
                networks:
                  - foo
            networks:
              foo:
                external: true
            """)
        let svc = try #require(cc.services["svc"] ?? nil)
        let sidecarIP = "10.0.0.11"
        let sh = sidecar(perNetworkIPs: ["foo": sidecarIP])

        let labelArgs = ComposeUp.LabelsArgs.build(
            ctx(service: svc, dockerCompose: cc, dnsSidecar: sh)
        )
        #expect(labelArgs.contains("compose.dns.resolvers.foo=\(sidecarIP)"))

        let netArgs = ComposeUp.NetworkingArgs.build(
            ctx(service: svc, dockerCompose: cc, dnsSidecar: sh)
        )
        #expect(adjacentValues(in: netArgs, after: "--network") == ["foo"])
        #expect(adjacentValues(in: netArgs, after: "--dns") == [sidecarIP])

        var cmd = try ComposeUp.parse([])
        cmd.projectName = "cc-test-1495-c3a"
        #expect(cmd.expectedNetworkNamesForService(svc, dockerCompose: cc) == Set(["foo"]))

        // Drift detection works (raw==canonical here, but exercise the path anyway).
        let stale = snapshot(
            id: "cc-test-1495-c3a-svc",
            imageReference: "docker.io/library/alpine:latest",
            labels: ["compose.dns.resolvers.foo": "10.0.0.99"]
        )
        let reason = ComposeUp.specDivergenceReason(
            existing: stale,
            expected: svc,
            expectedSidecarIPs: ["foo": sidecarIP],
            serviceNetworkCanonicalNames: cmd.serviceNetworkCanonicalNamesMap(svc, dockerCompose: cc, environment: [:])
        )
        #expect(reason != nil)
        #expect(reason?.contains("'foo'") == true)
    }

    @Test("Case 3b (external + name override): all four sites agree on the alias, drift detected")
    func case3bExternalAliased() throws {
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
                networks:
                  - foo
            networks:
              foo:
                external: true
                name: bar
            """)
        let svc = try #require(cc.services["svc"] ?? nil)
        let sidecarIP = "10.0.0.13"
        let sh = sidecar(perNetworkIPs: ["bar": sidecarIP])

        let labelArgs = ComposeUp.LabelsArgs.build(
            ctx(service: svc, dockerCompose: cc, dnsSidecar: sh)
        )
        #expect(labelArgs.contains("compose.dns.resolvers.bar=\(sidecarIP)"))

        let netArgs = ComposeUp.NetworkingArgs.build(
            ctx(service: svc, dockerCompose: cc, dnsSidecar: sh)
        )
        #expect(adjacentValues(in: netArgs, after: "--network") == ["bar"])
        #expect(adjacentValues(in: netArgs, after: "--dns") == [sidecarIP])

        var cmd = try ComposeUp.parse([])
        cmd.projectName = "cc-test-1495-c3b"
        #expect(cmd.expectedNetworkNamesForService(svc, dockerCompose: cc) == Set(["bar"]))

        // Site D regression — same root cause as Case 2.
        let stale = snapshot(
            id: "cc-test-1495-c3b-svc",
            imageReference: "docker.io/library/alpine:latest",
            labels: ["compose.dns.resolvers.bar": "10.0.0.99"]
        )
        let canonicalMap = cmd.serviceNetworkCanonicalNamesMap(svc, dockerCompose: cc, environment: [:])
        #expect(canonicalMap == ["foo": "bar"])
        let reason = ComposeUp.specDivergenceReason(
            existing: stale,
            expected: svc,
            expectedSidecarIPs: ["bar": sidecarIP],
            serviceNetworkCanonicalNames: canonicalMap
        )
        #expect(reason != nil, "DNS divergence MUST be detected for aliased external networks (CHAOS-1495 regression)")
        #expect(reason?.contains("'bar'") == true)
    }

    // MARK: - Case 3c (CHAOS-1497): deprecated nested form `external: { name: bar }`

    @Test("Case 3c (external.name nested form, CHAOS-1497): four-site agreement, drift detected")
    func case3cExternalNameInsideDict() throws {
        // The DEPRECATED compose-spec form where the rename lives INSIDE
        // `external` rather than at top-level `name:`. The model layer decodes
        // it correctly (`ExternalNetwork.name`), but every read site historically
        // looked at `network.name` only, never `network.external?.name`.
        // Result: sidecar tries `--network foo` while apple/container has the
        // network as `bar` → `waitForRunningSidecar` times out.
        //
        // Fix: 3-tier fallback `network.name ?? network.external?.name ?? networkKey`
        // at every name-resolution site (helper + 4 use sites).
        let cc = try decode(yaml: """
            services:
              svc:
                image: alpine:latest
                networks:
                  - foo
            networks:
              foo:
                external:
                  name: bar
            """)
        let svc = try #require(cc.services["svc"] ?? nil)
        let sidecarIP = "10.0.0.17"
        let sh = sidecar(perNetworkIPs: ["bar": sidecarIP])

        // Site A — label key uses the nested-external alias `bar`, never `foo`.
        let labelArgs = ComposeUp.LabelsArgs.build(
            ctx(service: svc, dockerCompose: cc, dnsSidecar: sh)
        )
        #expect(labelArgs.contains("compose.dns.resolvers.bar=\(sidecarIP)"))
        #expect(!labelArgs.contains(where: { $0.hasPrefix("compose.dns.resolvers.foo") }),
                "label key must NOT use the raw YAML key when external.name is set")

        // Site B — argv uses the alias.
        let netArgs = ComposeUp.NetworkingArgs.build(
            ctx(service: svc, dockerCompose: cc, dnsSidecar: sh)
        )
        #expect(adjacentValues(in: netArgs, after: "--network") == ["bar"])
        #expect(adjacentValues(in: netArgs, after: "--dns") == [sidecarIP])

        // Site C — divergence set uses the alias.
        var cmd = try ComposeUp.parse([])
        cmd.projectName = "cc-test-1497-c3c"
        #expect(cmd.expectedNetworkNamesForService(svc, dockerCompose: cc) == Set(["bar"]))

        // Site D regression — drift on the canonical name MUST be detected.
        let stale = snapshot(
            id: "cc-test-1497-c3c-svc",
            imageReference: "docker.io/library/alpine:latest",
            labels: ["compose.dns.resolvers.bar": "10.0.0.99"]
        )
        let canonicalMap = cmd.serviceNetworkCanonicalNamesMap(svc, dockerCompose: cc, environment: [:])
        #expect(canonicalMap == ["foo": "bar"])
        let reason = ComposeUp.specDivergenceReason(
            existing: stale,
            expected: svc,
            expectedSidecarIPs: ["bar": sidecarIP],
            serviceNetworkCanonicalNames: canonicalMap
        )
        #expect(reason != nil, "DNS divergence MUST be detected for nested-external-name networks (CHAOS-1497)")
        #expect(reason?.contains("'bar'") == true,
                "reason MUST reference the canonical name `bar`, not the raw key `foo`")
    }

    // MARK: - Helper utilities

    /// Returns each value immediately following `flag` in a flag-then-value
    /// argv list. Order-preserving, allows multiple occurrences of the same
    /// flag (used to assert multi-network repeats).
    private func adjacentValues(in argv: [String], after flag: String) -> [String] {
        var result: [String] = []
        var iterator = argv.makeIterator()
        while let next = iterator.next() {
            if next == flag, let value = iterator.next() {
                result.append(value)
            }
        }
        return result
    }
}

// MARK: - SidecarHandle test ergonomics

private extension SidecarHandle {
    /// Reconstruct an "adopted" handle with a per-network IP map suitable for
    /// in-memory tests. Mirrors the production `forCleanup` factory so we don't
    /// touch the disk root.
    func asAdopted(perNetworkIPs: [String: String]) -> SidecarHandle {
        SidecarHandle(
            projectName: projectName,
            containerName: containerName,
            configRoot: configRoot,
            perNetworkIPs: perNetworkIPs,
            wasAdopted: true
        )
    }
}
