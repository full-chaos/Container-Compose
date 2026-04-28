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

//
//  Healthcheck.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Healthcheck configuration for a service.
public struct Healthcheck: Codable, Hashable {
    /// Command to run to check health
    public let test: [String]?
    /// Grace period for the container to start
    public let start_period: String?
    /// How often to run the check
    public let interval: String?
    /// Number of consecutive failures to consider unhealthy
    public let retries: Int?
    /// Timeout for each check
    public let timeout: String?
    /// Interval used during `start_period` (Docker 24+, compose-spec `start_interval`).
    /// Parse-only: enforcement is gated on Apple `container` runtime support
    /// (currently absent — see AGENTS.md §6 #1).
    public let start_interval: String?
    /// Skip the inherited image healthcheck entirely (compose-spec `disable`).
    /// Parse-only: enforcement is gated on Apple `container` runtime support
    /// (currently absent — see AGENTS.md §6 #1).
    public let disable: Bool?

    public init(
        test: [String]? = nil,
        start_period: String? = nil,
        interval: String? = nil,
        retries: Int? = nil,
        timeout: String? = nil,
        start_interval: String? = nil,
        disable: Bool? = nil
    ) {
        self.test = test
        self.start_period = start_period
        self.interval = interval
        self.retries = retries
        self.timeout = timeout
        self.start_interval = start_interval
        self.disable = disable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle if `test` is a single string instead of an array
        if let test = try? container.decodeIfPresent([String].self, forKey: .test) {
            self.test = test
        } else if let testString = try? container.decodeIfPresent(String.self, forKey: .test) {
            self.test = ["CMD-SHELL", testString]
        } else {
            self.test = nil
        }

        self.start_period = try container.decodeIfPresent(String.self, forKey: .start_period)
        self.interval = try container.decodeIfPresent(String.self, forKey: .interval)
        self.retries = try container.decodeIfPresent(Int.self, forKey: .retries)
        self.timeout = try container.decodeIfPresent(String.self, forKey: .timeout)
        self.start_interval = try container.decodeIfPresent(String.self, forKey: .start_interval)
        self.disable = try container.decodeIfPresent(Bool.self, forKey: .disable)
    }
}
