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
import Foundation

extension ComposeUp {
    /// Polls the Apple `container` runtime until the named container satisfies
    /// the given `DependsOnCondition`, or throws on timeout.
    ///
    /// Condition semantics:
    /// - **serviceStarted**: returns when `container.status == .running`.
    /// - **serviceHealthy**: returns when `status == .running`. The Apple `container`
    ///   runtime package (`ContainerSnapshot`) does not currently expose a health / liveness
    ///   field on the container snapshot. Until it does, this condition falls back to
    ///   `.running` and emits a one-time warning.
    ///   // TODO: Re-implement true health check once the upstream Swift container package
    ///   // surfaces a health field on ContainerSnapshot.
    /// - **serviceCompletedSuccessfully**: returns when `container.status == .stopped`
    ///   AND `container.lastExitCode == 0`. Throws `ComposeWaitError.nonZeroExitCode` if
    ///   the container stopped with a non-zero exit code. If `lastExitCode` is `nil`
    ///   (e.g., the container exited before the daemon captured the code, or the daemon
    ///   was restarted between exit and read), falls back to treating `.stopped` as
    ///   sufficient and returns normally.
    ///
    /// - Parameters:
    ///   - serviceName: The logical service name (e.g. "db"). The container name is
    ///     derived as `"\(projectName)-\(serviceName)"`.
    ///   - condition: The `DependsOnCondition` that must be satisfied.
    ///   - timeout: Maximum number of seconds to wait before throwing. Defaults to 60 s.
    ///   - interval: Polling interval in seconds. Defaults to 0.5 s.
    /// - Throws: `ComposeWaitError.timeout` if the condition is not met within `timeout`
    ///   seconds, or any error thrown by `ContainerClient`.
    func waitForCondition(
        _ serviceName: String,
        condition: DependsOnCondition,
        timeout: TimeInterval = 60,
        interval: TimeInterval = 0.5
    ) async throws {
        guard let projectName else {
            // If there is no project name we cannot form a container name;
            // treat as a no-op (mirrors the behavior of waitUntilServiceIsRunning).
            return
        }

        let containerName = "\(projectName)-\(serviceName)"
        let deadline = Date().addingTimeInterval(timeout)
        let provider = ContainerClientEnvironment.current

        // Emit one-time warnings for conditions that cannot be fully implemented
        // with the current ContainerSnapshot API surface.
        switch condition {
        case .serviceHealthy:
            print(
                "Warning: waitForCondition(.serviceHealthy) for '\(serviceName)': " +
                "The Apple container runtime does not currently expose a health field on " +
                "ContainerSnapshot. Falling back to status == .running. " +
                "// TODO: Enforce true health check once upstream package surfaces health."
            )
        case .serviceCompletedSuccessfully, .serviceStarted:
            break
        }

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let container = try? await provider.get(id: containerName)

            guard let container else {
                // Container not found yet; keep polling.
                continue
            }

            let status = container.status
            switch condition {
            case .serviceStarted:
                // Condition satisfied when the container is running.
                if status == .running {
                    return
                }

            case .serviceHealthy:
                // TODO: Re-implement true health check once ContainerSnapshot exposes health.
                // Fall back to running status as the best available proxy for "healthy".
                if status == .running {
                    return
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

        throw ComposeWaitError.timeout(containerName: containerName, condition: condition, seconds: timeout)
    }
}

// MARK: - ComposeWaitError

/// Errors that can be thrown by `waitForCondition`.
public enum ComposeWaitError: Error, LocalizedError {
    /// The container did not satisfy the required condition within the allotted time.
    case timeout(containerName: String, condition: DependsOnCondition, seconds: TimeInterval)

    /// The container reached `.stopped` state with a non-zero exit code while waiting
    /// on `service_completed_successfully`.
    case nonZeroExitCode(containerName: String, exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case let .timeout(name, condition, seconds):
            return
                "Timed out after \(Int(seconds))s waiting for container '\(name)' " +
                "to satisfy condition '\(condition.rawValue)'."
        case let .nonZeroExitCode(name, exitCode):
            return
                "Container '\(name)' exited with non-zero status \(exitCode); " +
                "service_completed_successfully condition not satisfied."
        }
    }
}
