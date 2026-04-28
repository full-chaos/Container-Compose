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

/// Static argv-shape tests for `ComposeRun.imageAndEntrypointTail`.
///
/// Mirrors `CommandBuildArgvTests` for `compose up`, with one extra wrinkle:
/// `compose run`'s CLI command override (`compose run [--] SVC CMD…`)
/// suppresses the service-level `entrypoint` AND `command`, and the supplied
/// tokens become positional args after the image with no `--entrypoint` flag
/// emitted. PR-3 of the recorder seam migration introduces this helper as the
/// fix for `docs/plans/PLAN.md` §1 at the `compose run` site (the previous
/// 9-line block placed `--entrypoint` *after* the image).
@Suite("ComposeRun Argv Tail Tests")
struct ComposeRunArgvTailTests {

    private let image = "alpine:latest"

    // MARK: - CLI command override (highest precedence)

    @Test("CLI command non-empty + entrypoint set → CLI wins, no --entrypoint emitted")
    func cliCommandSuppressesServiceEntrypoint() {
        let argv = ComposeRun.imageAndEntrypointTail(
            image: image,
            cliCommand: ["x"],
            entrypoint: ["/app/foo"],
            command: nil
        )
        // `docker compose run svc x` semantics: image's default ENTRYPOINT
        // stays, x is the in-container command. Service entrypoint is dropped.
        #expect(argv == [image, "x"])
    }

    @Test("CLI command non-empty + entrypoint + service command → CLI wins; service command suppressed")
    func cliCommandSuppressesBothEntrypointAndServiceCommand() {
        let argv = ComposeRun.imageAndEntrypointTail(
            image: image,
            cliCommand: ["x", "y"],
            entrypoint: ["/app/foo", "bar"],
            command: ["baz"]
        )
        #expect(argv == [image, "x", "y"])
    }

    @Test("CLI command non-empty, no entrypoint or command → CLI tokens after image")
    func cliCommandOnlyAfterImage() {
        let argv = ComposeRun.imageAndEntrypointTail(
            image: image,
            cliCommand: ["echo", "hello"],
            entrypoint: nil,
            command: nil
        )
        #expect(argv == [image, "echo", "hello"])
    }

    // MARK: - No CLI override → mirrors ComposeUp behaviour

    @Test("empty CLI, single-token entrypoint → --entrypoint precedes image")
    func singleEntrypointNoCliCommand() {
        let argv = ComposeRun.imageAndEntrypointTail(
            image: image,
            cliCommand: [],
            entrypoint: ["/app/foo"],
            command: nil
        )
        #expect(argv == ["--entrypoint", "/app/foo", image])
    }

    @Test("empty CLI, multi-token entrypoint + service command → head as flag, rest + command after image")
    func multiEntrypointWithServiceCommand() {
        let argv = ComposeRun.imageAndEntrypointTail(
            image: image,
            cliCommand: [],
            entrypoint: ["a", "b"],
            command: ["c"]
        )
        #expect(argv == ["--entrypoint", "a", image, "b", "c"])
    }

    @Test("empty CLI, no entrypoint, command only → image then command tokens")
    func commandOnlyNoCliNoEntrypoint() {
        let argv = ComposeRun.imageAndEntrypointTail(
            image: image,
            cliCommand: [],
            entrypoint: nil,
            command: ["x"]
        )
        #expect(argv == [image, "x"])
    }

    @Test("empty CLI, neither entrypoint nor command → image alone")
    func imageOnlyNoCli() {
        let argv = ComposeRun.imageAndEntrypointTail(
            image: image,
            cliCommand: [],
            entrypoint: nil,
            command: nil
        )
        #expect(argv == [image])
    }

    // MARK: - Edge case: empty entrypoint array

    // Intentional contract: an empty entrypoint array and nil are deliberately
    // treated as the same case in `imageAndEntrypointTail`.
    @Test("empty CLI + empty entrypoint array behaves like nil — image first")
    func emptyEntrypointArrayBehavesLikeNil() {
        let argv = ComposeRun.imageAndEntrypointTail(
            image: image,
            cliCommand: [],
            entrypoint: [],
            command: ["x"]
        )
        #expect(argv == [image, "x"])
    }
}

/// Static argv-shape tests for `ComposeCreate.imageAndEntrypointTail`.
///
/// Mirrors `CommandBuildArgvTests` for `compose up` exactly: `compose create`
/// has no per-call CLI command override (unlike `compose run`), so the
/// signature and contract match `ComposeUp.imageAndEntrypointTail` token-for-
/// token. PR-4 of the recorder seam migration introduces this helper as the
/// fix for `docs/plans/PLAN.md` §1 at the `compose create` site (the previous
/// 9-line block placed `--entrypoint` *after* the image). This is the third
/// and final entrypoint-bug site — §1 fully closed.
@Suite("ComposeCreate Argv Tail Tests")
struct ComposeCreateArgvTailTests {

    private let image = "alpine:latest"

    @Test("single-token entrypoint, no command → --entrypoint precedes image")
    func singleEntrypointNoCommand() {
        let argv = ComposeCreate.imageAndEntrypointTail(
            image: image,
            entrypoint: ["/app/foo.sh"],
            command: nil
        )
        #expect(argv == ["--entrypoint", "/app/foo.sh", image])
    }

    @Test("single-token entrypoint plus command → command appended after image")
    func singleEntrypointWithCommand() {
        let argv = ComposeCreate.imageAndEntrypointTail(
            image: image,
            entrypoint: ["a"],
            command: ["x", "y"]
        )
        #expect(argv == ["--entrypoint", "a", image, "x", "y"])
    }

    @Test("no entrypoint, command only → image then command tokens")
    func commandOnly() {
        let argv = ComposeCreate.imageAndEntrypointTail(
            image: image,
            entrypoint: nil,
            command: ["x"]
        )
        #expect(argv == [image, "x"])
    }

    @Test("neither entrypoint nor command → image alone")
    func imageOnly() {
        let argv = ComposeCreate.imageAndEntrypointTail(
            image: image,
            entrypoint: nil,
            command: nil
        )
        #expect(argv == [image])
    }
}
