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
//  DeployUpdateConfig.swift
//  container-compose-app
//

/// Configuration for rolling update or rollback behaviour in Swarm mode.
///
/// This type is shared between `deploy.update_config` and `deploy.rollback_config`
/// as both have the same shape per the compose-spec.
///
/// Swarm-only; decoded but not enforced.
public struct DeployUpdateConfig: Codable, Hashable {
    /// Number of containers to update in parallel.
    ///
    /// Swarm-only; decoded but not enforced.
    public let parallelism: Int?

    /// Delay between updates/rollbacks (duration string, e.g. "10s").
    ///
    /// Swarm-only; decoded but not enforced.
    public let delay: String?

    /// Action to take on update/rollback failure ("pause", "continue", "rollback").
    ///
    /// Swarm-only; decoded but not enforced.
    public let failure_action: String?

    /// Duration to monitor updated tasks after each update (duration string).
    ///
    /// Swarm-only; decoded but not enforced.
    public let monitor: String?

    /// Maximum fraction of tasks allowed to fail during an update.
    ///
    /// Swarm-only; decoded but not enforced.
    public let max_failure_ratio: Double?

    /// Order of operations: "start-first" or "stop-first".
    ///
    /// Swarm-only; decoded but not enforced.
    public let order: String?
}
