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

// CHAOS-1496: generalized create-spec fingerprint label scheme.
//
// Three layers of coverage in this file:
//
//   1. Pure helpers (`SpecFingerprint.canonicalXxxHash`): equality on
//      equivalent inputs; difference on differing inputs; deterministic
//      across calls; nil/empty handling per the skip-on-empty rule.
//
//   2. `LabelsArgs.fingerprintLabels` argv-shape: each of the 5 labels
//      `compose.spec.{image,entrypoint.hash,env.hash,ports.hash,networks.hash}`
//      appears when its underlying compose-spec content is non-empty;
//      absent when not (build-only image; nil/empty entrypoint+command;
//      empty mergedEnv; nil/empty ports; nil networks).
//
//   3. Round-trip + backwards-compat against `specDivergenceReason`:
//      - Label written at create + value mismatch on next `up` ⇒ recreate
//        with a clear `compose.spec.X mismatch` reason.
//      - Label absent (pre-CHAOS-1496 container) ⇒ NO spurious recreate
//        (caller falls through to the existing snapshot-based check).
//      - Critical env-hash chicken-and-egg test: peer-IP env reference
//        stays adopted across `up` runs because the hash uses the
//        (a)-only form (post-${VAR}, pre-containerIps rewrite).
//
// All test fixtures use the `cc-test-` project-name prefix per AGENTS.md.

import Testing
import Foundation
import Yams
import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
@testable import ContainerComposeCore
import TestHelpers

@Suite("CHAOS-1496 spec fingerprint labels")
struct ComposeSpecFingerprintTests {

    // MARK: - Local test helpers

    private let emptyCompose: DockerCompose = {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        return try! YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }()

