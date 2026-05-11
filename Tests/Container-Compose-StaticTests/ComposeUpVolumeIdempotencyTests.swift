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

/// Regression coverage for CHAOS-1398: re-running `compose up` on a project with
/// existing named volumes must NOT re-attempt creation. apple/container's
/// `ClientVolume.create` writes a `volume.img` file and surfaces a Foundation
/// NSCocoaErrorDomain error ("file with the same name already exists") when
/// that file already exists. That error doesn't match
/// `RuntimeError.alreadyExists` and propagates out as an unhandled error, so
/// `up` fails on the second run with a confusing filesystem-level message.
///
/// Fix: pass a pre-loaded registry volume into the create path and skip the
/// create call entirely when the volume already exists. The existing
/// `RuntimeError.alreadyExists` catch stays as a race-condition backstop.
@Suite("ComposeUp volume idempotency (CHAOS-1398)", .serialized)
struct ComposeUpVolumeIdempotencyTests {

    @Test("ensureNamedVolumeRegistered skips create when volume already exists")
    func skipsCreateWhenVolumeExists() async throws {
        let runtime = RecordingRuntime()

        let didCreate = try await RuntimeEnvironment.$current.withValue(runtime) {
            try await ComposeUp.ensureNamedVolumeRegistered(
                spec: RuntimeCreateVolumeSpec(name: "postgres_data"),
                existing: RuntimeVolume(name: "postgres_data")
            )
        }

        #expect(didCreate == false)
        let entries = await runtime.entriesSnapshot()
        let calledCreate = entries.contains(where: {
            if case .createVolume = $0 { return true }
            return false
        })
        #expect(!calledCreate, "must NOT call createVolume when volume already in registry; got \(entries)")
    }

    @Test("ensureNamedVolumeRegistered creates volume when not present")
    func createsVolumeWhenNotPresent() async throws {
        let runtime = RecordingRuntime()

        let didCreate = try await RuntimeEnvironment.$current.withValue(runtime) {
            try await ComposeUp.ensureNamedVolumeRegistered(
                spec: RuntimeCreateVolumeSpec(name: "fresh_data"),
                existing: nil
            )
        }

        #expect(didCreate == true)
        let entries = await runtime.entriesSnapshot()
        #expect(entries == [.createVolume(name: "fresh_data")])
    }

    @Test("ensureNamedVolumeRegistered tolerates alreadyExists race")
    func toleratesAlreadyExistsRace() async throws {
        // MockRuntime throws .alreadyExists when a volume with that name is already in
        // its in-memory registry. existing is nil (simulating "we listed the registry
        // before someone else snuck a create in"), so we go through the create branch
        // and rely on the catch to swallow the race.
        let runtime = MockRuntime(volumes: [RuntimeVolume(name: "racy")])

        let didCreate = try await RuntimeEnvironment.$current.withValue(runtime) {
            try await ComposeUp.ensureNamedVolumeRegistered(
                spec: RuntimeCreateVolumeSpec(name: "racy"),
                existing: nil
            )
        }

        #expect(didCreate == false)
    }

