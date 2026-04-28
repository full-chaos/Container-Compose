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
//  DeployPlacement.swift
//  container-compose-app
//

/// Placement constraints and preferences for Swarm scheduling.
///
/// Swarm-only; decoded but not enforced.
public struct DeployPlacement: Codable, Hashable {
    /// List of placement constraint expressions (e.g. "node.role == manager").
    ///
    /// Swarm-only; decoded but not enforced.
    public let constraints: [String]?

    /// List of placement preference entries used for spreading tasks.
    ///
    /// Swarm-only; decoded but not enforced.
    public let preferences: [DeployPlacementPreference]?

    /// Maximum number of replicas to place on a single node.
    ///
    /// Swarm-only; decoded but not enforced.
    public let max_replicas_per_node: Int?
}
