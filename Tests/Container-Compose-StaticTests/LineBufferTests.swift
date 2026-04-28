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

/// Unit tests for `LineBuffer`, the helper introduced for PLAN.md §4 — the
/// streaming-relay log column-wrap fix. `LineBuffer` accumulates byte
/// chunks read off a `FileHandle` and emits one closure call per complete
/// `\n`-terminated line, eliminating the previous bug where
/// `ProductionRunner.spawnStreaming` treated every transport-chunk
/// boundary as a line boundary (so the per-service prefix added by
/// `ComposeUp`'s `handleOutput` closure was repeated for each fragment).
///
/// The end-to-end "chunked stdin produces one emission per line" test
/// (`endToEndChunkedStdoutProducesOneLineAtATime`) drives a real
/// `/bin/sh` subprocess through `ProductionRunner` and is the regression
/// guard against the column-wrap bug returning.
@Suite("LineBuffer", .serialized)
struct LineBufferTests {

    // MARK: - Helpers

    /// Run a single `append` and capture its emissions.
    private func emissions(of buffer: LineBuffer, append data: Data) -> [String] {
        var out: [String] = []
        buffer.append(data) { out.append($0) }
        return out
    }

    /// Run a single `flush` and capture its emissions.
    private func flushed(_ buffer: LineBuffer) -> [String] {
        var out: [String] = []
        buffer.flush { out.append($0) }
        return out
    }

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - LineBuffer cases

    @Test("Empty input produces no emissions")
    func emptyInputNoEmissions() {
        let b = LineBuffer()
        #expect(emissions(of: b, append: Data()).isEmpty)
        #expect(flushed(b).isEmpty)
    }

    @Test("Single complete line emits once without trailing newline")
    func singleCompleteLine() {
        let b = LineBuffer()
        #expect(emissions(of: b, append: data("hello\n")) == ["hello"])
    }

    @Test("Multiple complete lines emit once each")
    func multipleCompleteLines() {
        let b = LineBuffer()
        #expect(emissions(of: b, append: data("a\nb\nc\n")) == ["a", "b", "c"])
    }

    @Test("Partial line stays buffered until newline arrives")
    func partialThenComplete() {
        let b = LineBuffer()
        #expect(emissions(of: b, append: data("hel")).isEmpty)
        #expect(emissions(of: b, append: data("lo\n")) == ["hello"])
    }

    @Test("Complete + partial: complete line emits, partial buffered, flush emits the rest")
    func completePlusPartial() {
        let b = LineBuffer()
        #expect(emissions(of: b, append: data("a\nb")) == ["a"])
        #expect(flushed(b) == ["b"])
    }

    @Test("Multi-byte UTF-8 split across appends is rejoined correctly")
    func utf8SplitAcrossAppends() {
        // 'é' is U+00E9 → UTF-8 0xC3 0xA9.
        let b = LineBuffer()
        #expect(emissions(of: b, append: Data([0xC3])).isEmpty)
        #expect(emissions(of: b, append: Data([0xA9, 0x0A])) == ["é"])
    }

    @Test("CRLF endings: \\r stays attached, only \\n splits")
    func crlfStaysAttached() {
        // Documented contract: we split only on `\n`, so a CRLF line
        // ending leaves the `\r` as the last character of the emitted
        // line. Callers print whole lines with their own trailing
        // newline, so a stray `\r` is harmless.
        let b = LineBuffer()
        #expect(emissions(of: b, append: data("hi\r\n")) == ["hi\r"])
    }

    @Test("Flush on empty buffer emits nothing")
    func flushOnEmpty() {
        let b = LineBuffer()
        #expect(flushed(b).isEmpty)
    }

    @Test("Flush after only-complete-line emissions does not re-emit")
    func flushAfterCompleteIsNoop() {
        let b = LineBuffer()
        #expect(emissions(of: b, append: data("a\n")) == ["a"])
        #expect(flushed(b).isEmpty)
    }

    @Test("Empty line between newlines is preserved as empty string")
    func emptyLineBetweenNewlines() {
        let b = LineBuffer()
        #expect(emissions(of: b, append: data("a\n\nb\n")) == ["a", "", "b"])
    }

    // MARK: - End-to-end regression guard

    /// Spawn a tiny `/bin/sh` script that emits multi-line output in two
    /// chunks straddling a line boundary, and assert that
    /// `ProductionRunner.spawnStreaming` calls the stdout closure exactly
    /// once per logical line. This is the direct regression guard against
    /// PLAN.md §4 returning — the pre-fix behaviour would call `onStdout`
    /// twice (`"a\nb"`, `"c\n"`), once per `availableData` chunk.
    @Test("ProductionRunner streaming emits one closure call per logical line")
    func endToEndChunkedStdoutProducesOneLineAtATime() async throws {
        // Synchronous, lock-protected sink so emission order is preserved
        // (readabilityHandler invocations on a single FileHandle are
        // serialized, but we still need a Sendable wrapper to capture into).
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var _stdout: [String] = []
            private var _stderr: [String] = []
            func appendStdout(_ s: String) { lock.lock(); _stdout.append(s); lock.unlock() }
            func appendStderr(_ s: String) { lock.lock(); _stderr.append(s); lock.unlock() }
            var stdout: [String] { lock.lock(); defer { lock.unlock() }; return _stdout }
            var stderr: [String] { lock.lock(); defer { lock.unlock() }; return _stderr }
        }
        let sink = Sink()

        // Sleep long enough that the first `printf` data and the second
        // `printf` data arrive in separate `availableData` chunks. The
        // first chunk straddles a line boundary ("a\nb") so a correct
        // line-buffered relay must:
        //   - emit "a" immediately,
        //   - hold "b" until the next chunk's "c\n" arrives,
        //   - then emit "bc".
        // Pre-fix behaviour would have emitted "a\nb" then "c" — two
        // calls — so the per-service prefix would have been printed
        // twice for the joined "bc" line.
        let argv = [
            "/bin/sh",
            "-c",
            "printf 'a\\nb'; sleep 0.1; printf 'c\\n'"
        ]
        let request = RunRequest(kind: .streaming, argv: argv, cwd: nil)

        let runner = ProductionRunner()
        let result = try await runner.run(
            request,
            onStdout: { line in sink.appendStdout(line) },
            onStderr: { line in sink.appendStderr(line) }
        )

        #expect(result.exitCode == 0)
        #expect(sink.stdout == ["a", "bc"])
        #expect(sink.stderr.isEmpty)
    }
}
