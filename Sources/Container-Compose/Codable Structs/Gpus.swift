//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
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

/// A single GPU reservation request in the array form of `gpus`.
public struct GpuRequest: Codable, Hashable {
    /// GPU driver (e.g., "nvidia")
    public let driver: String?
    /// Number of GPUs to reserve
    public let count: Int?
    /// Specific device IDs to reserve
    public let device_ids: [String]?
    /// Required capabilities (e.g., ["compute", "utility"])
    public let capabilities: [String]?
    /// Driver-specific options (e.g., ["memory": "8G"])
    public let options: [String: String]?

    public init(
        driver: String? = nil,
        count: Int? = nil,
        device_ids: [String]? = nil,
        capabilities: [String]? = nil,
        options: [String: String]? = nil
    ) {
        self.driver = driver
        self.count = count
        self.device_ids = device_ids
        self.capabilities = capabilities
        self.options = options
    }
}

/// Represents the `gpus` field in a service definition.
///
/// Supports the shorthand `"all"` string form and the array-of-requests form.
public enum Gpus: Codable, Hashable {
    /// Shorthand: all GPUs available on the host
    case all
    /// Explicit list of GPU reservation requests
    case requests([GpuRequest])

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let s = try? single.decode(String.self), s == "all" {
            self = .all
            return
        }
        if let arr = try? single.decode([GpuRequest].self) {
            self = .requests(arr)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: single,
            debugDescription: "Expected \"all\" or array of GpuRequest"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .all:
            try c.encode("all")
        case .requests(let requests):
            try c.encode(requests)
        }
    }
}
