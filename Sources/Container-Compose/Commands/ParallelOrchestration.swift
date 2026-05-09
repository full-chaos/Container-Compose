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

// MARK: - ServiceTaggedError

/// Wraps a per-item error produced by a fan-out body so the offending
/// service / item key is preserved as the error propagates up out of the
/// child task.
///
/// The underlying error is rendered to a `String` at construction time so
/// the wrapper itself is `Sendable`. Swift 6.1 cannot prove arbitrary
/// `any Error` values are `Sendable`, and `any Error & Sendable`
/// existentials are awkward to thread through `withThrowingTaskGroup`'s
/// `Result.failure(_:)` payload — the rendered string sidesteps both
/// problems while preserving enough context for log output.
public struct ServiceTaggedError: Error, Sendable, LocalizedError, CustomStringConvertible {
    /// Identifier for the item / service whose body threw. Used by output
    /// reporters so the user can see *which* image failed to pull.
    public let itemKey: String

    /// Pre-rendered description of the underlying error. We render at
    /// construction time so this struct stays `Sendable` regardless of
    /// the concrete error type the body threw.
    public let underlyingDescription: String

    public init(itemKey: String, underlying: any Error) {
        self.itemKey = itemKey
        // `localizedDescription` is preferred when the inner error
        // conforms to LocalizedError; otherwise fall back to
        // `String(describing:)` which renders enums/structs uniformly.
        let nsError = underlying as NSError
        if nsError.domain != "Swift.Error" && !nsError.localizedDescription.isEmpty {
            self.underlyingDescription = nsError.localizedDescription
        } else {
            self.underlyingDescription = String(describing: underlying)
        }
    }

    public init(itemKey: String, underlyingDescription: String) {
        self.itemKey = itemKey
        self.underlyingDescription = underlyingDescription
    }

    public var description: String {
        "[\(itemKey)] \(underlyingDescription)"
    }

    public var errorDescription: String? { description }
}

// MARK: - runBoundedThrowingFanOut

/// Run `body` once per item with at most `limit` concurrent invocations.
/// Returns results in the same order as `items`.
///
/// Concurrency model:
/// - Built on `withThrowingTaskGroup` for structured concurrency: the
///   child tasks' lifetime is bounded by this function's return.
/// - Concurrency cap is enforced by `AsyncSemaphore` — every body call
///   acquires a permit before running and releases it on completion
///   (whether by return or by throw).
///
/// Cancellation / failure semantics:
/// - First failure (any body throwing) bubbles out of the
///   `for try await pair in group` loop, which drops the loop and
///   triggers `withThrowingTaskGroup`'s implicit cancel-on-exit on every
///   in-flight sibling. This is the language-level guarantee for
///   throwing task groups; we explicitly document it here so callers
///   know they get fail-fast cancellation for free.
/// - Errors are rewrapped in `ServiceTaggedError(itemKey:underlying:)`
///   unless the body already threw a `ServiceTaggedError` (which we
///   pass through to preserve the original tag).
/// - In-flight subprocess termination is NOT performed — `RunCommandRunner`
///   does not expose process kill, so cancelled children observe
///   cancellation only at their next `await` boundary. Documented as a
///   known limitation in `.sisyphus/plans/CHAOS-1446-plan.md` §Cancellation.
///
/// - Parameters:
///   - items: ordered tuples of `(key, value)`. The key tags errors and
///     drives result ordering. Keys SHOULD be unique; if duplicated,
///     ordering between duplicates is determined by their position in
///     the input array.
///   - limit: maximum concurrent in-flight body calls. Must be `>= 1`.
///   - body: per-item async work. Receives the item's key and value.
/// - Returns: an array of `(key: Key, value: T)` tuples in the same order
///   as `items`. On error, throws after siblings observe cancellation.
public func runBoundedThrowingFanOut<Key: Hashable & Sendable, Value: Sendable, T: Sendable>(
    items: [(key: Key, value: Value)],
    limit: Int,
    body: @Sendable @escaping (Key, Value) async throws -> T
) async throws -> [(key: Key, value: T)] {
    precondition(limit >= 1, "runBoundedThrowingFanOut requires limit >= 1; got \(limit)")
    if items.isEmpty { return [] }

    // Capture input order so we can re-sort the results on the way out.
    // The TaskGroup yields completions in arbitrary order, but callers
    // expect deterministic ordering matching the input.
    let inputOrder: [Key: Int] = items.enumerated().reduce(into: [:]) { acc, pair in
        acc[pair.element.key] = pair.offset
    }

    let semaphore = AsyncSemaphore(value: limit)

    return try await withThrowingTaskGroup(of: (Key, T).self) { group in
        for (key, value) in items {
            group.addTask {
                try await semaphore.withPermit {
                    do {
                        let result = try await body(key, value)
                        return (key, result)
                    } catch let alreadyTagged as ServiceTaggedError {
                        // Don't double-tag if the body already chose a
                        // more specific tag (e.g., a sub-fan-out
                        // attributed the failure to a different key).
                        throw alreadyTagged
                    } catch {
                        throw ServiceTaggedError(
                            itemKey: String(describing: key),
                            underlying: error
                        )
                    }
                }
            }
        }

        var results: [(Key, T)] = []
        results.reserveCapacity(items.count)
        for try await pair in group {
            results.append(pair)
        }

        // Re-sort to input order. Items with unknown keys (impossible in
        // the supported call patterns) sort to the end deterministically.
        results.sort { lhs, rhs in
            (inputOrder[lhs.0] ?? Int.max) < (inputOrder[rhs.0] ?? Int.max)
        }
        return results.map { (key: $0.0, value: $0.1) }
    }
}

