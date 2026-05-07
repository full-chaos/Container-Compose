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

import Testing
import Foundation
@testable import ContainerComposeCore

// MARK: - Phase 2 Task 2.5: Volume mount validation tests
//
// Design note: `ComposeUp.configVolume` is a `private mutating func` and
// cannot be directly unit-tested.  This file tests the observable behaviour
// through four complementary lenses:
//
//  1. `VolumeMountParser.parse(_:)` — the pure parser layer (fills gaps not
//     already covered by VolumeMountParserTests.swift).
//  2. `isNamedVolumeSource(_:)` — the heuristic that decides bind vs. named.
//  3. `resolvedPath(for:relativeTo:)` — path-expansion used by configVolume for
//     bind-mount source resolution (~ and relative paths).
//  4. Mode-awareness: that the parser surfaces `spec.mode != nil` so that the
//     caller's warn-skip path can fire — already pinned in VolumeMountParserTests
//     but extended here for completeness.
//
// Direct testing of the configVolume filesystem side-effects (directory creation,
// FileManager.fileExists) is intentionally deferred to Task 2.6 integration tests
// which run through `compose up` against a RecordingRuntime.  See the comment in
// VolumeMountIntegrationTests.swift for rationale.

@Suite("Volume Mount Validation")
struct VolumeMountValidationTests {

    // MARK: - Parse result completeness for common real-world specs

    @Test("Postgres data volume parses as named volume with correct destination")
    func postgresDataVolumeSpec() throws {
        let result = try VolumeMountParser.parse("pgdata:/var/lib/postgresql/data").get()
        #expect(result.kind == .namedVolume(name: "pgdata"))
        #expect(result.destination == "/var/lib/postgresql/data")
        #expect(result.mode == nil)
    }

    @Test("Redis config bind mount with absolute source")
    func redisConfigBindMount() throws {
        let result = try VolumeMountParser.parse("/etc/redis/redis.conf:/etc/redis/redis.conf").get()
        #expect(result.kind == .bindMount(hostPath: "/etc/redis/redis.conf"))
        #expect(result.destination == "/etc/redis/redis.conf")
        #expect(result.mode == nil)
    }

    @Test("Source with deep nested path segments is classified as bind mount")
    func deepNestedPathIsBind() throws {
        // A path like "data/nested/deep:/app" contains "/" so it is a bind mount.
        let result = try VolumeMountParser.parse("data/nested/deep:/app").get()
        #expect(result.kind == .bindMount(hostPath: "data/nested/deep"))
    }

    @Test("Named volume name with dots is treated as named volume (no slash)")
    func dotInNameWithoutSlashIsNamed() throws {
        // e.g. "my.volume:/data" — the dot is not a path indicator; the heuristic
        // uses slash-presence, not dot-presence.
        let result = try VolumeMountParser.parse("my.volume:/data").get()
        #expect(result.kind == .namedVolume(name: "my.volume"))
    }

    @Test("Named volume name with colon-only after source is emptyDestination error")
    func namedVolumeWithEmptyDest() {
        let result = VolumeMountParser.parse("my_volume:")
        guard case .failure(let err) = result else {
            Issue.record("Expected failure, got success")
            return
        }
        #expect(err == .emptyDestination)
    }

    @Test("Three-component spec with empty mode component normalizes mode to nil")
    func emptyModeComponentNormalizesToNil() throws {
        // "src:/dst:" — mode component present but empty.
        let result = try VolumeMountParser.parse("vol:/data:").get()
        #expect(result.mode == nil)
    }

    // MARK: - Mode variants: warn-skip surface contract

    // These tests verify that every mode string a real Compose file might carry
    // surfaces as a non-nil `.mode` on the parsed spec, so that configVolume's
    // warn-and-skip path fires correctly.

    @Test("Mode :ro is non-nil so warn-skip path fires")
    func roModeNonNil() throws {
        let result = try VolumeMountParser.parse("/host/data:/container/data:ro").get()
        #expect(result.mode == "ro", "mode must be non-nil to trigger warn-skip")
    }

