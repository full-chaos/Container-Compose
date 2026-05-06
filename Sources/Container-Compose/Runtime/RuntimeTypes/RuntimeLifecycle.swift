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

// MARK: - RuntimeStopOptions

public struct RuntimeStopOptions: Sendable, Equatable {
    public let signal: Int32
    public let timeoutSeconds: Int

    public static let `default` = RuntimeStopOptions(signal: 15, timeoutSeconds: 10)

    public init(signal: Int32, timeoutSeconds: Int) {
        self.signal = signal
        self.timeoutSeconds = timeoutSeconds
    }
}

// MARK: - RuntimeExitStatus

public struct RuntimeExitStatus: Sendable, Hashable, Codable {
    public let exitCode: Int32
    public let exitedAt: Date

    public init(exitCode: Int32, exitedAt: Date) {
        self.exitCode = exitCode
        self.exitedAt = exitedAt
    }
}

// MARK: - RuntimeContainerEvent

/// Synthesized lifecycle event emitted by `Runtime` conformers at create /
/// start / stop / kill / wait / remove call sites. The upstream
/// `apple/containerization` library has no native event stream; the
/// `AppleContainerizationRuntime` conformer wraps every lifecycle entry point
/// to produce these. The bridge conformer (Phase 1) does not emit these
/// natively but will forward upstream `ContainerEvent` translations in Phase 2
/// when more lifecycle paths migrate.
public enum RuntimeContainerEvent: Sendable, Hashable {
    case created(id: String, at: Date)
    case started(id: String, at: Date)
    case stopped(id: String, exitCode: Int32, at: Date)
    case killed(id: String, signal: Int32, at: Date)
    case oomKilled(id: String, at: Date)
    case removed(id: String, at: Date)
}
