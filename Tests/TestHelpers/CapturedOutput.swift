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
import ContainerComposeCore

/// Process-wide serializer for tests that capture global file descriptors
/// (`STDOUT_FILENO` / `STDERR_FILENO`) via `dup2`.
///
/// ## Why this exists (CHAOS-1509)
///
/// ~14 test files in `Container-Compose-StaticTests` capture printed
/// warnings by redirecting `STDOUT_FILENO` to a `Pipe` for the duration
/// of a test body, then restoring it. Under `swift test --parallel`,
/// multiple suites run their tests concurrently and any two captures
/// can interleave their `dup2` / `readDataToEndOfFile()` calls. The
/// result is a `readDataToEndOfFile()` that never returns because its
/// write end was hijacked by another test's restore — `swift test`
/// hangs indefinitely (CI runs observed at 30+ minutes).
///
/// `@Suite(.serialized)` is insufficient: it only serializes within a
/// single suite. Captures in DIFFERENT serialized suites can still run
/// in parallel with each other under `swift test --parallel`.
///
/// `CapturedOutput` exposes a single process-wide `AsyncSemaphore`
/// (`value: 1`) that every capture helper acquires before any FD
/// manipulation and releases after `readDataToEndOfFile()` returns —
/// guaranteeing at most one capture in flight across the entire
/// process. `AsyncSemaphore` is preferred over `NSLock` here because
/// `NSLock.lock()` / `try()` are marked `@available(*, noasync)` in
/// modern Foundation and the lock is thread-bound (unsafe to hold
/// across `await` suspension points).
///
/// ## Usage
///
/// Every capture helper acquires before FD manipulation and releases
/// after `readDataToEndOfFile()` returns:
///
/// ```swift
/// private func captureStandardOutput(_ body: () throws -> Void) async throws -> String {
///     try await CapturedOutput.acquire()
///     defer { CapturedOutput.releaseFireAndForget() }
///     // existing dup2/body/restore code unchanged
/// }
/// ```
///
/// Sync capture helpers must convert to `async throws`; their callers
/// (already `async throws` test functions) add `await`.
public enum CapturedOutput {

    /// Single process-wide capture semaphore. Use `acquire()` /
    /// `releaseFireAndForget()` rather than touching this directly.
    public static let semaphore = AsyncSemaphore(value: 1)

    /// Acquire the capture permit. Suspends until granted.
    /// Throws `CancellationError` if the calling task is cancelled
    /// before a permit is available.
    public static func acquire() async throws {
        try await semaphore.acquire()
    }

    /// Release the capture permit. `AsyncSemaphore.release()` is actor-
    /// isolated so it must be `await`-ed; callers in a synchronous
    /// `defer` cannot do that. `releaseFireAndForget()` launches an
    /// unstructured `Task` to release. Acceptable here because the next
    /// `acquire()` call from another capturer will simply suspend until
    /// the release Task is scheduled (no permit lost, no double-acquire).
    public static func releaseFireAndForget() {
        Task { await semaphore.release() }
    }
}
