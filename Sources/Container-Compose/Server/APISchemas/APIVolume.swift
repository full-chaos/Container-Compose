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

// MARK: GET /volumes  (CHAOS-1353)

public struct APIVolumeSummary: Codable, Sendable, Hashable {
    public let name: String
    public let driver: String
    public let labels: [String: String]
    public let createdAt: Date?

    public init(
        name: String,
        driver: String,
        labels: [String: String],
        createdAt: Date?
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
        self.createdAt = createdAt
    }
}

/// Envelope for `GET /volumes` to allow future addition of `warnings` /
/// `filters` fields without breaking the response shape.
public struct APIVolumeListResponse: Codable, Sendable, Hashable {
    public let volumes: [APIVolumeSummary]

    public init(volumes: [APIVolumeSummary]) {
        self.volumes = volumes
    }
}

// MARK: POST /volumes

public struct APICreateVolumeRequest: Codable, Sendable, Hashable {
    public let name: String
    public let driver: String?
    public let labels: [String: String]?

    public init(
        name: String,
        driver: String? = nil,
        labels: [String: String]? = nil
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
    }
}
