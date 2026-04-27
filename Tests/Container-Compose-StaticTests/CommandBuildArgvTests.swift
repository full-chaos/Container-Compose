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

import Testing
import Foundation
@testable import ContainerComposeCore

/// Static argv-shape tests for `ComposeUp.imageAndEntrypointTail`.
///
/// Regression coverage for the `--entrypoint` ordering bug: previously
/// `compose up` emitted `<image> --entrypoint a b c`, which `container run`
/// (and `docker run`) interpret as command tokens, not as a runtime override.
/// The corrected shape places `--entrypoint <first>` *before* the image and
/// any remaining entrypoint tokens after, with `command` appended last.
@Suite("Command Build Argv Tests")
struct CommandBuildArgvTests {

    private let image = "alpine:latest"

    @Test("single-token entrypoint, no command → --entrypoint precedes image")
    func singleEntrypointNoCommand() {
        let argv = ComposeUp.imageAndEntrypointTail(
            image: image,
            entrypoint: ["/app/foo.sh"],
            command: nil
        )
        #expect(argv == ["--entrypoint", "/app/foo.sh", image])
    }

    @Test("multi-token entrypoint, no command → first as flag, rest after image")
    func multiEntrypointNoCommand() {
        let argv = ComposeUp.imageAndEntrypointTail(
            image: image,
            entrypoint: ["a", "b", "c"],
            command: nil
        )
        #expect(argv == ["--entrypoint", "a", image, "b", "c"])
    }

    @Test("single-token entrypoint plus command → command appended after image")
    func singleEntrypointWithCommand() {
        let argv = ComposeUp.imageAndEntrypointTail(
            image: image,
            entrypoint: ["a"],
            command: ["x", "y"]
        )
        #expect(argv == ["--entrypoint", "a", image, "x", "y"])
    }

    @Test("no entrypoint, command only → image then command tokens")
    func commandOnly() {
        let argv = ComposeUp.imageAndEntrypointTail(
            image: image,
            entrypoint: nil,
            command: ["x"]
        )
        #expect(argv == [image, "x"])
    }

    @Test("neither entrypoint nor command → image alone")
    func imageOnly() {
        let argv = ComposeUp.imageAndEntrypointTail(
            image: image,
            entrypoint: nil,
            command: nil
        )
        #expect(argv == [image])
    }

    // MARK: - Edge case: empty arrays

    // Intentional contract: an empty entrypoint array and nil are deliberately treated as the same case in `imageAndEntrypointTail`.
    @Test("empty entrypoint array behaves like nil — image first")
    func emptyEntrypointArray() {
        let argv = ComposeUp.imageAndEntrypointTail(
            image: image,
            entrypoint: [],
            command: ["x"]
        )
        // No first token to extract, so no --entrypoint flag is emitted.
        #expect(argv == [image, "x"])
    }

    // MARK: - Multi-token entrypoint + command (combined)

    @Test("multi-token entrypoint plus command → all positional tokens follow image in order")
    func multiEntrypointWithCommand() {
        let argv = ComposeUp.imageAndEntrypointTail(
            image: image,
            entrypoint: ["a", "b", "c"],
            command: ["d", "e"]
        )
        #expect(argv == ["--entrypoint", "a", image, "b", "c", "d", "e"])
    }
}
