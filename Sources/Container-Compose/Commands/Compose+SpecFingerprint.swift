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

import CryptoKit
import Foundation

extension ComposeUp {
    /// CHAOS-1496: canonical fingerprint hashes used to populate the
    /// `compose.spec.*.hash` durable label channel emitted by `LabelsArgs.build`
    /// at create time and read back by `specDivergenceReason` on subsequent
    /// `up` invocations.
    ///
    /// Generalizes the CHAOS-1493 `compose.dns.resolvers.<network>=<ip>` label
    /// pattern: instead of reconstructing expected values from snapshot fields
    /// at adoption time and applying dimension-specific equality semantics
    /// (set membership, env subset, command shape reconstruction), the
    /// fingerprint scheme reduces every drift check to a single string
    /// equality comparison on a label.
    ///
    /// All canonical forms below are designed to be stable across Swift
    /// runtime ordering quirks (Set/Dictionary iteration is non-deterministic):
    /// the helpers explicitly sort their inputs before hashing so the hash
    /// written at create time will compare equal to the hash recomputed at
    /// adoption time when the underlying compose-spec content is unchanged.
    ///
    /// Intentionally read-only / pure: every helper is a `static func` that
    /// takes its input by value and returns either a hash string (or nil
    /// when the corresponding field has no content to fingerprint, mirroring
    /// the "skip when not applicable" emission rule in `LabelsArgs.build`).
    enum SpecFingerprint {
        /// Lowercase hex SHA256 of the UTF-8 bytes of `input`. Mirrors the
        /// digest format used by `Compose+ConfigsAndSecrets.writeTempFile`
        /// (configs/secrets path-hash prefix) so all label-emitted SHA256
        /// hashes share a single human-readable convention.
        static func sha256Hex(_ input: String) -> String {
            let digest = SHA256.hash(data: Data(input.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        /// Canonical hash of the launch command shape: `(entrypoint ?? []) +
        /// (command ?? [])` joined with the ASCII unit separator `\u{1F}`.
        ///
        /// `\u{1F}` is used (rather than space or newline) to preserve element
        /// boundaries unambiguously: a list `["a b", "c"]` hashes differently
        /// from `["a", "b c"]` even though both join to "a b\nc" or "a b c"
        /// under simpler separators. The unit separator is rejected from
        /// shell-quoted strings in practice, so collisions are negligible.
        ///
        /// Returns nil when both `entrypoint` and `command` are nil — in that
        /// case the service is launched with the image's default CMD/ENTRYPOINT
        /// and there is no compose-spec content to fingerprint. Callers
        /// (`LabelsArgs.build`) skip the label emission in this case so the
        /// resulting argv stays minimal for trivial services.
        static func canonicalEntrypointHash(entrypoint: [String]?, command: [String]?) -> String? {
            if entrypoint == nil && command == nil { return nil }
            let parts = (entrypoint ?? []) + (command ?? [])
            return sha256Hex(parts.joined(separator: "\u{1F}"))
        }

        /// Canonical hash of the merged environment: each entry rendered as
        /// `KEY=VALUE\n`, sorted by KEY (NOT by line), then concatenated.
        ///
        /// The trailing `\n` on every line means the empty-input hash is the
        /// hash of the empty string (`SHA256("")`). Callers in `LabelsArgs.build`
        /// skip emitting the label when `mergedEnv` is empty so the
        /// resulting argv shape stays clean for services with no env.
        ///
        /// Caller-side note: `mergedEnv` MUST be the output of
        /// `ComposeUp.mergeServiceEnvForFingerprint(_:)` — the (a)-only form
        /// that folds in project-level baseline env, env_file, and
        /// `service.environment` with `${VAR}` substitution but DOES NOT apply
        /// the (b)-layer `containerIps[value] ?? value` rewrite. `containerIps`
        /// is empty at `resolveAdoption` time (populated only by the
        /// per-service `configService` loop that runs AFTER adoption), so
        /// hashing the (a+b) form would spurious-diverge every service whose
        /// env references a peer service by name. The exact-string hash
        /// semantics of the corresponding `envHashDivergence` check rely on
        /// the create-time merge order matching the adoption-time merge order
        /// byte-for-byte. The SUBSET-semantics `envDivergenceReason` remains
        /// as snapshot fallback for pre-CHAOS-1496 containers, gated behind
        /// the CHAOS-1499 `compose.spec.bootstrapped` sentinel so it no
        /// longer fires spuriously on pre-1499 containers with peer-IP env
        /// values baked at create-time on a prior `up`.
        static func canonicalEnvHash(_ env: [String: String]) -> String {
            let lines = env
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)\n" }
                .joined()
            return sha256Hex(lines)
        }

        /// Canonical hash of `service.ports`. Each entry is run through
        /// `resolveVariable` then `composePortToRunArg` to land on the same
        /// canonical wire format `container run -p` accepts; the resulting
        /// strings are sorted, joined with `\n`, and hashed.
        ///
        /// `composePortToRunArg` is the exact same canonicalization
        /// `expectedPublishedPortsForService` and `canonicalPortSpec` use
        /// elsewhere in the divergence chain, so a hash match implies the
        /// existing snapshot-based `portsDivergenceReason` would also pass.
        ///
        /// Returns nil when `ports` is nil or empty — services without
        /// published ports have nothing to fingerprint and `LabelsArgs.build`
        /// skips the label emission.
        static func canonicalPortsHash(
            _ ports: [String]?,
            environmentVariables: [String: String]
        ) -> String? {
            guard let ports, !ports.isEmpty else { return nil }
            let canonical = ports.map { composePortToRunArg(resolveVariable($0, with: environmentVariables)) }
            return sha256Hex(canonical.sorted().joined(separator: "\n"))
        }

        /// Canonical hash of the SET of resolved network names this service
        /// is attached to. `resolvedNames` MUST already be canonicalized by
        /// the caller (env-substitution + top-level `name:` override applied)
        /// so this helper stays decoupled from `DockerCompose` /
        /// `environmentVariables` plumbing.
        ///
        /// CHAOS-1495 will introduce a `resolveCanonicalNetworkName` helper
        /// in `Helper Functions.swift`; until that lands, callers reproduce
        /// the existing inline formula at the call site:
        ///   `dockerCompose.networks?[name]??.name ?? resolveVariable(name, with: environmentVariables)`.
        /// Mechanical refactor planned post-1495 merge.
        ///
        /// Returns nil when `resolvedNames` is empty — services with no
        /// network attachments have nothing to fingerprint and
        /// `LabelsArgs.build` skips the label emission.
        static func canonicalNetworksHash(_ resolvedNames: [String]) -> String? {
            guard !resolvedNames.isEmpty else { return nil }
            return sha256Hex(resolvedNames.sorted().joined(separator: "\n"))
        }
    }
}
