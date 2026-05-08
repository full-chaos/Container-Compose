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

enum RuntimeVolumeClient {
    static func list() async throws -> [RuntimeVolume] {
        let volumes: [ContainerResource.Volume] = try await ClientVolume.list()
        return volumes.map { translate($0) }
    }

    static func create(spec: RuntimeCreateVolumeSpec) async throws -> RuntimeVolume {
        guard spec.driver == "local" else {
            throw RuntimeError.notSupported(operation: "createVolume(driver=\(spec.driver))", conformer: "RuntimeVolumeClient")
        }

        do {
            let volume: ContainerResource.Volume = try await ClientVolume.create(
                name: spec.name,
                driver: spec.driver,
                driverOpts: spec.driverOptions,
                labels: spec.labels
            )
            return translate(volume)
        } catch {
            throw RuntimeErrorMapper.map(error, id: spec.name)
        }
    }

    static func remove(name: String) async throws {
        do {
            try await ClientVolume.delete(name: name)
        } catch {
            throw RuntimeErrorMapper.map(error, id: name)
        }
    }

    static func inspect(name: String) async throws -> ContainerResource.Volume {
        do {
            return try await ClientVolume.inspect(name)
        } catch {
            throw RuntimeErrorMapper.map(error, id: name)
        }
    }

    static func inspectRuntime(name: String) async throws -> RuntimeVolume {
        translate(try await inspect(name: name))
    }

    private static func translate(_ volume: ContainerResource.Volume) -> RuntimeVolume {
        RuntimeVolume(
            name: volume.name,
            driver: volume.driver,
            labels: volume.labels,
            createdAt: volume.createdAt
        )
    }
}
