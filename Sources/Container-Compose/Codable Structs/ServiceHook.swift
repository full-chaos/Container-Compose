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
//  ServiceHook.swift
//  Container-Compose
//
//  Created for CHAOS-1303 — decode parity for post_start / pre_stop hooks.
//

import Foundation

/// Represents a single lifecycle hook entry for `post_start` or `pre_stop`.
///
/// Compose spec shape (compose-spec.json):
/// ```
/// {
///   "command": string | [string],
///   "user": string?,
///   "privileged": bool?,
///   "working_dir": string?,
///   "environment": { string: string }?
/// }
/// ```
/// Decode-only — Apple `container` does not support lifecycle hooks.
public struct ServiceHook: Codable, Hashable {
    /// Command to run (accepts single string or array of strings).
    public let command: [String]?

    /// User to run the hook as.
    public let user: String?

    /// Whether the hook should run with elevated privileges.
    public let privileged: Bool?

    /// Working directory for the hook.
    public let working_dir: String?

    /// Environment variables for the hook.
    public let environment: [String: String]?

    enum CodingKeys: String, CodingKey {
        case command, user, privileged, working_dir, environment
    }

    public init(
        command: [String]? = nil,
        user: String? = nil,
        privileged: Bool? = nil,
        working_dir: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.command = command
        self.user = user
        self.privileged = privileged
        self.working_dir = working_dir
        self.environment = environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // command accepts a single string or an array of strings.
        if let cmdArray = try? container.decodeIfPresent([String].self, forKey: .command) {
            command = cmdArray
        } else if let cmdString = try? container.decodeIfPresent(String.self, forKey: .command) {
            command = [cmdString]
        } else {
            command = nil
        }

        user = try container.decodeIfPresent(String.self, forKey: .user)
        privileged = try container.decodeIfPresent(Bool.self, forKey: .privileged)
        working_dir = try container.decodeIfPresent(String.self, forKey: .working_dir)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment)
    }
}