    @Test("Mode :rw is non-nil so warn-skip path fires")
    func rwModeNonNil() throws {
        let result = try VolumeMountParser.parse("myvol:/data:rw").get()
        #expect(result.mode == "rw", "mode must be non-nil to trigger warn-skip")
    }

    @Test("Mode :Z (SELinux) is non-nil so warn-skip path fires")
    func zUpperModeNonNil() throws {
        let result = try VolumeMountParser.parse("/host:/container:Z").get()
        #expect(result.mode == "Z", "mode must be non-nil to trigger warn-skip")
    }

    @Test("Mode :z (SELinux shared) is non-nil so warn-skip path fires")
    func zLowerModeNonNil() throws {
        let result = try VolumeMountParser.parse("/host:/container:z").get()
        #expect(result.mode == "z", "mode must be non-nil to trigger warn-skip")
    }

    @Test("Custom mode string is captured verbatim")
    func customModeStringCaptured() throws {
        // Any unrecognized mode suffix (e.g. "shared", "private") is captured as-is.
        let result = try VolumeMountParser.parse("/host:/container:shared").get()
        #expect(result.mode == "shared")
    }

    @Test("Named volume with :ro has mode non-nil for warn-skip")
    func namedVolumeROMode() throws {
        let result = try VolumeMountParser.parse("mydata:/app/data:ro").get()
        #expect(result.kind == .namedVolume(name: "mydata"))
        #expect(result.mode == "ro")
    }

    @Test("Two-component spec has nil mode — no spurious warn-skip")
    func twoComponentSpecHasNilMode() throws {
        let result = try VolumeMountParser.parse("mydata:/app/data").get()
        #expect(result.mode == nil, "nil mode must not trigger warn-skip")
    }

    // MARK: - Path expansion: resolvedPath helper used by configVolume

