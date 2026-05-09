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

// MARK: - ServiceMilestone

/// One readiness milestone a service can reach during compose
/// orchestration. Modeled after `compose-spec`'s `depends_on.condition`
/// values so each `depends_on` edge maps cleanly to one milestone.
///
/// Precedence (which milestone publications satisfy which awaits):
/// - Publishing `.started` satisfies waits for `.started` only.
/// - Publishing `.healthy` satisfies waits for `.healthy` AND `.started`
///   (a service cannot be healthy without first being started).
/// - Publishing `.completedSuccessfully` satisfies waits for
///   `.completedSuccessfully` AND `.started` (a service cannot have
///   completed without first starting). It does NOT satisfy `.healthy`
///   waits — a service may exit `0` without ever passing a healthcheck.
public enum ServiceMilestone: Sendable, Hashable {
    case started
    case healthy
    case completedSuccessfully
}

// MARK: - DependencyCoordinator

/// Per-service readiness coordinator for compose orchestration's parallel
/// service-start phase. Each service-start child task may:
/// 1. `awaitMilestone(for: depName, milestone: ...)` for each `depends_on`
///    edge — suspending on a per-edge milestone, NOT a per-service
///    "max condition" (UltraBrain Critical #4 fix).
/// 2. `publishMilestone(_:for:)` as its own state advances —
///    `.started` when the container is up, `.healthy` after a healthcheck
///    passes, `.completedSuccessfully` after a 0-exit run.
///
/// Why an actor with continuations (and NOT a `[String: Task<Void, Error>]`
/// map):
/// - Storing `Task` handles requires unstructured `Task { ... }` creation
///   (the original `ParallelLifecycleScheduler` did this and was removed
///   per UltraBrain Critical #2). `withThrowingTaskGroup.addTask` does not
///   yield handles you can store back.
/// - Continuations let the caller drive the task lifecycle from within a
///   `withThrowingTaskGroup`, preserving structured concurrency.
/// - Per-edge waits enable mixed conditions: `service A` may have
///   dependents `B` (waiting `started`) and `C` (waiting `healthy`)
///   independently — they are unblocked at their respective milestone
///   publications, not gated to the maximum.
///
/// Cancellation contract:
/// - `awaitMilestone` checks `Task.isCancelled` before suspending and
///   the coordinator's own cancelled flag; cancelled callers throw
///   `CancellationError()` immediately.
/// - A waiter that is cancelled while suspended is removed under actor
///   isolation via `withTaskCancellationHandler`. No state is leaked.
/// - `cancelAll()` is the failure-recovery API: it drains every pending
///   waiter with `CancellationError()` and rejects subsequent
///   `awaitMilestone` calls. Per UltraBrain Critical #6 it MUST be
///   called by `compose up`'s outer catch BEFORE any
///   `EmbeddedDNSSidecar.stop`-style teardown — so service tasks
///   observing the failure cannot publish DNS records or use stale
///   sidecar handles after teardown begins.
///
/// CHAOS-1446 Phase 1 ships the coordinator unwired. Phase 3 wires it
/// into `ComposeStart` / `ComposeStop` / `ComposeRestart` (DNS / env
/// hooks remain no-ops there). Phase 4 wires it into `ComposeUp`
/// alongside `DNSZoneCoordinator`.
public actor DependencyCoordinator {

    /// One suspended waiter. UUID lets the cancellation handler target
    /// the right entry without indexing concerns when other waiters
    /// arrive or leave concurrently.
    private struct Waiter {
        let id: UUID
        let service: String
        let milestone: ServiceMilestone
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Per-service set of milestones already reached. Once a milestone
    /// is recorded for a service, late `awaitMilestone` calls for that
    /// (service, milestone) pair return immediately.
    private var reachedByService: [String: Set<ServiceMilestone>] = [:]

    /// Suspended waiters in submission order. Drained in submission
    /// order by `publishMilestone` and `cancelAll`.
    private var waiters: [Waiter] = []

    /// Set once `cancelAll()` has been invoked. Subsequent
    /// `awaitMilestone` calls throw `CancellationError()` immediately
    /// instead of suspending — which would never be resumed once the
    /// coordinator is shutting down.
    private var cancelled: Bool = false

    public init() {}

    // MARK: - Public API

    /// Suspend until the named milestone has been reached for the named
    /// service (or has been satisfied by a prior publication of an
    /// implying milestone — see `ServiceMilestone` precedence docs).
    ///
    /// Throws `CancellationError()` if (a) the calling task is cancelled
    /// before or while waiting, or (b) `cancelAll()` has been invoked.
    public func awaitMilestone(for service: String, milestone: ServiceMilestone) async throws {
        try Task.checkCancellation()
        if cancelled {
            throw CancellationError()
        }
        if isAlreadyReached(milestone: milestone, for: service) {
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.waiters.append(
                    Waiter(
                        id: waiterID,
                        service: service,
                        milestone: milestone,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            // The cancellation closure runs OFF the actor; hop back on
            // to mutate `waiters` safely.
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    /// Mark `milestone` as reached for `service` and resume every
    /// pending waiter whose (service, milestone) is satisfied by the
    /// publication. Idempotent: republishing a milestone that's already
    /// recorded is a no-op (no continuations are double-resumed).
    public func publishMilestone(_ milestone: ServiceMilestone, for service: String) {
        if cancelled { return }
        var reached = reachedByService[service, default: []]
        let isNew = reached.insert(milestone).inserted
        guard isNew else { return }
        reachedByService[service] = reached

        // Drain in FIFO order. Two arrays so we can resume the matching
        // continuations OUTSIDE the loop that mutates `waiters` — a
        // belt-and-braces guard against re-entrancy from continuation
        // resumption (continuations resume synchronously to the
        // suspended task, but the suspended task may immediately
        // schedule more `awaitMilestone` calls).
        var toResume: [Waiter] = []
        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.service == service && satisfies(published: milestone, waited: waiter.milestone) {
                toResume.append(waiter)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        for waiter in toResume {
            waiter.continuation.resume()
        }
    }

    /// Cancel ALL pending waits with `CancellationError()` and mark the
    /// coordinator as cancelled — subsequent `awaitMilestone` calls
    /// throw `CancellationError()` immediately. Idempotent.
    ///
    /// Per UltraBrain Critical #6: call from the outer `compose up`
    /// catch block BEFORE `EmbeddedDNSSidecar.stop` or any other
    /// teardown that could race with in-flight service work.
    public func cancelAll() {
        if cancelled { return }
        cancelled = true
        let toCancel = waiters
        waiters = []
        for waiter in toCancel {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - Internal helpers

    private func cancelWaiter(id: UUID) {
        // If `release-style drain` (publishMilestone) already resumed
        // this waiter, nothing to do — the race favored publication and
        // the awaiter has already returned successfully. Per the cancel
        // contract this is acceptable: cancellation is "lost" in this
        // narrow window but the body's own `Task.checkCancellation()`
        // calls will still observe cancellation.
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let removed = waiters.remove(at: index)
        removed.continuation.resume(throwing: CancellationError())
    }

    private func isAlreadyReached(milestone: ServiceMilestone, for service: String) -> Bool {
        guard let reached = reachedByService[service] else { return false }
        return reached.contains(where: { satisfies(published: $0, waited: milestone) })
    }

    /// Per `ServiceMilestone` precedence: `started` is implied by
    /// `healthy` and `completedSuccessfully`; nothing else is implied
    /// across milestones.
    private func satisfies(published: ServiceMilestone, waited: ServiceMilestone) -> Bool {
        if published == waited { return true }
        return waited == .started && (published == .healthy || published == .completedSuccessfully)
    }

    // MARK: - Test affordances

    internal func currentWaiterCount() -> Int { waiters.count }
    internal func reachedSnapshot() -> [String: Set<ServiceMilestone>] { reachedByService }
    internal func isCancelled() -> Bool { cancelled }
}
