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

import Foundation

// MARK: - RuntimeVolume (CHAOS-1353)

/// Runtime-side volume representation for `Runtime.listVolumes()` /
/// `createVolume()` / `removeVolume(name:)`. Volume names are the canonical
/// key; no UUIDs are used (mirrors the Compose-spec where a volume is
/// identified by its name under `volumes:`). The `driver` field is `local` for
/// all volumes in Phase 8; other drivers are out of scope per the CHAOS-1353
/// ticket boundary.
public struct RuntimeVolume: Sendable, Hashable, Codable {
    public let name: String
    public let driver: String
    public let labels: [String: String]
    public let createdAt: Date?

    public init(
        name: String,
        driver: String = "local",
        labels: [String: String] = [:],
        createdAt: Date? = nil
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
        self.createdAt = createdAt
    }
}

/// Spec used to create a new volume via `Runtime.createVolume(spec:)`.
public struct RuntimeCreateVolumeSpec: Sendable, Equatable {
    public let name: String
    public let driver: String
    public let labels: [String: String]
    public let driverOptions: [String: String]

    public init(
        name: String,
        driver: String = "local",
        labels: [String: String] = [:],
        driverOptions: [String: String] = [:]
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
        self.driverOptions = driverOptions
    }
}
