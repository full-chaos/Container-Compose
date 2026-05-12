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
import Foundation
import Rainbow

public actor LoopState {
    private(set) var containerConsoleColors: [String: NamedColor] = [:]
    private var didWarnServiceModelsUnsupported = false
    private var didWarnServiceProviderUnsupported = false
    private(set) var containerIps: [String: String] = [:]
    private(set) var preparedNamedVolumes: Set<String> = []
    private(set) var existingNamedVolumeRegistryCache: [String: RuntimeVolume] = [:]
    private var existingNamedVolumeRegistryCacheLoaded: Bool = false
    private var serviceLaunchFailures: [String: String] = [:]

    /// Project-level environment baseline (.env file + any process-derived
    /// overlays loaded at the top of `ComposeUp.run()`). Lives on the actor
    /// so the parallel service-start TaskGroup cannot race on
    /// `updateEnvironmentForServiceIP`'s peer-name → IP rewrites.
    /// CHAOS-1446 Phase 4B; mirrors the `containerIps` field's invariants.
    private(set) var environmentVariables: [String: String] = [:]

    func assignColor(for serviceName: String, available: Set<NamedColor>) -> NamedColor {
        let used = Set(containerConsoleColors.values)
        let unused = available.subtracting(used)
        let serviceColor = (unused.randomElement() ?? available.randomElement())!

        containerConsoleColors[serviceName] = serviceColor
        return serviceColor
    }

    func recordLaunchFailure(for serviceName: String, message: String) {
        serviceLaunchFailures[serviceName] = message
    }

    func launchFailure(for serviceName: String) -> String? {
        serviceLaunchFailures[serviceName]
    }

    func warnModelsOnce() -> Bool {
        if didWarnServiceModelsUnsupported { return false }
        didWarnServiceModelsUnsupported = true
        return true
    }

    func warnProviderOnce() -> Bool {
        if didWarnServiceProviderUnsupported { return false }
        didWarnServiceProviderUnsupported = true
        return true
    }

    func setIP(serviceName: String, ip: String?) {
        containerIps[serviceName] = ip
    }

    func ip(for serviceName: String) -> String? {
        containerIps[serviceName]
    }

    func tryInsertPreparedKey(_ key: String) -> Bool {
        preparedNamedVolumes.insert(key).inserted
    }

    func cachedRuntimeVolume(name: String) -> RuntimeVolume? {
        existingNamedVolumeRegistryCache[name]
    }

    func cacheRuntimeVolume(name: String, volume: RuntimeVolume) {
        existingNamedVolumeRegistryCache[name] = volume
    }

    func loadCacheOnce(loader: @Sendable () async throws -> [String: RuntimeVolume]) async throws {
        if existingNamedVolumeRegistryCacheLoaded { return }
        let result = try await loader()
        existingNamedVolumeRegistryCache = result
        existingNamedVolumeRegistryCacheLoaded = true
    }

    // MARK: - environmentVariables (CHAOS-1446 Phase 4B)

    /// Replace the project-level environment baseline. Called once near the
    /// top of `ComposeUp.run()` after `loadEnvFile(...)` returns.
    func setEnvironment(_ env: [String: String]) {
        environmentVariables = env
    }

    /// Returns a value snapshot of the current project-level environment.
    /// Callers that read `environmentVariables` repeatedly inside a single
    /// per-service code path SHOULD capture-once with this snapshot and
    /// thread the local copy down — the actor's read+rewrite race window
    /// is closed only when each reader uses a stable snapshot.
    func snapshotEnvironment() -> [String: String] {
        environmentVariables
    }

    /// CHAOS-1446 Phase 4B: rewrite every entry whose VALUE equals
    /// `serviceName` to point at the resolved IP (or leave unchanged when
    /// IP resolution failed). Mirrors the inline mutation that
    /// `ComposeUp.updateEnvironmentWithServiceIP` performed pre-Phase 4B,
    /// but routed through the actor so concurrent service-start tasks can
    /// no longer race on the dictionary.
    ///
    /// `ip == nil` is the error-tolerant path: we leave the placeholder
    /// VALUE alone so the env var still resolves to a string (the service
    /// name itself) — same observable behaviour as the pre-1446 inline
    /// `self.environmentVariables[key] = ip ?? value`.
    func updateEnvironmentForServiceIP(serviceName: String, ip: String?) {
        for (key, value) in environmentVariables where value == serviceName {
            environmentVariables[key] = ip ?? value
        }
    }
}
