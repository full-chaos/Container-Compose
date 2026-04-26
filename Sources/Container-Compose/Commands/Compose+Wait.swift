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
    /// - **serviceCompletedSuccessfully**: returns when `container.status == .stopped`.
    ///   The Apple `container` runtime does not currently expose a per-container exit code
    ///   on `ContainerSnapshot`, so we can only verify that the container has stopped, not
    ///   that it stopped with exit code 0. A `ComposeWaitError.exitCodeUnavailable` error
    ///   is thrown after the container reaches `.stopped` state if strict exit-code
    ///   verification is ever required by callers; currently, reaching `.stopped` is treated
    ///   as sufficient and the function returns normally with a warning.
    ///   // TODO: Re-implement strict exit-code check once ContainerSnapshot exposes exitCode.
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
        let client = ContainerClient()

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
        case .serviceCompletedSuccessfully:
            print(
                "Warning: waitForCondition(.serviceCompletedSuccessfully) for '\(serviceName)': " +
                "The Apple container runtime does not currently expose an exit code on " +
                "ContainerSnapshot. This condition will return as soon as status == .stopped, " +
                "without verifying exit code 0. " +
                "// TODO: Add exit-code check once ContainerSnapshot exposes exitCode."
            )
        case .serviceStarted:
            break
        }

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let container = try? await client.get(id: containerName)

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
                // TODO: Add exit-code == 0 check once ContainerSnapshot exposes exitCode.
                // For now, reaching .stopped is treated as "completed".
                if status == .stopped {
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

    /// The exit code of the container is unavailable (reserved for future use once
    /// ContainerSnapshot exposes exitCode).
    case exitCodeUnavailable(containerName: String)

    public var errorDescription: String? {
        switch self {
        case let .timeout(name, condition, seconds):
            return
                "Timed out after \(Int(seconds))s waiting for container '\(name)' " +
                "to satisfy condition '\(condition.rawValue)'."
        case let .exitCodeUnavailable(name):
            return
                "Cannot verify exit code for container '\(name)': " +
                "ContainerSnapshot does not expose an exit code field in the current " +
                "Apple container runtime package."
        }
    }
}