    @Test("Tilde in bind-mount source expands to home directory")
    func tildeExpandsToHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = "/tmp/project"
        let resolved = resolvedPath(for: "~/data", relativeTo: base)
        #expect(resolved.hasPrefix(home), "~ must expand to home directory, got: \(resolved)")
        #expect(resolved.hasSuffix("/data"))
    }

    @Test("Relative ./data path resolves against base URL")
    func relativeDotPathResolvesAgainstBase() {
        let base = "/tmp/project"
        let resolved = resolvedPath(for: "./data", relativeTo: base)
        #expect(resolved == "/tmp/project/data")
    }

    @Test("Relative ../sibling path resolves against base URL")
    func relativeDotDotPathResolvesAgainstBase() {
        let base = "/tmp/project/compose"
        let resolved = resolvedPath(for: "../shared", relativeTo: base)
        #expect(resolved == "/tmp/project/shared")
    }

    @Test("Absolute path is returned unchanged by resolvedPath")
    func absolutePathReturnedUnchanged() {
        let base = "/tmp/project"
        let resolved = resolvedPath(for: "/var/data", relativeTo: base)
        #expect(resolved == "/var/data")
    }

    @Test("Named volume source passes isNamedVolumeSource heuristic")
    func namedVolumePassesHeuristic() {
        #expect(isNamedVolumeSource("pgdata") == true)
        #expect(isNamedVolumeSource("my-vol") == true)
        #expect(isNamedVolumeSource("db_storage") == true)
        #expect(isNamedVolumeSource("vol1") == true)
    }

    @Test("Bind mount sources fail isNamedVolumeSource heuristic")
    func bindMountSourcesFailHeuristic() {
        #expect(isNamedVolumeSource("/absolute/path") == false)
        #expect(isNamedVolumeSource("./relative") == false)
        #expect(isNamedVolumeSource("../parent") == false)
        #expect(isNamedVolumeSource("nested/path") == false)
        #expect(isNamedVolumeSource("~/home") == false)
    }

    // MARK: - Edge: originalSource is preserved exactly

    @Test("originalSource field preserves the raw source before resolution")
    func originalSourcePreservedForBind() throws {
        let result = try VolumeMountParser.parse("./config:/etc/config").get()
        #expect(result.originalSource == "./config",
                "originalSource must hold the verbatim pre-resolution string")
    }

    @Test("originalSource field preserves the named volume name exactly")
    func originalSourcePreservedForNamed() throws {
        let result = try VolumeMountParser.parse("my_volume:/data").get()
        #expect(result.originalSource == "my_volume")
    }

    // MARK: - Error cases: malformed specs

    @Test("Spec with no colon is an invalidFormat error")
    func noColonIsError() {
        let result = VolumeMountParser.parse("justdestination")
        if case .success = result {
            Issue.record("Expected .failure for spec with no colon")
        }
    }

    @Test("Spec with empty source component is emptySource error")
    func emptySourceIsEmptySourceError() {
        let result = VolumeMountParser.parse(":/container")
        guard case .failure(let err) = result else {
            Issue.record("Expected .failure")
            return
        }
        #expect(err == .emptySource)
    }

    @Test("Empty spec string returns invalidFormat error")
    func emptySpecReturnsError() {
        let result = VolumeMountParser.parse("")
        guard case .failure(let err) = result else {
            Issue.record("Expected .failure")
            return
        }
        #expect(err == .invalidFormat(spec: ""))
    }

    // MARK: - Disabled: direct configVolume filesystem-side-effect tests
    // (now covered by VolumeMountFSCheckerTests below via the extracted helper)

    @Test("Bind mount source non-existence warns and skips without mkdir (CHAOS-1438)")
    func bindMountNonExistentSourceWarnsAndSkips() async throws {
        // CHAOS-1438: previously this case auto-created a directory at the
        // host source path. The new contract is warn-and-skip with no host
        // mutation, so file-mount intent (e.g. `./init.sql`) is no longer
        // silently materialised as a directory.
        let stub = StubFS(existsResult: false, isDirectory: false)
        let result = VolumeMountFSChecker.check(
            source: "./data",
            destination: "/app/data",
            cwd: "/project",
            fileManager: stub
        )
        #expect(result == .skipMissing(source: "./data"))
    }

    @Test("Bind mount source that is a regular file is mounted (CHAOS-1438)")
    func bindMountSourceIsRegularFileMounts() async throws {
        // CHAOS-1438: apple/container 0.12.3+ supports file-source bind
        // mounts; the checker previously dropped them with a warning,
        // which broke postgres init scripts, nginx configs, certs, and
        // every other single-file Compose mount idiom.
        let stub = StubFS(existsResult: true, isDirectory: false)
        let result = VolumeMountFSChecker.check(
            source: "/etc/myconfig.conf",
            destination: "/etc/myconfig.conf",
            cwd: "/project",
            fileManager: stub
        )
        #expect(result == .mount(args: ["-v", "/etc/myconfig.conf:/etc/myconfig.conf"]))
    }
}

// MARK: - VolumeMountFSChecker unit tests (CHAOS-1410, CHAOS-1438)

/// Stub filesystem for `VolumeMountFSChecker` tests. Allows injecting canned
/// responses for `fileExists` without touching disk.
///
/// CHAOS-1438: the `createDirectory` method was removed from the checker's
/// `FSOperations` protocol because the checker no longer mutates the host
/// filesystem. The previous `createShouldSucceed` field on this stub is
/// gone for the same reason.
private final class StubFS: VolumeMountFSChecker.FSOperations {
    let existsResult: Bool
    let isDirectory: Bool

    init(existsResult: Bool, isDirectory: Bool) {
        self.existsResult = existsResult
        self.isDirectory = isDirectory
    }

    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        isDirectory?.pointee = ObjCBool(self.isDirectory)
        return existsResult
    }
}

@Suite("VolumeMountFSChecker")
struct VolumeMountFSCheckerTests {

    // MARK: - Source exists as directory

