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

// MARK: - GET /containers/{id}/logs

/// CHAOS-1350 NDJSON log frame emitted by `GET /containers/{id}/logs`.
/// `line` is UTF-8 text decoded from `RuntimeLogFrame.data`; `stream` is
/// derived from the runtime frame source (`stdout` / `stderr`).
public struct APILogFrame: Codable, Sendable, Hashable {
    public let stream: String
    public let timestamp: Date
    public let line: String

    public init(stream: String, timestamp: Date, line: String) {
        self.stream = stream
        self.timestamp = timestamp
        self.line = line
    }
}
