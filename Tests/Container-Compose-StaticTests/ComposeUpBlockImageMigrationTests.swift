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
import Testing
@testable import ContainerComposeCore
import TestHelpers

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Regression coverage for CHAOS-1418: `migrateLegacyNamedVolumeDataIfNeeded`
/// crashed with `NSFileWriteFileExistsError` (NSCocoaError 516) when the runtime
/// volume source was a block-image `.img` file. After CHAOS-1368, `inspect`
/// returns the `.img` file path rather than the parent directory; calling
/// `createDirectory(atPath:)` on an existing file path throws this error.
///
/// Fix: detect the `.img` suffix, emit a warning explaining manual steps,
/// write the migration marker so the next `up` skips immediately, and return.
///
/// Test strategy: use the `CONTAINER_COMPOSE_TEST_NAMED_VOLUME_SOURCE` override
/// to inject a controlled source path; create the legacy fallback directory and
/// marker directory under `URL.homeDirectory` using a UUID-namespaced project
/// name so tests never collide with real data or each other.
@Suite("ComposeUp block-image migration guard (CHAOS-1418)", .serialized)
struct ComposeUpBlockImageMigrationTests {

    // MARK: - Test 1: block-image source → skip + marker + warning

    @Test("block-image source skips merge, writes marker, emits warning to stderr")
    func blockImageSourceSkipsMigration() async throws {
        let (projectName, volumeName) = uniqueNames()
        let legacyPath = legacyPath(project: projectName, volume: volumeName)
        let markerURL = markerURL(project: projectName, volume: volumeName)

        // Create the legacy directory so the guard passes.
        try FileManager.default.createDirectory(atPath: legacyPath, withIntermediateDirectories: true)
        defer { cleanup(legacyPath: legacyPath, markerURL: markerURL) }

        // Create a temporary .img file as the "runtime volume source".
        let imgFile = FileManager.default.temporaryDirectory
            .appending(path: "chaos-1418-\(UUID().uuidString).img")
        try Data().write(to: imgFile)
        defer { try? FileManager.default.removeItem(at: imgFile) }

        let captured = try await capturingStderr {
            try await withEnv(ComposeUp.testNamedVolumeSourceOverrideEnv, value: imgFile.path) {
                var cmd = ComposeUp()
                try await cmd.migrateLegacyNamedVolumeDataIfNeeded(
                    projectName: projectName,
                    actualVolumeName: volumeName
                )
            }
        }

        // Warning must be emitted.
        #expect(captured.contains("Warning"),
                "stderr must contain 'Warning'; got: \(captured)")
        #expect(captured.contains("block-image"),
                "warning must mention block-image; got: \(captured)")
        #expect(captured.contains(legacyPath),
                "warning must include the legacy path; got: \(captured)")
        #expect(captured.contains(volumeName),
                "warning must include the volume name; got: \(captured)")
        #expect(captured.contains("manually"),
                "warning must suggest manual action; got: \(captured)")

        // Marker must be written with the skip sentinel.
        let markerContent = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(markerContent == "migration-skipped-block-image",
                "marker content must be 'migration-skipped-block-image'; got: \(markerContent)")

        // Legacy directory must NOT have been touched (no merge attempted).
        let legacyContents = try FileManager.default.contentsOfDirectory(atPath: legacyPath)
        #expect(legacyContents.isEmpty,
                "legacy directory must be untouched — no files copied; got: \(legacyContents)")
    }

    // MARK: - Test 2: directory source → existing merge behavior preserved

    @Test("directory source performs merge and writes migrated marker")
    func directorySourceMergesContents() async throws {
        let (projectName, volumeName) = uniqueNames()
        let legacyPath = legacyPath(project: projectName, volume: volumeName)
        let markerURL = markerURL(project: projectName, volume: volumeName)

        // Legacy dir with sample content.
        try FileManager.default.createDirectory(atPath: legacyPath, withIntermediateDirectories: true)
        let sampleFile = URL(fileURLWithPath: legacyPath).appending(path: "data.txt")
        try "hello".write(to: sampleFile, atomically: true, encoding: .utf8)

        // Destination directory acting as the "runtime volume source".
        let destDir = FileManager.default.temporaryDirectory
            .appending(path: "chaos-1418-dest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            cleanup(legacyPath: legacyPath, markerURL: markerURL)
            try? FileManager.default.removeItem(at: destDir)
        }

        try await withEnv(ComposeUp.testNamedVolumeSourceOverrideEnv, value: destDir.path) {
            var cmd = ComposeUp()
            try await cmd.migrateLegacyNamedVolumeDataIfNeeded(
                projectName: projectName,
                actualVolumeName: volumeName
            )
        }

        // The merged file must now exist in the destination.
        let mergedPath = destDir.appending(path: "data.txt").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: mergedPath),
                "data.txt must be copied into the destination dir; dest=\(destDir.path)")

        // Marker must be written with the success sentinel.
        let markerContent = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(markerContent == "migrated",
                "marker content must be 'migrated' for a successful directory merge; got: \(markerContent)")
    }

    // MARK: - Test 3: marker present → early return

    @Test("marker present causes early return — no warning, no merge, no createDirectory")
    func markerPresentEarlyReturn() async throws {
        let (projectName, volumeName) = uniqueNames()
        let legacyPath = legacyPath(project: projectName, volume: volumeName)
        let markerURL = markerURL(project: projectName, volume: volumeName)

        // Create the legacy directory.
        try FileManager.default.createDirectory(atPath: legacyPath, withIntermediateDirectories: true)
        try "some-legacy-file".write(
            to: URL(fileURLWithPath: legacyPath).appending(path: "old.txt"),
            atomically: true, encoding: .utf8
        )

        // Pre-write the marker (simulates a previous successful or skipped migration).
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "migration-skipped-block-image".write(to: markerURL, atomically: true, encoding: .utf8)
        defer { cleanup(legacyPath: legacyPath, markerURL: markerURL) }

        // Point env at a sentinel .img path to catch any accidental merge.
        let sentinelPath = "/tmp/should-not-be-touched-\(UUID().uuidString).img"

        let captured = try await capturingStderr {
            try await withEnv(ComposeUp.testNamedVolumeSourceOverrideEnv, value: sentinelPath) {
                var cmd = ComposeUp()
                try await cmd.migrateLegacyNamedVolumeDataIfNeeded(
                    projectName: projectName,
                    actualVolumeName: volumeName
                )
            }
        }

        // No warning must be emitted — early return before reaching any output.
        #expect(!captured.contains("Warning"),
                "early-return path must emit no warning; got: \(captured)")

        // Sentinel file must not exist (no createDirectory or copyItem called).
        #expect(!FileManager.default.fileExists(atPath: sentinelPath),
                "sentinel file must not have been created; marker early-return failed")

        // Marker content must be unchanged.
        let markerContent = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(markerContent == "migration-skipped-block-image",
                "marker must not be overwritten; got: \(markerContent)")
    }

    // MARK: - Test 4: missing legacy fallback → early return

    @Test("missing legacy fallback causes early return — no side effects")
    func missingLegacyFallbackEarlyReturn() async throws {
        let (projectName, volumeName) = uniqueNames()
        let legacyPath = legacyPath(project: projectName, volume: volumeName)
        let markerURL = markerURL(project: projectName, volume: volumeName)

        // Do NOT create the legacy directory — it simply doesn't exist.
        #expect(!FileManager.default.fileExists(atPath: legacyPath),
                "precondition: legacy dir must not exist")

        let sentinelPath = "/tmp/should-not-be-touched-\(UUID().uuidString).img"

        let captured = try await capturingStderr {
            try await withEnv(ComposeUp.testNamedVolumeSourceOverrideEnv, value: sentinelPath) {
                var cmd = ComposeUp()
                try await cmd.migrateLegacyNamedVolumeDataIfNeeded(
                    projectName: projectName,
                    actualVolumeName: volumeName
                )
            }
        }

        // No marker or sentinel file; the captured stderr may include unrelated
        // parallel test-run progress, so we only validate side effects here.
        #expect(!FileManager.default.fileExists(atPath: markerURL.path(percentEncoded: false)),
                "marker must not be written when legacy path is absent")
        #expect(!FileManager.default.fileExists(atPath: sentinelPath),
                "sentinel file must not have been created")
    }

    // MARK: - Helpers

    /// Generates a unique (projectName, volumeName) pair backed by a UUID
    /// so tests never collide with each other or with real home-dir data.
    private func uniqueNames() -> (project: String, volume: String) {
        let id = UUID().uuidString.lowercased()
        return ("chaos1418-\(id)", "vol-\(id)")
    }

    /// Mirrors `ComposeUp.legacyVolumeFallbackPath` — kept in sync by inspection.
    private func legacyPath(project: String, volume: String) -> String {
        URL.homeDirectory
            .appending(path: ".containers/Volumes/\(project)/\(volume)")
            .path(percentEncoded: false)
    }

    /// Mirrors `ComposeUp.migrationMarkerURL` — kept in sync by inspection.
    private func markerURL(project: String, volume: String) -> URL {
        URL.homeDirectory
            .appending(path: ".container-compose/volume-migrations")
            .appending(path: "\(project)--\(volume).migrated")
    }

    /// Removes the legacy dir and marker written during a test.
    private func cleanup(legacyPath: String, markerURL: URL) {
        try? FileManager.default.removeItem(atPath: legacyPath)
        try? FileManager.default.removeItem(at: markerURL)
        // Best-effort cleanup of the UUID-namespaced project dir under .containers/Volumes/
        let projectDir = URL(fileURLWithPath: legacyPath).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: projectDir)
    }

    /// Runs `block` with `key` set to `value` in the process environment,
    /// restoring the previous value on exit.
    private func withEnv(_ key: String, value: String, _ block: () async throws -> Void) async throws {
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, value, 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        try await block()
    }

    /// Captures stderr for the duration of `block` by `dup2`-ing a pipe over
    /// `STDERR_FILENO`. `writeWarningToStandardError` writes to FileHandle.standardError,
    /// which flushes immediately, so no extra fflush is needed.
    private func capturingStderr(_ block: () async throws -> Void) async throws -> String {
        try await CapturedOutput.acquire()
        defer { CapturedOutput.releaseFireAndForget() }
        let original = dup(STDERR_FILENO)
        let pipe = Pipe()
        guard original >= 0,
              dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0
        else {
            if original >= 0 { close(original) }
            throw CaptureError.dupFailed
        }
        let reader = Task {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }
        defer {
            _ = dup2(original, STDERR_FILENO)
            close(original)
        }
        try await block()
        _ = dup2(original, STDERR_FILENO)
        pipe.fileHandleForWriting.closeFile()
        let data = await reader.value
        return String(data: data, encoding: .utf8) ?? ""
    }

    private enum CaptureError: Error { case dupFailed }
}