    @Test("Existing directory source returns mount args (CHAOS-1410)")
    func existingDirectoryReturnsMountArgs() {
        let stub = StubFS(existsResult: true, isDirectory: true)
        let result = VolumeMountFSChecker.check(
            source: "./data",
            destination: "/app/data",
            cwd: "/project",
            fileManager: stub
        )
        #expect(result == .mount(args: ["-v", "./data:/app/data"]))
    }

    @Test("Absolute-path source is passed through unchanged to mount args (CHAOS-1410)")
    func absolutePathSourceUnchangedInArgs() {
        let stub = StubFS(existsResult: true, isDirectory: true)
        let result = VolumeMountFSChecker.check(
            source: "/var/data",
            destination: "/app",
            cwd: "/project",
            fileManager: stub
        )
        #expect(result == .mount(args: ["-v", "/var/data:/app"]))
    }

    // MARK: - Source exists as file (CHAOS-1438)

    @Test("File source returns mount args (CHAOS-1438)")
    func fileSourceReturnsMountArgs() {
        // apple/container 0.12.3+ supports file-source bind mounts.
        // The checker emits the `-v` regardless of file-vs-directory.
        let stub = StubFS(existsResult: true, isDirectory: false)
        let result = VolumeMountFSChecker.check(
            source: "/etc/conf.d/app.conf",
            destination: "/etc/app.conf",
            cwd: "/project",
            fileManager: stub
        )
        #expect(result == .mount(args: ["-v", "/etc/conf.d/app.conf:/etc/app.conf"]))
    }

    @Test("Relative file source is passed through unchanged to mount args (CHAOS-1438)")
    func relativeFileSourceMounts() {
        // Postgres init-script idiom: ./init.sql:/docker-entrypoint-initdb.d/init.sql
        let stub = StubFS(existsResult: true, isDirectory: false)
        let result = VolumeMountFSChecker.check(
            source: "./init.sql",
            destination: "/docker-entrypoint-initdb.d/init.sql",
            cwd: "/project",
            fileManager: stub
        )
        #expect(result == .mount(args: ["-v", "./init.sql:/docker-entrypoint-initdb.d/init.sql"]))
    }

    // MARK: - Source does not exist (CHAOS-1438)

    @Test("Non-existent source returns skipMissing without mkdir (CHAOS-1438)")
    func nonExistentSourceReturnsSkipMissing() {
        // CHAOS-1438: the previous behaviour silently auto-created a
        // directory at the source path, which (a) leaked empty dirs into
        // the host workspace and (b) corrupted file-mount intent. The
        // new contract is warn-and-skip with no host mutation.
        let stub = StubFS(existsResult: false, isDirectory: false)
        let result = VolumeMountFSChecker.check(
            source: "logs",
            destination: "/app/logs",
            cwd: "/project",
            fileManager: stub
        )
        #expect(result == .skipMissing(source: "logs"))
    }

    @Test("Non-existent file-shaped source also returns skipMissing (CHAOS-1438)")
    func nonExistentFileShapedSourceReturnsSkipMissing() {
        // The exact bug from CHAOS-1438: `./init.sql` does not exist on
        // host; user expects a file mount. We must NOT mkdir; we must skip.
        let stub = StubFS(existsResult: false, isDirectory: false)
        let result = VolumeMountFSChecker.check(
            source: "./init.sql",
            destination: "/docker-entrypoint-initdb.d/init.sql",
            cwd: "/project",
            fileManager: stub
        )
        #expect(result == .skipMissing(source: "./init.sql"))
    }

    // MARK: - Path resolution: tilde prefix

    @Test("Tilde-prefixed source is used as-is (not joined to cwd) (CHAOS-1410)")
    func tildePrefixedSourceUsedAsIs() {
        let stub = StubFS(existsResult: true, isDirectory: true)
        let result = VolumeMountFSChecker.check(
            source: "~/mydata",
            destination: "/app/data",
            cwd: "/project",
            fileManager: stub
        )
        // The checker passes ~/mydata as-is to FileManager (callers expand
        // ~ via NSString.expandingTildeInPath upstream if needed).
        #expect(result == .mount(args: ["-v", "~/mydata:/app/data"]))
    }
}
