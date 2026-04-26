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

/// The condition under which a dependency is considered satisfied,
/// matching the Docker Compose `depends_on` condition values.
public enum DependsOnCondition: String, Codable, Sendable, CaseIterable {
    /// The dependency container must be running (started, not necessarily healthy).
    /// Corresponds to `condition: service_started` in Docker Compose.
    case serviceStarted = "service_started"

    /// The dependency container must be running AND report a healthy status.
    /// Corresponds to `condition: service_healthy` in Docker Compose.
    case serviceHealthy = "service_healthy"

    /// The dependency container must have exited with a zero exit code.
    /// Corresponds to `condition: service_completed_successfully` in Docker Compose.
    case serviceCompletedSuccessfully = "service_completed_successfully"
}
