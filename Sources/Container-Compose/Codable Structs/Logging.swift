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

import Foundation

/// Represents the logging configuration for a service.
///
/// YAML example:
///   logging:
///     driver: json-file
///     options:
///       max-size: "10m"
///       max-file: "3"
public struct Logging: Codable, Hashable {
    /// The logging driver to use (e.g., "json-file", "syslog", "none")
    public let driver: String?

    /// Driver-specific options
    public let options: [String: String]?

    public init(driver: String? = nil, options: [String: String]? = nil) {
        self.driver = driver
        self.options = options
    }
}
