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
@preconcurrency import Rainbow

// MARK: - OutputCoordinator

/// Actor-isolated print coordinator for the parallel-orchestration era
/// (CHAOS-1446 Phase 1).
///
/// Two responsibilities:
///
/// 1. **Per-service color assignment.** Mirrors the
///    `availableContainerConsoleColors` palette currently inlined in
///    `ComposeUp.launchService` (and duplicated in `ComposeTop` /
///    `ComposeLogs`). Phase 4 will swap the inline color picker in
///    `ComposeUp` for `await coordinator.color(for: serviceName)` so a
///    single source of truth governs which color a service renders in.
///
/// 2. **Serialized output.** `phase`, `info`, and `line` write to stdout
///    while holding actor isolation, preventing concurrent service tasks
///    from interleaving partial lines with each other or with banner
///    text.
///
/// Phase 1 ships this actor unwired — `ComposeUp` continues to use its
/// inline color picker so this phase is purely additive (NO command
/// behavior change). Phase 4 wires it in.
///
/// Sendability:
/// - `NamedColor` is `Rainbow`'s color enum, imported with
///   `@preconcurrency` to suppress the missing-Sendable warning. It is
///   a value type (RawRepresentable Int) and is safe to store/return
///   from actor-isolated code.
public actor OutputCoordinator {

    // MARK: - Palette

    /// Console colors used for per-service output. Identical (in content
    /// and order) to `ComposeUp.availableContainerConsoleColors`. Kept as
    /// an array (not a `Set`) because `Set` iteration order is
    /// non-deterministic — and we want first-pick behaviour to be
    /// reproducible across runs for log-comparing humans.
    public static let availableConsoleColors: [NamedColor] = [
        .blue,
        .cyan,
        .magenta,
        .lightBlack,
        .lightBlue,
        .lightCyan,
        .lightYellow,
        .yellow,
        .lightGreen,
        .green,
    ]

    // MARK: - State

    /// Persistent service → color assignments. Once a service receives a
    /// color via `color(for:)`, it keeps that color for the lifetime of
    /// this coordinator.
    private var assignments: [String: NamedColor] = [:]

    public init() {}

    // MARK: - Color assignment

    /// Return the color assigned to `serviceName`. On first request,
    /// allocates the first palette color not yet in use; if every color
    /// is already taken, falls back to a random pick (matching the
    /// pre-existing `ComposeUp.launchService` behavior of accepting
    /// duplicates once we run out of unique colors).
    public func color(for serviceName: String) -> NamedColor {
        if let existing = assignments[serviceName] {
            return existing
        }

        let palette = Self.availableConsoleColors
        let used = Set(assignments.values)
        let next = palette.first(where: { !used.contains($0) })
            ?? palette.randomElement()
            ?? .white

        assignments[serviceName] = next
        return next
    }

    // MARK: - Print routines

    /// Emit a phase banner (e.g. `"--- Processing Services ---"`).
    /// Banners print uncolored to stdout under actor isolation so they
    /// cannot interleave with concurrent per-service output.
    public func phase(_ message: String) {
        print(message)
    }

    /// Emit an info line scoped to a single service. The line is
    /// prefixed `"[serviceName] "` and rendered in the service's color.
    public func info(service serviceName: String, _ message: String) {
        let color = color(for: serviceName)
        print("[\(serviceName)] \(message)".applyingColor(color))
    }

    /// Emit a pre-formatted line scoped to a single service, applying
    /// the service's color. Use when the caller has already constructed
    /// the full text (including any prefix) and just needs colorization
    /// + serialization. The pre-existing `ComposeUp.launchService`
    /// stdout/stderr stream handler builds lines as `"\(serviceName): …"`
    /// and applies color directly; Phase 4 may refactor that handler to
    /// route through this method.
    public func line(service serviceName: String, _ message: String) {
        let color = color(for: serviceName)
        print(message.applyingColor(color))
    }

    /// Emit an uncolored, unprefixed line under actor isolation. Useful
    /// for warnings/errors where the caller has assembled their own
    /// formatting and just needs serialization with peer output.
    public func raw(_ message: String) {
        print(message)
    }

    // MARK: - Test affordances

    /// Snapshot of current per-service color assignments. Test-only.
    internal func currentAssignments() -> [String: NamedColor] { assignments }
}
