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
import Logging
import ServiceLifecycle

// MARK: - ServiceLivenessRegistry

/// Thread-safe set of service names currently inside their `run()` body.
///
/// Populated by `ShutdownTrackedService` and read by `ShutdownWatchdogService`.
/// `NSLock` (rather than an actor) keeps `markStarted` / `markStopped`
/// synchronous so the decorator can place them around `try await wrapped.run()`
/// without leaking `async` into the wrapped service's signature.
final class ServiceLivenessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var aliveServices: Set<String> = []

    func markStarted(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        aliveServices.insert(name)
    }

    func markStopped(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        aliveServices.remove(name)
    }

    /// Snapshot of currently-alive service names, sorted for deterministic
    /// log output.
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return aliveServices.sorted()
    }
}

// MARK: - ShutdownTrackedService

/// Decorator that records its wrapped service's liveness in a shared
/// `ServiceLivenessRegistry`. Used so the watchdog can name the wedged
/// service when shutdown stalls.
struct ShutdownTrackedService<Wrapped: ServiceLifecycle.Service>: ServiceLifecycle.Service {
    let name: String
    let registry: ServiceLivenessRegistry
    let wrapped: Wrapped

    init(name: String, registry: ServiceLivenessRegistry, wrapped: Wrapped) {
        self.name = name
        self.registry = registry
        self.wrapped = wrapped
    }

    func run() async throws {
        registry.markStarted(name)
        defer { registry.markStopped(name) }
        try await wrapped.run()
    }
}

// MARK: - ShutdownWatchdogService

/// Diagnostic watchdog for CHAOS-1423. Once shutdown is signaled, fires a
/// `Task.detached` that — after `stallThreshold` elapses — logs which
/// tracked services are still inside `run()`.
///
/// **Why detached?** When `ServiceGroup` escalates from graceful drain to
/// task cancellation (and ultimately to `fatalError` after
/// `maximumCancellationDuration`), structured child tasks die with the
/// wedged parent. A detached task is independent of the group's task tree,
/// so the diagnostic log is guaranteed to fire even when the process is
/// about to be force-killed.
///
/// **Cost of being detached.** On a *clean* shutdown (where the group
/// drains before the threshold elapses) the detached task still sleeps
/// the full `stallThreshold` before checking the registry. Holding the
/// registry + logger references for ~5s extra is cheap, and the
/// `guard !alive.isEmpty` keeps the log silent — accepted as the price
/// of guaranteed-fire diagnostics on the wedged path.
///
/// **Idempotent.** Both `onGracefulShutdown` (SIGTERM/SIGINT path) and
/// `onCancel` (SIGQUIT / escalation path) call `spawnIfFirst()`, but only
/// the first invocation actually spawns. This keeps log output to one
/// `shutdown_stalled` entry per shutdown sequence.
final class ShutdownWatchdogService: ServiceLifecycle.Service, @unchecked Sendable {
    let registry: ServiceLivenessRegistry
    let logger: Logger
    let stallThreshold: Duration

    private let lock = NSLock()
    private var spawned = false

    init(
        registry: ServiceLivenessRegistry,
        logger: Logger,
        stallThreshold: Duration = .seconds(5)
    ) {
        self.registry = registry
        self.logger = logger
        self.stallThreshold = stallThreshold
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withGracefulShutdownHandler {
                // Sleep until the group cancels us. Mirrors SocketCleanupService.
                try await Task.sleep(for: .seconds(60 * 60 * 24 * 365 * 100))
            } onGracefulShutdown: {
                self.spawnIfFirst()
            }
        } onCancel: {
            self.spawnIfFirst()
        }
    }

    /// Test hook: returns `true` iff the detached watchdog has been spawned
    /// for the current shutdown sequence.
    var hasSpawned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return spawned
    }

    /// Internal so tests can drive the SIGTERM-then-escalate sequence
    /// directly without spinning a real `ServiceGroup`. Idempotency contract:
    /// at most one `Task.detached` is spawned per shutdown sequence, even if
    /// both `onGracefulShutdown` and `onCancel` fire (the normal SIGTERM →
    /// 10s grace → escalate-to-cancel path).
    func spawnIfFirst() {
        lock.lock()
        let alreadySpawned = spawned
        spawned = true
        lock.unlock()
        guard !alreadySpawned else { return }

        let registry = self.registry
        let logger = self.logger
        let threshold = self.stallThreshold
        Task.detached {
            try? await Task.sleep(for: threshold)
            let alive = registry.snapshot()
            guard !alive.isEmpty else { return }
            logger.warning(
                "shutdown_stalled",
                metadata: [
                    "alive_services": .array(alive.map { .string($0) }),
                    "stall_threshold": "\(threshold)",
                ]
            )
        }
    }
}
