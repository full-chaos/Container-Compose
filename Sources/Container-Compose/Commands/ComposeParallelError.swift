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

// MARK: - ComposeParallelError

/// Failure cases the Phase 4 parallel `compose up` orchestration can surface
/// to the outer caller. Each case carries the offending service name so
/// fatal failure messages identify WHICH service broke without the caller
/// having to dig into a wrapped `any Error`.
///
/// `underlying` is stored as a rendered `String` (not `any Error`) to keep
/// this enum trivially `Sendable` under Swift 6.1 strict concurrency \u2014
/// `any Error & Sendable` existentials thread awkwardly through
/// `withThrowingTaskGroup`'s Result.failure payload, and the caller only
/// uses the underlying for diagnostic output anyway. Same approach as
/// `ServiceTaggedError` in `ParallelOrchestration.swift`.
public enum ComposeParallelError: Error, Sendable, LocalizedError, CustomStringConvertible {
    /// Phase A image preparation (pull or build) failed for the named
    /// service. The fan-out group cancels siblings and aborts before
    /// Phase B begins.
    case servicePreparationFailed(service: String, underlying: String)

    /// Phase B service start failed (container run argv assembly,
    /// readiness wait, IP resolution, or DNS zone refresh) for the
    /// named service. Per CHAOS-1475 MUST-FIX #2, only zone-refresh
    /// failures are fatal at the start step itself; readiness/IP errors
    /// are surfaced and the per-service work returns. This case wraps
    /// genuinely fatal start failures so the group can fail the whole
    /// invocation.
    case serviceStartFailed(service: String, underlying: String)

    /// A `depends_on` dependency for the named service failed (or was
    /// cancelled by the group's cancelAll). Carries both the dependent
    /// and the failing dependency name so the user can trace the
    /// causation chain. Only surfaces when `depends_on.required: true`
    /// (the default); `required: false` paths warn-and-continue inside
    /// `DependencyCoordinator.awaitMilestone`.
    case dependencyFailed(service: String, dependency: String, underlying: String)

    /// The service's child task observed cancellation (typically because
    /// a sibling failed and the group called `cancelAll()`). Distinct
    /// from `servicePreparationFailed` / `serviceStartFailed` so failure
    /// reports can distinguish the originating failure from the
    /// downstream cancellation cascade.
    case cancelled(service: String)

    public var description: String {
        switch self {
        case let .servicePreparationFailed(service, underlying):
            return "Image preparation failed for service '\(service)': \(underlying)"
        case let .serviceStartFailed(service, underlying):
            return "Failed to start service '\(service)': \(underlying)"
        case let .dependencyFailed(service, dependency, underlying):
            return "Service '\(service)' could not start because dependency '\(dependency)' failed: \(underlying)"
        case let .cancelled(service):
            return "Service '\(service)' was cancelled (a sibling service failed first)."
        }
    }

    public var errorDescription: String? { description }
}