    @Test("ensureNamedVolumeRegistered prints stale-volume warning when volume already exists")
    func warnsWhenVolumeExists() async throws {
        let runtime = RecordingRuntime()

        let captured = try await Self.capturingStdout {
            _ = try await RuntimeEnvironment.$current.withValue(runtime) {
                try await ComposeUp.ensureNamedVolumeRegistered(
                    spec: RuntimeCreateVolumeSpec(name: "postgres_data"),
                    existing: RuntimeVolume(name: "postgres_data")
                )
            }
        }

        #expect(captured.contains("named volume 'postgres_data' already exists"),
                "expected stale-volume warning to mention the volume name; got: \(captured)")
        #expect(captured.contains("compose down -v"),
                "expected warning to point users at the recovery command; got: \(captured)")
    }

    @Test("ensureNamedVolumeRegistered does NOT print stale-volume warning on fresh create")
    func silentOnFreshCreate() async throws {
        let runtime = RecordingRuntime()

        let captured = try await Self.capturingStdout {
            _ = try await RuntimeEnvironment.$current.withValue(runtime) {
                try await ComposeUp.ensureNamedVolumeRegistered(
                    spec: RuntimeCreateVolumeSpec(name: "fresh_data"),
                    existing: nil
                )
            }
        }

        #expect(!captured.contains("already exists"),
                "fresh create must not emit stale-volume warning; got: \(captured)")
    }

    @Test("ensureNamedVolumeRegistered warns on driver drift")
    func warnsOnDriverDrift() async throws {
        let runtime = RecordingRuntime()

        let captured = try await Self.capturingStdout {
            _ = try await RuntimeEnvironment.$current.withValue(runtime) {
                try await ComposeUp.ensureNamedVolumeRegistered(
                    spec: RuntimeCreateVolumeSpec(name: "x", driver: "local"),
                    existing: RuntimeVolume(name: "x", driver: "nfs")
                )
            }
        }

        #expect(captured.contains("different config"), "expected drift warning; got: \(captured)")
        #expect(captured.contains("driver"), "expected driver field in warning; got: \(captured)")
        #expect(captured.contains("registry='nfs'"), "expected registry driver; got: \(captured)")
        #expect(captured.contains("compose='local'"), "expected compose driver; got: \(captured)")
        #expect(!captured.contains("was not torn down"), "drift warning must replace stale-reuse warning; got: \(captured)")
    }

    @Test("ensureNamedVolumeRegistered warns on labels drift")
    func warnsOnLabelsDrift() async throws {
        let runtime = RecordingRuntime()

        let captured = try await Self.capturingStdout {
            _ = try await RuntimeEnvironment.$current.withValue(runtime) {
                try await ComposeUp.ensureNamedVolumeRegistered(
                    spec: RuntimeCreateVolumeSpec(name: "x", driver: "local", labels: ["env": "production"]),
                    existing: RuntimeVolume(name: "x", driver: "local", labels: ["env": "staging"])
                )
            }
        }

        #expect(captured.contains("different config"), "expected drift warning; got: \(captured)")
        #expect(captured.contains("labels"), "expected labels field in warning; got: \(captured)")
        #expect(captured.contains("staging"), "expected registry label value; got: \(captured)")
        #expect(captured.contains("production"), "expected compose label value; got: \(captured)")
        #expect(!captured.contains("was not torn down"), "drift warning must replace stale-reuse warning; got: \(captured)")
    }

    @Test("ensureNamedVolumeRegistered emits stale warning when config matches")
    func noDriftWhenConfigMatches() async throws {
        let runtime = RecordingRuntime()

        let captured = try await Self.capturingStdout {
            _ = try await RuntimeEnvironment.$current.withValue(runtime) {
                try await ComposeUp.ensureNamedVolumeRegistered(
                    spec: RuntimeCreateVolumeSpec(name: "x", driver: "local", labels: [:]),
                    existing: RuntimeVolume(name: "x", driver: "local", labels: [:])
                )
            }
        }

        #expect(captured.contains("already exists from a previous run"), "expected stale-reuse warning; got: \(captured)")
        #expect(captured.contains("compose down -v"), "expected recovery command; got: \(captured)")
        #expect(!captured.contains("different config"), "matching config must not emit drift warning; got: \(captured)")
    }

    /// Captures stdout for the duration of `block` by `dup2`-ing a pipe over
    /// `STDOUT_FILENO`. Mirrors the established pattern in `LifecycleArgsTests`.
    private static func capturingStdout(_ block: () async throws -> Void) async throws -> String {
        try await CapturedOutput.acquire()
        defer { CapturedOutput.releaseFireAndForget() }
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        let pipe = Pipe()
        guard original >= 0,
              dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0
        else {
            if original >= 0 { close(original) }
            throw CaptureError.dupFailed
        }
        let reader = Task {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }
        defer {
            _ = dup2(original, STDOUT_FILENO)
            close(original)
        }
        try await block()
        fflush(stdout)
        _ = dup2(original, STDOUT_FILENO)
        pipe.fileHandleForWriting.closeFile()
        let data = await reader.value
        return String(data: data, encoding: .utf8) ?? ""
    }

    private enum CaptureError: Error { case dupFailed }
}
