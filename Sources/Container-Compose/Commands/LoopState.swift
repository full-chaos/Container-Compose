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

    func assignColor(for serviceName: String, available: Set<NamedColor>) -> NamedColor {
        var serviceColor: NamedColor = available.randomElement()!

        if Array(Set(containerConsoleColors.values)).sorted(by: { $0.rawValue < $1.rawValue }) != available.sorted(by: { $0.rawValue < $1.rawValue }) {
            while containerConsoleColors.values.contains(serviceColor) {
                serviceColor = available.randomElement()!
            }
        }

        containerConsoleColors[serviceName] = serviceColor
        return serviceColor
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
}
