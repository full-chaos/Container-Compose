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

// MARK: - GET /events

/// CHAOS-1350 NDJSON lifecycle-event frame emitted by `GET /events`.
/// The wire shape stays intentionally flat so clients do not observe Swift enum
/// associated-value encoding details from `RuntimeContainerEvent`.
public struct APIEventFrame: Codable, Sendable, Hashable {
    public let type: String
    public let id: String
    public let timestamp: Date
    public let exitCode: Int32?
    public let signal: Int32?

    public init(
        type: String,
        id: String,
        timestamp: Date,
        exitCode: Int32?,
        signal: Int32?
    ) {
        self.type = type
        self.id = id
        self.timestamp = timestamp
        self.exitCode = exitCode
        self.signal = signal
    }
}

// MARK: - GET /events  (legacy Phase 2.A schema reservation)

public struct APIEvent: Codable, Sendable, Hashable {
    public let type: String
    public let action: String
    public let id: String
    public let time: Date
    public let attributes: [String: String]

    public init(
        type: String,
        action: String,
        id: String,
        time: Date,
        attributes: [String: String]
    ) {
        self.type = type
        self.action = action
        self.id = id
        self.time = time
        self.attributes = attributes
    }
}
