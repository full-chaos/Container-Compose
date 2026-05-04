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
import ContainerResource
import ContainerizationError
@testable import ContainerComposeCore

/// Contract tests for `RuntimeErrorMapper` (CHAOS-1416).
///
/// Each test verifies a parallel pair: given a specific upstream error shape,
/// the mapper produces the expected `RuntimeError`. Locks the translation table
/// so future refactors can't accidentally regress any arm.
@Suite("RuntimeErrorMapper contract tests (CHAOS-1416)")
struct RuntimeErrorMapperTests {

    // MARK: - Pass-through

    @Test("RuntimeError passes through unchanged")
    func passThrough_runtimeError() {
        let original = RuntimeError.notFound(id: "alpine")
        let mapped = RuntimeErrorMapper.map(original)
        #expect(mapped == original)
    }

    @Test("RuntimeError.alreadyExists passes through unchanged")
    func passThrough_alreadyExists() {
        let original = RuntimeError.alreadyExists(id: "pg_data")
        let mapped = RuntimeErrorMapper.map(original)
        #expect(mapped == original)
    }

    // MARK: - VolumeError

    @Test("VolumeError.volumeAlreadyExists maps to alreadyExists — embedded name")
    func volumeAlreadyExists_usesEmbeddedName() {
        let error = VolumeError.volumeAlreadyExists("pg_data")
        let mapped = RuntimeErrorMapper.map(error)
        #expect(mapped == .alreadyExists(id: "pg_data"))
    }

    @Test("VolumeError.volumeAlreadyExists maps to alreadyExists — caller-supplied id wins")
    func volumeAlreadyExists_callerIdWins() {
        let error = VolumeError.volumeAlreadyExists("embedded_name")
        let mapped = RuntimeErrorMapper.map(error, id: "caller_name")
        #expect(mapped == .alreadyExists(id: "caller_name"))
    }

    @Test("VolumeError.volumeNotFound maps to notFound — embedded name")
    func volumeNotFound_usesEmbeddedName() {
        let error = VolumeError.volumeNotFound("missing_vol")
        let mapped = RuntimeErrorMapper.map(error)
        #expect(mapped == .notFound(id: "missing_vol"))
    }

    @Test("VolumeError.volumeNotFound maps to notFound — caller-supplied id wins")
    func volumeNotFound_callerIdWins() {
        let error = VolumeError.volumeNotFound("embedded")
        let mapped = RuntimeErrorMapper.map(error, id: "caller")
        #expect(mapped == .notFound(id: "caller"))
    }

    @Test("VolumeError.volumeInUse maps to backendFailure")
    func volumeInUse_backendFailure() {
        let error = VolumeError.volumeInUse("pg_data")
        let mapped = RuntimeErrorMapper.map(error)
        if case .backendFailure = mapped {
            // expected
        } else {
            Issue.record("Expected .backendFailure, got \(mapped)")
        }
    }

    // MARK: - ContainerizationError typed code

    @Test("ContainerizationError(.notFound) maps to notFound")
    func containerizationError_notFoundCode() {
        let error = ContainerizationError(.notFound, message: "container ghost not found")
        let mapped = RuntimeErrorMapper.map(error, id: "ghost")
        #expect(mapped == .notFound(id: "ghost"))
    }

    @Test("ContainerizationError(.notFound) nested in cause maps to notFound")
    func containerizationError_notFoundInCause() {
        let cause = ContainerizationError(.notFound, message: "inner not found")
        let outer = ContainerizationError(.internalError, message: "wrapped", cause: cause)
        let mapped = RuntimeErrorMapper.map(outer, id: "myContainer")
        #expect(mapped == .notFound(id: "myContainer"))
    }

    @Test("ContainerizationError message 'already exists' maps to alreadyExists")
    func containerizationError_alreadyExistsMessage() {
        let error = ContainerizationError(.internalError, message: "volume already exists on disk")
        let mapped = RuntimeErrorMapper.map(error, id: "pg_data")
        #expect(mapped == .alreadyExists(id: "pg_data"))
    }

    @Test("ContainerizationError message 'not found' maps to notFound")
    func containerizationError_notFoundMessage() {
        let error = ContainerizationError(.internalError, message: "resource not found in store")
        let mapped = RuntimeErrorMapper.map(error, id: "missing")
        #expect(mapped == .notFound(id: "missing"))
    }

    @Test("ContainerizationError other codes map to backendFailure")
    func containerizationError_otherCode() {
        let error = ContainerizationError(.timeout, message: "daemon request timed out")
        let mapped = RuntimeErrorMapper.map(error, id: "web")
        if case .backendFailure = mapped {
            // expected
        } else {
            Issue.record("Expected .backendFailure, got \(mapped)")
        }
    }

    // MARK: - NSCocoaError (CHAOS-1413 Layer 1)

    @Test("NSFileWriteFileExistsError maps to alreadyExists")
    func nsCocoaError_fileWriteExists() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: nil)
        let mapped = RuntimeErrorMapper.map(error, id: "vol_a")
        #expect(mapped == .alreadyExists(id: "vol_a"), "NSFileWriteFileExistsError must map to alreadyExists (CHAOS-1413 Layer 1 fix)")
    }

    @Test("NSFileNoSuchFileError maps to notFound")
    func nsCocoaError_noSuchFile() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
        let mapped = RuntimeErrorMapper.map(error, id: "vol_b")
        #expect(mapped == .notFound(id: "vol_b"))
    }

    @Test("Other NSCocoaErrorDomain codes map to backendFailure")
    func nsCocoaError_otherCode() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileLockingError, userInfo: [NSLocalizedDescriptionKey: "file locked"])
        let mapped = RuntimeErrorMapper.map(error)
        if case .backendFailure = mapped {
            // expected
        } else {
            Issue.record("Expected .backendFailure, got \(mapped)")
        }
    }

    @Test("NSError in other domain maps to backendFailure")
    func nsError_otherDomain() {
        let error = NSError(domain: "com.example.MyDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "custom error"])
        let mapped = RuntimeErrorMapper.map(error)
        if case .backendFailure = mapped {
            // expected
        } else {
            Issue.record("Expected .backendFailure, got \(mapped)")
        }
    }

    // MARK: - Generic error

    @Test("Arbitrary Swift Error maps to backendFailure")
    func genericError_backendFailure() {
        struct SomeBackendError: LocalizedError {
            var errorDescription: String? { "something went wrong" }
        }
        let mapped = RuntimeErrorMapper.map(SomeBackendError())
        if case .backendFailure(let msg) = mapped {
            #expect(msg == "something went wrong")
        } else {
            Issue.record("Expected .backendFailure, got \(mapped)")
        }
    }

    // MARK: - id fallback

    @Test("When id is nil and VolumeError embeds a name, that name is used")
    func idFallback_fromVolumeError() {
        let error = VolumeError.volumeNotFound("embedded_name")
        let mapped = RuntimeErrorMapper.map(error, id: nil)
        #expect(mapped == .notFound(id: "embedded_name"))
    }

    @Test("When id is nil and ContainerizationError is used, id falls back to 'unknown'")
    func idFallback_unknown() {
        let error = ContainerizationError(.notFound, message: "not found")
        let mapped = RuntimeErrorMapper.map(error, id: nil)
        #expect(mapped == .notFound(id: "unknown"))
    }
}
