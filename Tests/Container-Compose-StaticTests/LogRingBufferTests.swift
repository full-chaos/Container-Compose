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
import Testing
@testable import ContainerComposeCore

@Suite(.serialized)
struct LogRingBufferTests {

    @Test("Each write appends one timestamped frame")
    func writeAppendsFrames() throws {
        let buffer = LogRingBuffer(source: .stdout, capacity: 8)
        try buffer.write(Data("alpha".utf8))
        try buffer.write(Data("beta".utf8))
        let replay = buffer.replay()
        #expect(replay.count == 2)
        #expect(String(data: replay[0].data, encoding: .utf8) == "alpha")
        #expect(String(data: replay[1].data, encoding: .utf8) == "beta")
        #expect(replay[0].source == .stdout)
        #expect(replay[1].source == .stdout)
    }

    @Test("Buffer evicts oldest frames once capacity exceeded")
    func evictsOldestFrames() throws {
        let buffer = LogRingBuffer(source: .stdout, capacity: 3)
        for i in 0..<5 {
            try buffer.write(Data("\(i)".utf8))
        }
        let replay = buffer.replay()
        #expect(replay.count == 3)
        #expect(String(data: replay[0].data, encoding: .utf8) == "2")
        #expect(String(data: replay[1].data, encoding: .utf8) == "3")
        #expect(String(data: replay[2].data, encoding: .utf8) == "4")
    }

    @Test("Replay since: filters out frames older than cursor")
    func replayWithSince() throws {
        let buffer = LogRingBuffer(source: .stderr, capacity: 16)
        try buffer.write(Data("first".utf8))
        // Bracket cursor with sleeps so it lies strictly between the two
        // frame timestamps. Without both sleeps, Date() resolution can
        // tie with the first frame's timestamp and break the >= filter.
        Thread.sleep(forTimeInterval: 0.05)
        let cursor = Date()
        Thread.sleep(forTimeInterval: 0.05)
        try buffer.write(Data("second".utf8))
        let filtered = buffer.replay(options: RuntimeLogOptions(follow: false, tail: nil, since: cursor))
        #expect(filtered.count == 1)
        #expect(String(data: filtered[0].data, encoding: .utf8) == "second")
    }

    @Test("Replay tail: returns the last N frames")
    func replayWithTail() throws {
        let buffer = LogRingBuffer(source: .stdout, capacity: 16)
        for i in 0..<6 {
            try buffer.write(Data("\(i)".utf8))
        }
        let last2 = buffer.replay(options: RuntimeLogOptions(follow: false, tail: 2, since: nil))
        #expect(last2.count == 2)
        #expect(String(data: last2[0].data, encoding: .utf8) == "4")
        #expect(String(data: last2[1].data, encoding: .utf8) == "5")
    }

    @Test("Write after close throws")
    func writeAfterClose() throws {
        let buffer = LogRingBuffer(source: .stdout, capacity: 8)
        try buffer.write(Data("alive".utf8))
        try buffer.close()
        #expect(throws: RuntimeError.self) {
            try buffer.write(Data("zombie".utf8))
        }
        #expect(buffer.replay().count == 1)
    }
}
