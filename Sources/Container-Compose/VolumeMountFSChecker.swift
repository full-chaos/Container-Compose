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
/// emit a warning for `.skipMissing` so the user knows the mount was elided.
internal enum VolumeMountFSResult: Equatable {
    /// The host source path exists (file *or* directory). Mount it.
    ///
    /// CHAOS-1438: this case now covers both directories *and* regular files.
    /// apple/container's bind-mount parser accepts file sources verbatim
    /// (verified against apple/container 0.12.3), so single-file binds —
    /// the most common Compose pattern for init scripts, configs, certs —
    /// pass straight through.
    case mount(args: [String])

    /// The host source path does not exist. Warn-and-skip.
    ///
    /// CHAOS-1438: previously the checker silently `mkdir`'d the source path
    /// here, which (a) leaked empty directories into the host workspace
    /// without consent and (b) corrupted file-mount intent — a user asking
    /// for `./init.sql:/docker-entrypoint-initdb.d/init.sql` had `./init.sql`
    /// materialised as an empty *directory*, so postgres saw a directory
    /// where it expected a SQL file ("Is a directory" error).
    ///
    /// The new contract: `VolumeMountFSChecker` never mutates the host
    /// filesystem. apple/container surfaces a missing source as a clear
    /// runtime error; we choose the slightly softer policy of
    /// warn-and-skip-this-mount so a single bad volume entry does not abort
    /// the whole project. Users who want fail-fast can run with verbose
    /// logging or check the warning output.
    case skipMissing(source: String)
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
    /// Keeping it narrow means tests only need to stub the one method actually
    /// called, rather than the entire `FileManager` surface.
    ///
    /// CHAOS-1438: `createDirectory` was removed from this protocol because
    /// the checker no longer auto-creates host-side paths. The previous
    /// behaviour silently corrupted file mounts by materialising directories
    /// at file paths.
    ///
    /// The `fileExists` signature uses `UnsafeMutablePointer<ObjCBool>?` to
    /// match `FileManager`'s existing Objective-C–bridged method signature.
    internal protocol FSOperations {
        func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
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
            // Path exists. Both files and directories are valid bind-mount
            // sources for apple/container — emit the mount.
            //
            // CHAOS-1438: previously a regular file source was silently
            // dropped here ("does not support direct file mounts"), but
            // apple/container 0.12.3+ supports them and they are the most
            // common Compose pattern (init scripts, configs, certs).
            return .mount(args: ["-v", "\(source):\(destination)"])
        } else {
            // Source does not exist. Warn-and-skip; never mkdir.
            //
            // CHAOS-1438: the previous auto-mkdir behaviour was the actual
            // root cause of the file-mount-becomes-directory bug.
            return .skipMissing(source: source)
        }
    }
}

// MARK: - FileManager conformance

extension FileManager: VolumeMountFSChecker.FSOperations {}
