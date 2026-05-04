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

/// The result of `VolumeMountFSChecker.check(_:destination:cwd:)`.
///
/// Callers turn `.mount` results into `-v source:destination` arguments and
/// emit the messages in `.skip` / `.created` results to the user.
internal enum VolumeMountFSResult: Equatable {
    /// The source directory exists (or was just created). Mount it.
    case mount(args: [String])
    /// The source path is a regular file, not a directory. Skip.
    case skipFile(source: String)
    /// The source path did not exist and directory creation failed. Skip.
    case skipCreateError(fullHostPath: String, underlyingError: String)
    /// The source path did not exist but was created successfully. Mount it.
    case created(fullHostPath: String, args: [String])
}

/// Pure filesystem-checking logic extracted from `ComposeUp.configVolume`'s
/// bind-mount branch.
///
/// This struct is `internal` so `@testable import ContainerComposeCore` in
/// unit tests can reach it without making it part of the public API.
/// `ComposeUp.configVolume` delegates to this struct so the same logic is
/// tested at both the unit level and through the full command integration path.
///
/// **Design note:** `VolumeMountFSChecker` accepts a `FileManager`-like
/// protocol so unit tests can inject a stub without touching real disk.
/// The default `fileManager` argument is `FileManager.default` so callers
/// in production do not need to pass anything extra.
internal struct VolumeMountFSChecker {

    // MARK: - FileManager abstraction

    /// Minimal interface over `FileManager` operations used by the checker.
    /// Keeping it narrow means tests only need to stub the two methods actually
    /// called, rather than the entire `FileManager` surface.
    ///
    /// The `fileExists` signature uses `UnsafeMutablePointer<ObjCBool>?` to
    /// match `FileManager`'s existing Objective-C–bridged method signature.
    internal protocol FSOperations {
        func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
        func createDirectory(atPath path: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws
    }

    // MARK: - Core check

    /// Inspect the bind-mount `source` on disk relative to `cwd` and return
    /// a `VolumeMountFSResult` that describes what the caller should do.
    ///
    /// - Parameters:
    ///   - source: The raw source string from the compose volume entry
    ///     (may be absolute, `~`-prefixed, or relative).
    ///   - destination: The absolute path inside the container.
    ///   - cwd: The project directory used to resolve relative source paths.
    ///   - fileManager: Filesystem operations provider (defaults to `FileManager.default`).
    /// - Returns: A `VolumeMountFSResult` indicating what to do with this mount.
    internal static func check(
        source: String,
        destination: String,
        cwd: String,
        fileManager: any FSOperations = FileManager.default
    ) -> VolumeMountFSResult {
        // Resolve the full host path: absolute / tilde paths are used as-is;
        // relative paths are joined to cwd, matching ComposeUp.configVolume's
        // own inline logic.
        let fullHostPath: String
        if source.starts(with: "/") || source.starts(with: "~") {
            fullHostPath = source
        } else {
            fullHostPath = cwd + "/" + source
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: fullHostPath, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                // Path exists and is a directory: mount it.
                return .mount(args: ["-v", "\(source):\(destination)"])
            } else {
                // Path exists but is a regular file: warn+skip.
                return .skipFile(source: source)
            }
        } else {
            // Path does not exist: try to create it as a directory.
            do {
                try fileManager.createDirectory(
                    atPath: fullHostPath,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                return .created(fullHostPath: fullHostPath, args: ["-v", "\(source):\(destination)"])
            } catch {
                return .skipCreateError(fullHostPath: fullHostPath, underlyingError: error.localizedDescription)
            }
        }
    }
}

// MARK: - FileManager conformance

extension FileManager: VolumeMountFSChecker.FSOperations {}
