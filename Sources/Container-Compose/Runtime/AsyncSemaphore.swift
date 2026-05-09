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

// MARK: - AsyncSemaphore

/// Cooperative, actor-isolated counting semaphore. Used to bound the number
/// of concurrent operations a fan-out helper schedules — the
/// `runBoundedThrowingFanOut(...)` helper in `ParallelOrchestration.swift`
/// is the primary client (CHAOS-1446 Phase 1).
///
/// Why an actor (and NOT `DispatchSemaphore`):
/// - `DispatchSemaphore.wait()` blocks the underlying executor thread.
///   Under Swift 6 strict concurrency the cooperative thread pool is small
///   (typically `ProcessInfo.activeProcessorCount`) and blocking one with a
///   `wait()` while other tasks are also blocked produces immediate
///   deadlocks. The cooperative model only stays correct if every async
///   `await` actually suspends.
/// - This actor's `acquire()` suspends via `withCheckedThrowingContinuation`,
///   freeing the executor thread for sibling tasks while the caller waits.
///
/// Cancellation contract:
/// - `acquire()` checks `Task.isCancelled` before suspending; cancelled
///   callers throw `CancellationError()` immediately and consume no permit.
/// - A waiter that is cancelled while suspended is removed from the queue
///   via `withTaskCancellationHandler` and resumed with `CancellationError`.
///   No permit is consumed.
/// - The race where `release()` resumes a waiter that was *also* cancelled
///   resolves in favor of release — the resumed `acquire()` returns
///   normally, the body runs, and the permit balances on `release()`.
///   The "cancellation lost" window is narrow and harmless (the body's
///   own `Task.checkCancellation()` calls will still observe cancellation).
///
/// Lifetime:
/// - The semaphore must outlive every outstanding `acquire()` call. In
///   practice, the fan-out helper builds the semaphore on the stack and
///   the helper's `withThrowingTaskGroup` ensures all child tasks finish
///   before the helper returns — so the semaphore is alive throughout.
public actor AsyncSemaphore {

    /// One waiter pending in the FIFO queue. The UUID lets the
    /// cancellation handler target the right waiter without indexing
    /// concerns when other waiters arrive or leave concurrently.
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var permits: Int
    private var waiters: [Waiter] = []

    /// Initialize with `value` permits.
    /// - Precondition: `value >= 1`. `0`-permit semaphores have no
    ///   sensible release semantics in this codebase; the fan-out helper
    ///   validates `limit >= 1` upstream so the precondition fires only on
    ///   programmer error.
    public init(value: Int) {
        precondition(value >= 1, "AsyncSemaphore requires value >= 1; got \(value)")
        self.permits = value
    }

    /// Acquire one permit. Returns once a permit is available. Throws
    /// `CancellationError()` if the calling task was cancelled before or
    /// while waiting.
    ///
    /// On successful return the caller owns one permit and MUST balance
    /// it with exactly one `release()`. The convenience wrapper
    /// `withPermit(_:)` enforces the balance automatically.
    public func acquire() async throws {
        try Task.checkCancellation()

        if permits > 0 {
            permits -= 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            // The cancellation closure runs OFF the actor (it's @Sendable
            // and may fire from any thread). Hop back onto the actor to
            // mutate the waiters list safely.
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    /// Internal: actor-isolated cleanup invoked from the cancellation
    /// handler when a waiting task is cancelled. If the waiter was already
    /// removed by `release(...)` we no-op — the race favored release and
    /// the acquirer will see a successful permit. Otherwise we remove the
    /// waiter and resume it with `CancellationError`.
    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let removed = waiters.remove(at: index)
        removed.continuation.resume(throwing: CancellationError())
    }

    /// Release one permit. Wakes the longest-waiting acquirer (FIFO) if
    /// any; otherwise increments the permit count.
    public func release() {
        if waiters.isEmpty {
            permits += 1
            return
        }
        let next = waiters.removeFirst()
        next.continuation.resume()
    }

    // MARK: - Convenience

    /// Acquire a permit, run `body`, release the permit. Releases the
    /// permit even if `body` throws. If acquisition itself fails (e.g.
    /// the calling task was cancelled before a permit was available),
    /// the body never runs and no spurious release is performed.
    ///
    /// `body` is `@Sendable` because it executes inside a child task in
    /// fan-out scenarios. Restricting `T: Sendable` keeps the return
    /// value transmissible across that boundary.
    public func withPermit<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    // MARK: - Test affordances

    /// Snapshot of the current permit count. Test-only.
    /// Permit count may be negative-equivalent in spirit when waiters are
    /// queued (this implementation tracks waiters separately, so `permits`
    /// is always `>= 0`).
    internal func currentPermits() -> Int { permits }

    /// Snapshot of the current waiter queue depth. Test-only.
    internal func currentWaiterCount() -> Int { waiters.count }
}
