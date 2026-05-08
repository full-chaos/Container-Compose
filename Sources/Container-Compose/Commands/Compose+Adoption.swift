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
        _ services: [(serviceName: String, service: Service)]
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

            if let reason = Self.specDivergenceReason(existing: existing, expected: service) {
                decisions[serviceName] = .recreate(reason: reason)
                continue
            }

            decisions[serviceName] = .adopt
            print("Adopting existing container: \(containerName)")
        }

        return decisions
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

    /// CHAOS-1492 v1 divergence detection: image only.
    ///
    /// Returns a non-nil reason string when the existing container's image
    /// reference differs from the qualified form of `service.image`.
    /// Build-only services (no `image:` field) skip this check — their
    /// effective image reference comes from the build pipeline, not the
    /// compose file, and tracking that drift lives outside this PR.
    ///
    /// TODO(CHAOS-1492 follow-up): extend to env, ports, command, and
    /// network attachments. v1 sticks to image because it's the highest-
    /// signal drift indicator and trivially comparable; richer comparisons
    /// require structural-diff helpers we don't have yet.
    internal static func specDivergenceReason(
        existing: ContainerSnapshot,
        expected: Service
    ) -> String? {
        let existingImage = existing.configuration.image.reference
        guard let expectedRaw = expected.image else { return nil }
        let expectedQualified = qualifyImageReference(expectedRaw)
        if existingImage != expectedQualified {
            return "image changed: \(existingImage) -> \(expectedQualified)"
        }
        return nil
    }
}
