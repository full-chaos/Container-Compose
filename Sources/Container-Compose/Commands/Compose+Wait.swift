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

import ContainerAPIClient
import ContainerResource
import Foundation

extension ComposeUp {
    func waitForCondition(
        _ serviceName: String,
        explicitContainerName: String? = nil,
        condition: DependsOnCondition,
        timeout: TimeInterval = 60,
        interval: TimeInterval = 0.5
    ) async throws {
        guard let projectName else {
            return
        }

        let containerName = effectiveContainerName(
            projectName: projectName,
            serviceName: serviceName,
            explicit: explicitContainerName
        )
        let deadline = Date().addingTimeInterval(timeout)
        let provider = ContainerClientEnvironment.current

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let container = try? await provider.get(id: containerName)

            guard let container else {
                continue
            }

            let status = container.status
            switch condition {
            case .serviceStarted:
                if status == .running {
                    return
                }

            case .serviceHealthy:
                if status == .running {
                    if let health = container.health {
                        if health == .healthy {
                            return
                        }
                    } else {
                        return
                    }
                }

            case .serviceCompletedSuccessfully:
                if status == .stopped {
                    if let exitCode = container.lastExitCode, exitCode != 0 {
                        throw ComposeWaitError.nonZeroExitCode(
                            containerName: containerName,
                            exitCode: exitCode
                        )
                    }
                    return
                }
            }
        }

        throw ComposeWaitError.timeout(serviceName: serviceName, containerName: containerName, condition: condition, seconds: timeout)
    }
}

// MARK: - ComposeWaitError

/// Errors that can be thrown by `waitForCondition`.
public enum ComposeWaitError: Error, LocalizedError {
    /// The container did not satisfy the required condition within the allotted time.
    case timeout(serviceName: String, containerName: String, condition: DependsOnCondition, seconds: TimeInterval)

    /// The container reached `.stopped` state with a non-zero exit code while waiting
    /// on `service_completed_successfully`.
    case nonZeroExitCode(containerName: String, exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case let .timeout(serviceName, containerName, condition, seconds):
            return
                "Timed out after \(Int(seconds))s waiting for container '\(containerName)' " +
                "(service '\(serviceName)') to satisfy condition '\(condition.rawValue)'."
        case let .nonZeroExitCode(name, exitCode):
            return
                "Container '\(name)' exited with non-zero status \(exitCode); " +
                "service_completed_successfully condition not satisfied."
        }
    }
}
