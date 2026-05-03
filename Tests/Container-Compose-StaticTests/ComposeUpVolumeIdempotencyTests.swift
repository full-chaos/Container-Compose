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

/// Regression coverage for CHAOS-1398: re-running `compose up` on a project with
/// existing named volumes must NOT re-attempt creation. apple/container's
/// `ClientVolume.create` writes a `volume.img` file and surfaces a Foundation
/// NSCocoaErrorDomain error ("file with the same name already exists") when
/// that file already exists. That error doesn't match
/// `RuntimeError.alreadyExists` and propagates out as an unhandled error, so
/// `up` fails on the second run with a confusing filesystem-level message.
///
/// Fix: pass a pre-loaded set of registry volume names into the create path
/// and skip the create call entirely when the volume already exists. The
/// existing `RuntimeError.alreadyExists` catch stays as a race-condition
/// backstop.
@Suite("ComposeUp volume idempotency (CHAOS-1398)")
struct ComposeUpVolumeIdempotencyTests {

    @Test("ensureNamedVolumeRegistered skips create when volume already exists")
    func skipsCreateWhenVolumeExists() async throws {
        let runtime = RecordingRuntime()

        let didCreate = try await RuntimeEnvironment.$current.withValue(runtime) {
            try await ComposeUp.ensureNamedVolumeRegistered(
                spec: RuntimeCreateVolumeSpec(name: "postgres_data"),
                existingVolumeNames: ["postgres_data", "logs"]
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
                existingVolumeNames: []
            )
        }

        #expect(didCreate == true)
        let entries = await runtime.entriesSnapshot()
        #expect(entries == [.createVolume(name: "fresh_data")])
    }

    @Test("ensureNamedVolumeRegistered tolerates alreadyExists race")
    func toleratesAlreadyExistsRace() async throws {
        // MockRuntime throws .alreadyExists when a volume with that name is already in
        // its in-memory registry. existingVolumeNames is empty (simulating "we listed
        // the registry before someone else snuck a create in"), so we go through the
        // create branch and rely on the catch to swallow the race.
        let runtime = MockRuntime(volumes: [RuntimeVolume(name: "racy")])

        let didCreate = try await RuntimeEnvironment.$current.withValue(runtime) {
            try await ComposeUp.ensureNamedVolumeRegistered(
                spec: RuntimeCreateVolumeSpec(name: "racy"),
                existingVolumeNames: []
            )
        }

        #expect(didCreate == false)
    }
}
