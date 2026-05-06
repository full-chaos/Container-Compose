//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
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

// MARK: - Lifecycle Schemas (CHAOS-1354)

/// Request body for `POST /containers/{id}/stop`.
/// All fields are optional; omitted fields fall back to `RuntimeStopOptions.default`
/// (signal 15 / SIGTERM, 10 s timeout).
public struct APIStopRequest: Codable, Sendable, Hashable {
    /// POSIX signal number to send before force-killing. Defaults to 15 (SIGTERM).
    public let signal: Int32?
    /// Seconds to wait for the container to stop gracefully before SIGKILL. Defaults to 10.
    public let timeoutSeconds: Int?

    public init(signal: Int32?, timeoutSeconds: Int?) {
        self.signal = signal
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Request body for `POST /containers/{id}/kill`.
/// If omitted the body defaults to signal 9 (SIGKILL).
public struct APIKillRequest: Codable, Sendable, Hashable {
    /// POSIX signal number to deliver. Defaults to 9 (SIGKILL).
    public let signal: Int32?

    public init(signal: Int32?) {
        self.signal = signal
    }
}

/// Response body for `POST /containers/{id}/wait`.
/// Returns the exit code and the time the container exited.
public struct APIWaitResponse: Codable, Sendable, Hashable {
    public let exitCode: Int32
    public let exitedAt: Date

    public init(exitCode: Int32, exitedAt: Date) {
        self.exitCode = exitCode
        self.exitedAt = exitedAt
    }
}
