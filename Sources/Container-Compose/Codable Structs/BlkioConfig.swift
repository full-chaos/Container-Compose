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

/// A per-device I/O weight entry.
public struct BlkioWeightDevice: Codable, Hashable {
    /// Device path (e.g., "/dev/sda")
    public let path: String
    /// Relative I/O weight for the device
    public let weight: Int

    public init(path: String, weight: Int) {
        self.path = path
        self.weight = weight
    }
}

/// A per-device bandwidth rate entry (bytes per second).
public struct BlkioRateDevice: Codable, Hashable {
    /// Device path (e.g., "/dev/sda")
    public let path: String
    /// Rate string (e.g., "12mb")
    public let rate: String

    public init(path: String, rate: String) {
        self.path = path
        self.rate = rate
    }
}

/// A per-device IOPS (I/O operations per second) entry.
public struct BlkioIopsDevice: Codable, Hashable {
    /// Device path (e.g., "/dev/sda")
    public let path: String
    /// IOPS limit
    public let rate: Int

    public init(path: String, rate: Int) {
        self.path = path
        self.rate = rate
    }
}

/// Block I/O configuration for a service.
public struct BlkioConfig: Codable, Hashable {
    /// Default relative I/O weight (10–1000)
    public let weight: Int?
    /// Per-device I/O weights
    public let weight_device: [BlkioWeightDevice]?
    /// Per-device read bandwidth limits
    public let device_read_bps: [BlkioRateDevice]?
    /// Per-device write bandwidth limits
    public let device_write_bps: [BlkioRateDevice]?
    /// Per-device read IOPS limits
    public let device_read_iops: [BlkioIopsDevice]?
    /// Per-device write IOPS limits
    public let device_write_iops: [BlkioIopsDevice]?

    public init(
        weight: Int? = nil,
        weight_device: [BlkioWeightDevice]? = nil,
        device_read_bps: [BlkioRateDevice]? = nil,
        device_write_bps: [BlkioRateDevice]? = nil,
        device_read_iops: [BlkioIopsDevice]? = nil,
        device_write_iops: [BlkioIopsDevice]? = nil
    ) {
        self.weight = weight
        self.weight_device = weight_device
        self.device_read_bps = device_read_bps
        self.device_write_bps = device_write_bps
        self.device_read_iops = device_read_iops
        self.device_write_iops = device_write_iops
    }
}
