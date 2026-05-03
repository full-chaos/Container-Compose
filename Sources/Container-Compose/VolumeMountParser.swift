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

/// The kind of a volume mount derived from parsing the source field.
public enum VolumeMountKind: Equatable, Sendable {
    /// A bind mount from a host path (contains `/` or starts with `.`).
    case bindMount(hostPath: String)
    /// A registry-managed named volume (no `/` and not starting with `.`).
    case namedVolume(name: String)
    /// An in-memory tmpfs mount (empty source field).
    case tmpfs
}

/// A fully-parsed description of one `service.volumes` entry.
public struct VolumeMountSpec: Equatable, Sendable {
    /// The resolved kind of this mount.
    public let kind: VolumeMountKind
    /// The destination path inside the container.
    public let destination: String
    /// The optional mode suffix (e.g. `"ro"`, `"rw"`, `"Z"`, `"z"`).
    /// `nil` when no mode was specified.
    public let mode: String?
    /// The raw source string as it appeared in the compose volume entry
    /// (before filesystem resolution or named-volume lookup).
    public let originalSource: String
}

/// Errors that `VolumeMountParser.parse(_:)` can return.
public enum VolumeMountParseError: Error, Equatable, Sendable {
    /// The spec string does not contain the required `source:destination` separator.
    case invalidFormat(spec: String)
    /// The source component of the spec is empty.
    case emptySource
    /// The destination component of the spec is empty.
    case emptyDestination
}

/// Pure string parser for Docker Compose `service.volumes` short-form entries.
///
/// Accepted format: `source:destination[:mode]`
///
/// - `source` is the host path or named-volume name.
/// - `destination` is the absolute path inside the container.
/// - `mode` is an optional access modifier such as `ro`, `rw`, `Z`, or `z`.
///
/// This struct is intentionally **side-effect-free**: it never touches the
/// filesystem, spawns tasks, or consults the named-volume registry.
/// Runtime concerns (path creation, volume preparation) remain in the caller.
///
/// Kind detection delegates to `isNamedVolumeSource(_:)` — the canonical
/// heuristic in `Helper Functions.swift` — so the two code paths stay
/// in sync.
public struct VolumeMountParser {

    private init() {}

    /// Parse a compose volume spec string into a `VolumeMountSpec`.
    ///
    /// - Parameter spec: A volume string such as `"./data:/app/data"`,
    ///   `"myvolume:/var/lib/data:ro"`, or `"/host/path:/container/path:Z"`.
    /// - Returns: `.success(VolumeMountSpec)` on success,
    ///   `.failure(VolumeMountParseError)` when the string is malformed.
    public static func parse(_ spec: String) -> Result<VolumeMountSpec, VolumeMountParseError> {
        // Split into at most 3 components: source, destination, optional mode.
        // Using maxSplits: 2 ensures a mode component that itself contains ":"
        // (not valid in practice, but safe) does not get lost.
        let components = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)

        guard components.count >= 2 else {
            return .failure(.invalidFormat(spec: spec))
        }

        let source = components[0]
        let destination = components[1]
        let mode: String? = components.count == 3 ? components[2] : nil

        guard !source.isEmpty else {
            return .failure(.emptySource)
        }

        guard !destination.isEmpty else {
            return .failure(.emptyDestination)
        }

        let kind: VolumeMountKind
        if isNamedVolumeSource(source) {
            kind = .namedVolume(name: source)
        } else {
            kind = .bindMount(hostPath: source)
        }

        // Normalize an empty mode component (e.g. "src:/dst:") to nil.
        let normalizedMode: String? = mode.flatMap { $0.isEmpty ? nil : $0 }

        return .success(VolumeMountSpec(
            kind: kind,
            destination: destination,
            mode: normalizedMode,
            originalSource: source
        ))
    }
}