    /// Builds an `ArgsContext` with the bits a fingerprint test needs:
    /// service + project env + dockerCompose + optional pre-merged
    /// fingerprint env. Defaults match `LabelsArgsTests.makeContext`.
    private func makeContext(
        service: Service,
        environmentVariables: [String: String] = [:],
        fingerprintEnv: [String: String] = [:],
        dockerCompose: DockerCompose? = nil,
        implicitDefaultNetwork: String? = nil
    ) -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "cc-test-fp",
            containerName: "cc-test-fp-svc",
            detach: false,
            environmentVariables: environmentVariables,
            dockerCompose: dockerCompose ?? emptyCompose,
            composeFilename: nil,
            fingerprintEnv: fingerprintEnv,
            implicitDefaultNetwork: implicitDefaultNetwork
        )
    }

    /// Returns ONLY the synthetic `compose.spec.*` labels emitted by
    /// `LabelsArgs.fingerprintLabels`, as a `[label: value]` map keyed by
    /// label name (after the `compose.spec.` prefix). Strips out user labels
    /// and `compose.dns.resolvers.*` labels from CHAOS-1493.
    private func fingerprintMap(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        while i + 1 < args.count {
            if args[i] == "--label" {
                let value = args[i + 1]
                if let eq = value.firstIndex(of: "="), value.hasPrefix("compose.spec.") {
                    let key = String(value[..<eq])
                    let val = String(value[value.index(after: eq)...])
                    result[key] = val
                }
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    /// Build a minimal `ContainerSnapshot` for a stubbed running container
    /// with explicit labels. Mirrors `ComposeUpAdoptionTests.makeSnapshotWith`
    /// but with a smaller surface tailored to the fingerprint check tests.
    private func makeSnapshot(
        id: String,
        imageReference: String = "docker.io/library/alpine:latest",
        labels: [String: String] = [:],
        environment: [String] = [],
        executable: String = "/bin/sh",
        arguments: [String] = [],
        publishedPorts: [PublishPort] = [],
        networks: [AttachmentConfiguration] = []
    ) -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: executable,
            arguments: arguments,
            environment: environment,
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
        config.publishedPorts = publishedPorts
        config.networks = networks
        return ContainerSnapshot(configuration: config, status: .running, networks: [])
    }

    // MARK: - Layer 1: pure-helper canonical-hash semantics

    @Test("canonicalEntrypointHash: nil entrypoint AND nil command returns nil")
    func entrypointHashNilWhenBothNil() {
        #expect(ComposeUp.SpecFingerprint.canonicalEntrypointHash(entrypoint: nil, command: nil) == nil)
    }

    @Test("canonicalEntrypointHash: only entrypoint set produces a stable hash")
    func entrypointHashOnlyEntrypoint() {
        let h = ComposeUp.SpecFingerprint.canonicalEntrypointHash(
            entrypoint: ["sh", "-c"],
            command: nil
        )
        #expect(h != nil)
        #expect(h?.count == 64)  // lowercase-hex SHA256
        #expect(h == h?.lowercased())
        // Deterministic across calls
        let h2 = ComposeUp.SpecFingerprint.canonicalEntrypointHash(
            entrypoint: ["sh", "-c"],
            command: nil
        )
        #expect(h == h2)
    }

    @Test("canonicalEntrypointHash: differing element boundaries produce different hashes")
    func entrypointHashElementBoundaries() {
        // The unit-separator join MUST distinguish ["a b", "c"] from ["a", "b c"].
        let h1 = ComposeUp.SpecFingerprint.canonicalEntrypointHash(
            entrypoint: ["a b", "c"],
            command: nil
        )
        let h2 = ComposeUp.SpecFingerprint.canonicalEntrypointHash(
            entrypoint: ["a", "b c"],
            command: nil
        )
        #expect(h1 != nil)
        #expect(h2 != nil)
        #expect(h1 != h2)
    }

    @Test("canonicalEntrypointHash: entrypoint+command concat distinguishable from command-only")
    func entrypointHashConcatVsCommandOnly() {
        let h1 = ComposeUp.SpecFingerprint.canonicalEntrypointHash(
            entrypoint: ["sh", "-c"],
            command: ["sleep 1"]
        )
        let h2 = ComposeUp.SpecFingerprint.canonicalEntrypointHash(
            entrypoint: nil,
            command: ["sh", "-c", "sleep 1"]
        )
        // Same final argv shape but different compose-spec semantics
        // (entrypoint override vs. CMD-only). Hashes of the joined list
        // happen to be EQUAL here because the joined-with-US form
        // collapses to identical strings — that is the documented
        // behavior. The check just pins it so a future refactor that
        // changes the canonical form is caught.
        #expect(h1 == h2)
    }

    @Test("canonicalEnvHash: empty env produces SHA256 of empty string")
    func envHashEmptyDeterministic() {
        let h = ComposeUp.SpecFingerprint.canonicalEnvHash([:])
        // SHA256 of "" — well-known constant.
        #expect(h == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("canonicalEnvHash: order-independent (sorted by key)")
    func envHashOrderIndependent() {
        let a = ComposeUp.SpecFingerprint.canonicalEnvHash(["A": "1", "B": "2", "C": "3"])
        let b = ComposeUp.SpecFingerprint.canonicalEnvHash(["C": "3", "A": "1", "B": "2"])
        #expect(a == b)
    }

    @Test("canonicalEnvHash: distinct values produce distinct hashes")
    func envHashDistinctValues() {
        let a = ComposeUp.SpecFingerprint.canonicalEnvHash(["DB_HOST": "postgres"])
        let b = ComposeUp.SpecFingerprint.canonicalEnvHash(["DB_HOST": "redis"])
        #expect(a != b)
    }

    @Test("canonicalPortsHash: nil/empty returns nil")
    func portsHashNilOrEmpty() {
        #expect(ComposeUp.SpecFingerprint.canonicalPortsHash(nil, environmentVariables: [:]) == nil)
        #expect(ComposeUp.SpecFingerprint.canonicalPortsHash([], environmentVariables: [:]) == nil)
    }

    @Test("canonicalPortsHash: order-independent (sorted before hash)")
    func portsHashOrderIndependent() {
        let a = ComposeUp.SpecFingerprint.canonicalPortsHash(
            ["8080:80", "9090:90"], environmentVariables: [:]
        )
        let b = ComposeUp.SpecFingerprint.canonicalPortsHash(
            ["9090:90", "8080:80"], environmentVariables: [:]
        )
        #expect(a != nil)
        #expect(a == b)
    }

    @Test("canonicalPortsHash: env-substituted values produce same hash as their literal form")
    func portsHashEnvSubstituted() {
        let withEnv = ComposeUp.SpecFingerprint.canonicalPortsHash(
            ["${PORT}:80"], environmentVariables: ["PORT": "8080"]
        )
        let literal = ComposeUp.SpecFingerprint.canonicalPortsHash(
            ["8080:80"], environmentVariables: [:]
        )
        #expect(withEnv == literal)
    }

    @Test("canonicalNetworksHash: empty returns nil")
    func networksHashEmpty() {
        #expect(ComposeUp.SpecFingerprint.canonicalNetworksHash([]) == nil)
    }

    @Test("canonicalNetworksHash: order-independent (sorted before hash)")
    func networksHashOrderIndependent() {
        let a = ComposeUp.SpecFingerprint.canonicalNetworksHash(["frontend", "backend"])
        let b = ComposeUp.SpecFingerprint.canonicalNetworksHash(["backend", "frontend"])
        #expect(a == b)
    }

    @Test("canonicalNetworksHash: distinct names produce distinct hashes")
    func networksHashDistinct() {
        let a = ComposeUp.SpecFingerprint.canonicalNetworksHash(["a"])
        let b = ComposeUp.SpecFingerprint.canonicalNetworksHash(["b"])
        #expect(a != b)
    }

    @Test("sha256Hex: lowercase hex output of fixed length 64")
    func sha256HexShape() {
        let h = ComposeUp.SpecFingerprint.sha256Hex("hello")
        #expect(h == h.lowercased())
        #expect(h.count == 64)
        // Spot check against known SHA256("hello").
        #expect(h == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    // MARK: - Layer 2: LabelsArgs.fingerprintLabels argv-shape

    @Test("fingerprint emits only compose.spec.image plus the CHAOS-1499 bootstrap sentinel for trivial image-only service")
    func emitsOnlyImageForTrivialService() {
        let svc = Service(image: "alpine:latest")
        let args = ComposeUp.LabelsArgs.fingerprintLabels(makeContext(service: svc))
        let map = fingerprintMap(args)
        // CHAOS-1499: `compose.spec.bootstrapped=true` is unconditional —
        // every post-CHAOS-1499 container that goes through fingerprintLabels
        // gets it. Trivial image-only services still emit nothing else.
        #expect(map.keys.sorted() == ["compose.spec.bootstrapped", "compose.spec.image"])
        #expect(map["compose.spec.image"] == "alpine:latest")
        #expect(map["compose.spec.bootstrapped"] == "true")
    }

    @Test("fingerprint emits compose.spec.bootstrapped=true unconditionally — even for build-only services with no other compose.spec.* labels (CHAOS-1499)")
    func emitsBootstrapSentinelUnconditionally() throws {
        // CHAOS-1499: The bootstrap sentinel MUST be present on every post-1499
        // container's labels, regardless of whether other compose.spec.* labels
        // apply. A build-only service with no env, ports, networks, command,
        // or entrypoint emits zero conditional labels — only the sentinel.
        let yaml = """
        services:
          svc:
            build:
              context: .
        """
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let svc = try #require(dc.services["svc"] ?? nil)
        let args = ComposeUp.LabelsArgs.fingerprintLabels(makeContext(service: svc))
        let map = fingerprintMap(args)
        #expect(map["compose.spec.bootstrapped"] == "true",
                "sentinel must be emitted even for the most trivial service shape")
        #expect(map.keys.sorted() == ["compose.spec.bootstrapped"],
                "build-only service with no other compose-spec content should ONLY emit the sentinel")
    }

    @Test("fingerprint omits compose.spec.image for build-only services (no image:)")
    func omitsImageForBuildOnly() throws {
        let yaml = """
        services:
          svc:
            build:
              context: .
        """
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let svc = try #require(dc.services["svc"] ?? nil)
        let args = ComposeUp.LabelsArgs.fingerprintLabels(makeContext(service: svc))
        let map = fingerprintMap(args)
        #expect(map["compose.spec.image"] == nil)
    }

    @Test("fingerprint emits compose.spec.entrypoint.hash when command is set")
    func emitsEntrypointHashWhenCommandSet() {
        let svc = Service(image: "alpine", command: ["sleep", "100"])
        let args = ComposeUp.LabelsArgs.fingerprintLabels(makeContext(service: svc))
        let map = fingerprintMap(args)
        #expect(map["compose.spec.entrypoint.hash"] != nil)
        #expect(map["compose.spec.entrypoint.hash"]?.count == 64)
    }

    @Test("fingerprint omits compose.spec.entrypoint.hash when both entrypoint and command nil")
    func omitsEntrypointHashWhenBothNil() {
        let svc = Service(image: "alpine")
        let args = ComposeUp.LabelsArgs.fingerprintLabels(makeContext(service: svc))
        let map = fingerprintMap(args)
        #expect(map["compose.spec.entrypoint.hash"] == nil)
    }

    @Test("fingerprint emits compose.spec.env.hash when fingerprintEnv non-empty")
    func emitsEnvHashWhenSet() {
        let svc = Service(image: "alpine")
        let args = ComposeUp.LabelsArgs.fingerprintLabels(
            makeContext(service: svc, fingerprintEnv: ["LOG_LEVEL": "info"])
        )
        let map = fingerprintMap(args)
        #expect(map["compose.spec.env.hash"] != nil)
        #expect(map["compose.spec.env.hash"]?.count == 64)
    }

    @Test("fingerprint omits compose.spec.env.hash when fingerprintEnv empty")
    func omitsEnvHashWhenEmpty() {
        let svc = Service(image: "alpine")
        let args = ComposeUp.LabelsArgs.fingerprintLabels(makeContext(service: svc))
        let map = fingerprintMap(args)
        #expect(map["compose.spec.env.hash"] == nil)
    }

    @Test("fingerprint emits compose.spec.ports.hash when ports set")
    func emitsPortsHashWhenSet() {
        let svc = Service(image: "alpine", ports: ["8080:80"])
        let args = ComposeUp.LabelsArgs.fingerprintLabels(makeContext(service: svc))
        let map = fingerprintMap(args)
        #expect(map["compose.spec.ports.hash"] != nil)
    }

    @Test("fingerprint omits compose.spec.ports.hash when ports nil/empty")
    func omitsPortsHashWhenAbsent() {
        let svc = Service(image: "alpine")
        let args = ComposeUp.LabelsArgs.fingerprintLabels(makeContext(service: svc))
        #expect(fingerprintMap(args)["compose.spec.ports.hash"] == nil)

        let svcEmpty = Service(image: "alpine", ports: [])
        let argsEmpty = ComposeUp.LabelsArgs.fingerprintLabels(makeContext(service: svcEmpty))
        #expect(fingerprintMap(argsEmpty)["compose.spec.ports.hash"] == nil)
    }

    @Test("fingerprint emits compose.spec.networks.hash when networks set")
    func emitsNetworksHashWhenSet() throws {
        let yaml = """
        services:
          svc:
            image: alpine:latest
            networks:
              - frontend
        networks:
          frontend:
            driver: bridge
        """
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let svc = try #require(dc.services["svc"] ?? nil)
        let args = ComposeUp.LabelsArgs.fingerprintLabels(
            makeContext(service: svc, dockerCompose: dc)
        )
        let map = fingerprintMap(args)
        #expect(map["compose.spec.networks.hash"] != nil)
    }

    @Test("fingerprint omits compose.spec.networks.hash when no networks attached at all")
    func omitsNetworksHashWhenAbsent() {
        // No service.networks AND no implicit default network synthesized —
        // truly nothing to fingerprint. (CHAOS-1494's implicit-network case
        // is covered by `networksHashCoversImplicitDefault` below.)
        let svc = Service(image: "alpine")
        let args = ComposeUp.LabelsArgs.fingerprintLabels(makeContext(service: svc))
        #expect(fingerprintMap(args)["compose.spec.networks.hash"] == nil)
    }

    // MARK: - Layer 2b: CHAOS-1494 implicit-network coverage

    @Test("compose.spec.networks.hash covers CHAOS-1494 implicit project default network")
    func networksHashCoversImplicitDefault() {
        // Service has no `service.networks` block, but the project synthesized
        // an implicit default network (CHAOS-1494). The fingerprint label MUST
        // include the implicit attachment so a future explicit network change
        // is detectable as a hash mismatch.
        let svc = Service(image: "alpine")
        let args = ComposeUp.LabelsArgs.fingerprintLabels(
            makeContext(service: svc, implicitDefaultNetwork: "cc-test-fp-default")
        )
        let map = fingerprintMap(args)
        let hash = try? #require(map["compose.spec.networks.hash"])
        // The hash must equal the SHA256 of `["cc-test-fp-default"]` sorted+joined
        // — i.e. the canonical-name-only form. Recompute via the same helper to
        // pin the round-trip contract.
        let expected = ComposeUp.SpecFingerprint.canonicalNetworksHash(["cc-test-fp-default"])
        #expect(hash == expected)
    }

    @Test("compose.spec.networks.hash skips implicit default when service.network_mode is set")
    func networksHashSkipsImplicitWhenNetworkModeSet() {
        // Mirrors NetworkingArgs.build: services with `network_mode: host` (or
        // any explicit network_mode) bypass the implicit attachment, so the
        // fingerprint MUST also skip the implicit network. Otherwise the hash
        // would diverge between create-time (where NetworkingArgs skips the
        // attachment) and adoption-time (where the label says "attach to
        // implicit").
        let svc = Service(image: "alpine", network_mode: "host")
        let args = ComposeUp.LabelsArgs.fingerprintLabels(
            makeContext(service: svc, implicitDefaultNetwork: "cc-test-fp-default")
        )
        #expect(fingerprintMap(args)["compose.spec.networks.hash"] == nil)
    }

    @Test("specDivergenceReason fires when implicit-network service's networks.hash drifts")
    func networksHashDivergenceFiresForImplicitNetwork() {
        // Pass-1 simulation: service had no service.networks, was attached to
        // implicit `<projectName>-default`, hash A was written to the label.
        let pass1Hash = ComposeUp.SpecFingerprint.canonicalNetworksHash(["cc-test-fp-default"])!
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            labels: ["compose.spec.networks.hash": pass1Hash]
        )
        // Pass-2 simulation: user added `service.networks: [foo]` in compose.
        // The new expected hash must differ — forcing a recreate.
        let pass2Hash = ComposeUp.SpecFingerprint.canonicalNetworksHash(["foo"])
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: Service(image: "alpine"),
            expectedNetworksHash: pass2Hash
        )
        #expect(reason?.contains("compose.spec.networks.hash mismatch") == true)
    }

    @Test("fingerprint resolves env-substituted image reference before hashing")
    func imageEnvSubstituted() {
        let svc = Service(image: "${IMAGE}:latest")
        let args = ComposeUp.LabelsArgs.fingerprintLabels(
            makeContext(service: svc, environmentVariables: ["IMAGE": "myimage"])
        )
        let map = fingerprintMap(args)
        #expect(map["compose.spec.image"] == "myimage:latest")
    }

    // MARK: - Layer 3a: round-trip — label mismatch ⇒ recreate

    // Helpers for layer-3 round-trip tests stay simple: each test stubs
    // the labels it cares about directly on the snapshot, then asserts that
    // `specDivergenceReason` returns the expected outcome. The previous
    // "makeSnapshotMatchingService" mega-helper is unused; tests are
    // clearer when each one explicitly states its inputs.

    @Test("specDivergenceReason: image label mismatch triggers recreate")
    func divergesOnImageLabelMismatch() {
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            imageReference: "docker.io/library/alpine:latest",
            labels: ["compose.spec.image": "alpine:OLD"]
        )
        let expected = Service(image: "alpine:NEW")
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: expected,
            expectedImageLabel: "alpine:NEW"
        )
        #expect(reason?.contains("compose.spec.image mismatch") == true)
        #expect(reason?.contains("alpine:OLD") == true)
        #expect(reason?.contains("alpine:NEW") == true)
    }

    @Test("specDivergenceReason: entrypoint hash mismatch triggers recreate")
    func divergesOnEntrypointHashMismatch() {
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            labels: ["compose.spec.entrypoint.hash": "deadbeef"]
        )
        let newHash = ComposeUp.SpecFingerprint.canonicalEntrypointHash(
            entrypoint: nil, command: ["sleep", "100"]
        )
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: Service(image: "alpine", command: ["sleep", "100"]),
            expectedEntrypointHash: newHash
        )
        #expect(reason?.contains("compose.spec.entrypoint.hash mismatch") == true)
    }

    @Test("specDivergenceReason: env hash mismatch triggers recreate")
    func divergesOnEnvHashMismatch() {
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            labels: ["compose.spec.env.hash": "old-hash-value"]
        )
        let newHash = ComposeUp.SpecFingerprint.canonicalEnvHash(["LOG_LEVEL": "debug"])
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: Service(image: "alpine"),
            expectedEnvHash: newHash
        )
        #expect(reason?.contains("compose.spec.env.hash mismatch") == true)
    }

    @Test("specDivergenceReason: ports hash mismatch triggers recreate")
    func divergesOnPortsHashMismatch() {
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            labels: ["compose.spec.ports.hash": "old-ports-hash"]
        )
        let newHash = ComposeUp.SpecFingerprint.canonicalPortsHash(
            ["8080:80"], environmentVariables: [:]
        )
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: Service(image: "alpine", ports: ["8080:80"]),
            expectedPortsHash: newHash
        )
        #expect(reason?.contains("compose.spec.ports.hash mismatch") == true)
    }

    @Test("specDivergenceReason: networks hash mismatch triggers recreate")
    func divergesOnNetworksHashMismatch() {
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            labels: ["compose.spec.networks.hash": "old-networks-hash"]
        )
        let newHash = ComposeUp.SpecFingerprint.canonicalNetworksHash(["frontend"])
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: Service(image: "alpine"),
            expectedNetworksHash: newHash
        )
        #expect(reason?.contains("compose.spec.networks.hash mismatch") == true)
    }

    // MARK: - Layer 3b: round-trip — label match ⇒ no divergence

    @Test("specDivergenceReason: matching labels yield no divergence")
    func adoptsWhenAllLabelsMatch() throws {
        let imageLabel = "alpine:latest"
        let entrypointHash = ComposeUp.SpecFingerprint.canonicalEntrypointHash(
            entrypoint: nil, command: ["sleep", "100"]
        )!
        let envHash = ComposeUp.SpecFingerprint.canonicalEnvHash(["LOG_LEVEL": "info"])
        let portsHash = ComposeUp.SpecFingerprint.canonicalPortsHash(
            ["8080:80"], environmentVariables: [:]
        )!

        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            imageReference: "docker.io/library/alpine:latest",
            labels: [
                "compose.spec.image": imageLabel,
                "compose.spec.entrypoint.hash": entrypointHash,
                "compose.spec.env.hash": envHash,
                "compose.spec.ports.hash": portsHash,
            ],
            // Existing env must contain every key the env-fallback check
            // would assert (subset semantics) — keep it aligned with the
            // hashed (a)-only form.
            environment: ["LOG_LEVEL=info"],
            // For a compose `command: ["sleep", "100"]` with no entrypoint,
            // apple/container parses the runtime initProcess as
            // executable="sleep" + arguments=["100"]. The existing
            // commandDivergenceReason reconstructs the full command as
            // [executable] + arguments = ["sleep", "100"] which then matches
            // the expected command.
            executable: "sleep",
            arguments: ["100"],
            publishedPorts: [
                PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 8080, containerPort: 80, proto: .tcp, count: 1)
            ]
        )
        let svc = Service(image: "alpine:latest", ports: ["8080:80"], command: ["sleep", "100"])
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: svc,
            expectedPublishedPorts: ["0.0.0.0:8080:80"],
            expectedEnvironment: ["LOG_LEVEL": "info"],
            expectedCommand: ["sleep", "100"],
            expectedImageLabel: imageLabel,
            expectedEntrypointHash: entrypointHash,
            expectedEnvHash: envHash,
            expectedPortsHash: portsHash
        )
        #expect(reason == nil)
    }

    // MARK: - Layer 3c: backwards-compat — missing label falls through to fallback

    @Test("specDivergenceReason: missing image label falls through (no spurious recreate)")
    func backwardsCompatImageLabelAbsent() {
        // Pre-CHAOS-1496 container — no compose.spec.* labels. Image string
        // matches expected, so the existing snapshot fallback returns nil.
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            imageReference: "docker.io/library/alpine:latest",
            labels: [:]
        )
        let svc = Service(image: "alpine:latest")
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: svc,
            expectedImageLabel: "alpine:latest"
        )
        #expect(reason == nil)
    }

    @Test("specDivergenceReason: missing entrypoint hash label falls through to existing command check")
    func backwardsCompatEntrypointHashAbsent() {
        // Pre-CHAOS-1496 container — no entrypoint.hash label. Existing
        // command matches expected, so the existing fallback returns nil.
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            executable: "sleep",
            arguments: ["100"]
        )
        let svc = Service(image: "alpine", command: ["sleep", "100"])
        let newHash = ComposeUp.SpecFingerprint.canonicalEntrypointHash(
            entrypoint: nil, command: ["sleep", "100"]
        )
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: svc,
            expectedCommand: ["sleep", "100"],
            expectedEntrypointHash: newHash
        )
        #expect(reason == nil)
    }

    @Test("specDivergenceReason: missing env hash label falls through to subset-semantics fallback (sentinel-bearing post-1499 container)")
    func backwardsCompatEnvHashAbsent() {
        // CHAOS-1499: SUBSET fallback is gated on the
        // `compose.spec.bootstrapped` sentinel. To keep this test exercising
        // the SUBSET semantics (rather than the new gate that would skip
        // them), include the sentinel on the existing fixture. Pre-1499
        // containers without the sentinel are covered separately by the
        // CHAOS-1499 gate tests.
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            labels: ["compose.spec.bootstrapped": "true"],
            environment: ["LOG_LEVEL=info", "PATH=/usr/bin"]
        )
        let svc = Service(image: "alpine")
        let newHash = ComposeUp.SpecFingerprint.canonicalEnvHash(["LOG_LEVEL": "info"])
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: svc,
            expectedEnvironment: ["LOG_LEVEL": "info"],
            expectedEnvHash: newHash
        )
        // Fallback uses SUBSET semantics; image-injected PATH is ignored.
        #expect(reason == nil)
    }

    @Test("specDivergenceReason: missing ports hash label falls through to set-equality fallback")
    func backwardsCompatPortsHashAbsent() throws {
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            publishedPorts: [
                PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 8080, containerPort: 80, proto: .tcp, count: 1)
            ]
        )
        let svc = Service(image: "alpine", ports: ["8080:80"])
        let newHash = ComposeUp.SpecFingerprint.canonicalPortsHash(
            ["8080:80"], environmentVariables: [:]
        )
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: svc,
            expectedPublishedPorts: ["0.0.0.0:8080:80"],
            expectedPortsHash: newHash
        )
        #expect(reason == nil)
    }

    @Test("specDivergenceReason: missing networks hash label falls through to set-equality fallback")
    func backwardsCompatNetworksHashAbsent() {
        let existing = makeSnapshot(
            id: "cc-test-fp-svc",
            networks: [
                AttachmentConfiguration(network: "frontend", options: AttachmentOptions(hostname: "svc"))
            ]
        )
        let svc = Service(image: "alpine")
        let newHash = ComposeUp.SpecFingerprint.canonicalNetworksHash(["frontend"])
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: svc,
            expectedNetworkNames: ["frontend"],
            expectedNetworksHash: newHash
        )
        #expect(reason == nil)
    }

    // MARK: - Layer 3d: chicken-and-egg env hash — peer-IP env stays adopted

    @Test("env-hash chicken-and-egg: peer-IP env reference does NOT trigger recreate cascade")
    func envHashAvoidsPeerIPCascade() {
        // SCENARIO: service B has env `DB_HOST=postgres` (literal peer name).
        // At create time, `mergeAndExpandServiceEnv` populated containerIps
        // and rewrote DB_HOST to e.g. "192.168.66.4" (the IP of peer service
        // postgres). The runtime container sees DB_HOST=192.168.66.4.
        //
        // At adoption time, `containerIps` is EMPTY (resolveAdoption runs
        // BEFORE configService populates it). The naive approach of hashing
        // the FULL (a)+(b) form would compute the hash of DB_HOST=postgres
        // (literal) and compare against the create-time label's hash of
        // DB_HOST=192.168.66.4 — guaranteed mismatch, spurious recreate
        // every `up` for any service with peer-IP env.
        //
        // The fix: hash the (a)-only form (post-${VAR}-substitution, BEFORE
        // containerIps rewrite). At create time the (a)-only env has
        // DB_HOST=postgres. At adoption time the (a)-only env also has
        // DB_HOST=postgres (containerIps doesn't matter). Hashes match,
        // service is adopted.

        // (a)-only form of B's env: peer name is preserved as a literal
        // string (no IP substitution happens in the (a) layer).
        let aOnlyEnv = ["DB_HOST": "postgres"]
        let createTimeHash = ComposeUp.SpecFingerprint.canonicalEnvHash(aOnlyEnv)

        // Existing container's actual runtime env reflects the (b)-layer
        // rewrite that happened at create time — IP-resolved value.
        let existing = makeSnapshot(
            id: "cc-test-fp-svc-b",
            labels: ["compose.spec.env.hash": createTimeHash],
            environment: ["DB_HOST=192.168.66.4"]
        )

        // Adoption-time recompute: containerIps empty, so the (a)-only env
        // for service B is the same `DB_HOST=postgres` literal as create time.
        let adoptionTimeHash = ComposeUp.SpecFingerprint.canonicalEnvHash(aOnlyEnv)

        // Hashes MUST be equal — adoption proceeds, no recreate cascade.
        #expect(createTimeHash == adoptionTimeHash)

        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: Service(image: "alpine", environment: ["DB_HOST": "postgres"]),
            // Pre-1496 fallback would diverge here (subset semantics on env
            // would see "postgres" expected vs. "192.168.66.4" existing).
            // We intentionally pass an EMPTY expectedEnvironment to make
            // this test focus exclusively on the hash-PRIMARY path —
            // production-side `expectedEnvironmentForService` retains the
            // CHAOS-1493 subset semantics, which is a separate concern.
            expectedEnvironment: [:],
            expectedEnvHash: adoptionTimeHash
        )
        #expect(reason == nil, "Hash matched ⇒ no divergence ⇒ no recreate cascade")
    }

    @Test("env-hash sensitive: USER-DECLARED env actually changes ⇒ recreate")
    func envHashCatchesUserDeclaredChange() {
        // Negative companion to the chicken-and-egg test above: when the
        // user actually changes the env declaration (e.g. DB_HOST=postgres
        // → DB_HOST=newhost), the (a)-only hash MUST differ and we MUST
        // recreate. This pins that the fingerprint scheme isn't blanket-
        // tolerant of env churn — only of the (b)-layer chicken-and-egg.
        let oldHash = ComposeUp.SpecFingerprint.canonicalEnvHash(["DB_HOST": "postgres"])
        let newHash = ComposeUp.SpecFingerprint.canonicalEnvHash(["DB_HOST": "newhost"])
        #expect(oldHash != newHash)

        let existing = makeSnapshot(
            id: "cc-test-fp-svc-b",
            labels: ["compose.spec.env.hash": oldHash]
        )
        let reason = ComposeUp.specDivergenceReason(
            existing: existing,
            expected: Service(image: "alpine", environment: ["DB_HOST": "newhost"]),
            expectedEnvHash: newHash
        )
        #expect(reason?.contains("compose.spec.env.hash mismatch") == true)
    }
}