// MARK: - String-keyed convenience

/// Convenience overload: callers operating on `[(String, V)]` (the common
/// shape for `[(serviceName, Service)]`) can call this without writing
/// out the key type. Behaves identically to the generic version.
public func runBoundedThrowingFanOut<Value: Sendable, T: Sendable>(
    items: [(serviceName: String, value: Value)],
    limit: Int,
    body: @Sendable @escaping (String, Value) async throws -> T
) async throws -> [(serviceName: String, value: T)] {
    let keyed = items.map { (key: $0.serviceName, value: $0.value) }
    let results = try await runBoundedThrowingFanOut(items: keyed, limit: limit, body: body)
    return results.map { (serviceName: $0.key, value: $0.value) }
}

// MARK: - runBoundedCollectingFanOut (non-failing variant)

/// Run `body` once per item with at most `limit` concurrent invocations,
/// returning EVERY result (success or failure) in a `[Key: Result<T, Error>]`
/// dictionary. Unlike `runBoundedThrowingFanOut`, a body throwing does NOT
/// cancel siblings — every item runs to completion and its outcome is
/// captured.
///
/// Used by `compose pull --ignore-pull-failures` and any future caller that
/// must surface a per-item outcome rather than fail-fast (CHAOS-1446 plan
/// CR-5).
///
/// Concurrency model:
/// - Built on `withTaskGroup` (NOT `withThrowingTaskGroup`) — the group
///   itself never throws, so siblings always run to completion.
/// - Bounded by `AsyncSemaphore`, identical pattern to the throwing variant.
/// - Body returns `Result<T, Error>` directly so the caller decides whether
///   a per-item failure is fatal at their layer.
///
/// Cancellation handling:
/// - If the calling task is cancelled, queued bodies that haven't yet
///   acquired a permit observe a `CancellationError` from the semaphore
///   and that error is captured as a per-item `.failure(CancellationError())`
///   in the result map.
/// - In-flight bodies that already ran (or are running) complete normally;
///   their `Task.checkCancellation()` calls — if any — surface as their own
///   `.failure(...)` outcomes.
///
/// - Parameters:
///   - items: ordered tuples of `(key, value)`. Keys SHOULD be unique; if
///     duplicated, the LAST occurrence's outcome wins in the returned
///     dictionary.
///   - limit: maximum concurrent in-flight body calls. Must be `>= 1`.
///   - body: per-item async work that returns its own `Result<T, Error>`.
///     Bodies are non-throwing — capture failures into `.failure(...)`.
/// - Returns: a dictionary keyed by item key whose values are the per-item
///   outcomes. Always contains exactly `Set(items.map(\.key)).count` entries.
public func runBoundedCollectingFanOut<Key: Hashable & Sendable, Value: Sendable, T: Sendable>(
    items: [(key: Key, value: Value)],
    limit: Int,
    body: @Sendable @escaping (Key, Value) async -> Result<T, Error>
) async -> [Key: Result<T, Error>] {
    precondition(limit >= 1, "runBoundedCollectingFanOut requires limit >= 1; got \(limit)")
    if items.isEmpty { return [:] }

    let semaphore = AsyncSemaphore(value: limit)

    return await withTaskGroup(of: (Key, Result<T, Error>).self) { group in
        for (key, value) in items {
            group.addTask {
                let outcome: Result<T, Error>
                do {
                    outcome = try await semaphore.withPermit {
                        await body(key, value)
                    }
                } catch {
                    // Semaphore acquisition was cancelled (parent task
                    // cancellation observed before a permit was available).
                    // Surface as a per-item failure so the caller can
                    // distinguish from a body-thrown failure if needed.
                    outcome = .failure(error)
                }
                return (key, outcome)
            }
        }

        var results: [Key: Result<T, Error>] = [:]
        results.reserveCapacity(items.count)
        for await pair in group {
            results[pair.0] = pair.1
        }
        return results
    }
}

/// Convenience overload: callers operating on `[(serviceName, Value)]` —
/// the common shape for `[(serviceName, Service)]` — can call this without
/// writing out the key type. Behaves identically to the generic version.
public func runBoundedCollectingFanOut<Value: Sendable, T: Sendable>(
    items: [(serviceName: String, value: Value)],
    limit: Int,
    body: @Sendable @escaping (String, Value) async -> Result<T, Error>
) async -> [String: Result<T, Error>] {
    let keyed = items.map { (key: $0.serviceName, value: $0.value) }
    return await runBoundedCollectingFanOut(items: keyed, limit: limit, body: body)
}
