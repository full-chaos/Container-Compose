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

// MARK: - RuntimeLogOptions / RuntimeLogFrame

public struct RuntimeLogOptions: Sendable, Equatable {
    public let follow: Bool
    public let tail: Int?
    public let since: Date?
    public let timestamps: Bool

    public static let `default` = RuntimeLogOptions(follow: false, tail: nil, since: nil, timestamps: false)

    public init(follow: Bool, tail: Int?, since: Date?, timestamps: Bool = false) {
        self.follow = follow
        self.tail = tail
        self.since = since
        self.timestamps = timestamps
    }
}

public struct RuntimeLogFrame: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case stdout
        case stderr
    }
    public let timestamp: Date
    public let source: Source
    public let data: Data

    public init(timestamp: Date, source: Source, data: Data) {
        self.timestamp = timestamp
        self.source = source
        self.data = data
    }
}
