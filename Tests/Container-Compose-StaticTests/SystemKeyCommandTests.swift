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

import ArgumentParser
import Foundation
import Testing
@testable import ContainerComposeCore

#if canImport(Darwin)
import Darwin
#endif

@Suite(.serialized)
struct SystemKeyCommandTests {

    // MARK: - Helpers

    private func tempAuthFile() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cc-keytest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "auth.json")
    }

    private func captureStandardOutput(_ body: () async throws -> Void) async throws -> String {
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        guard original >= 0 else { throw CaptureError.dupFailed }

        let pipe = Pipe()
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            close(original)
            throw CaptureError.dupFailed
        }

        do {
            try await body()
            fflush(stdout)
            restoreStandardOutput(original: original, pipe: pipe)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            fflush(stdout)
            restoreStandardOutput(original: original, pipe: pipe)
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            throw error
        }
    }

    private func restoreStandardOutput(original: Int32, pipe: Pipe) {
        _ = dup2(original, STDOUT_FILENO)
        close(original)
        pipe.fileHandleForWriting.closeFile()
    }

    private enum CaptureError: Error {
        case dupFailed
    }

    // MARK: - Tests

    @Test
    func generateKeyStoresHash() async throws {
        let path = tempAuthFile()
        let cmd = try SystemGenerateKey.parse(["--name", "dev", "--auth-file", path.path])
        _ = try await captureStandardOutput { try await cmd.run() }

        let store = try await FileAuthStore(path: path)
        let keys = await store.list()
        #expect(keys.count == 1)
        #expect(keys[0].name == "dev")
        #expect(keys[0].hash.count == 64)
    }

    @Test
    func generateKeyDuplicateNameThrows() async throws {
        let path = tempAuthFile()
        let first = try SystemGenerateKey.parse(["--name", "dev", "--auth-file", path.path])
        _ = try await captureStandardOutput { try await first.run() }
        let second = try SystemGenerateKey.parse(["--name", "dev", "--auth-file", path.path])

        do {
            _ = try await captureStandardOutput { try await second.run() }
            Issue.record("Expected duplicate name ValidationError")
        } catch is ValidationError {
            // expected
        } catch {
            Issue.record("Expected ValidationError, got \(error)")
        }
    }

    @Test
    func revokeKeyRemovesByName() async throws {
        let path = tempAuthFile()
        let store = try await FileAuthStore(path: path)
        try await store.insert(StoredKey(
            name: "dev",
            hash: String(repeating: "a", count: 64),
            createdAt: Date()
        ))
        let cmd = try SystemRevokeKey.parse(["dev", "--auth-file", path.path])

        let output = try await captureStandardOutput { try await cmd.run() }
        let reloadedStore = try await FileAuthStore(path: path)
        let keys = await reloadedStore.list()

        #expect(output.contains("Revoked key: dev"))
        #expect(keys.isEmpty)
    }

    @Test
    func revokeKeyMissingNameExitsNonZero() async throws {
        let path = tempAuthFile()
        let cmd = try SystemRevokeKey.parse(["missing", "--auth-file", path.path])

        do {
            _ = try await captureStandardOutput { try await cmd.run() }
            Issue.record("Expected ExitCode(1)")
        } catch let error as ExitCode {
            #expect(error == ExitCode(1))
        } catch {
            Issue.record("Expected ExitCode, got \(error)")
        }
    }

    @Test
    func listKeysFormatsHeaderAndRows() async throws {
        let path = tempAuthFile()
        let store = try await FileAuthStore(path: path)
        try await store.insert(StoredKey(
            name: "first",
            hash: String(repeating: "1", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try await store.insert(StoredKey(
            name: "second",
            hash: String(repeating: "2", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        ))
        let cmd = try SystemListKeys.parse(["--auth-file", path.path])

        let output = try await captureStandardOutput { try await cmd.run() }

        #expect(output.hasPrefix("NAME\tHASH-PREFIX\tCREATED"))
        #expect(output.contains("first\t11111111\t"))
        #expect(output.contains("second\t22222222\t"))
        #expect(!output.contains(String(repeating: "1", count: 64)))
        #expect(!output.contains(String(repeating: "2", count: 64)))
    }

    @Test
    func listKeysEmptyStoreOnlyHeader() async throws {
        let path = tempAuthFile()
        let cmd = try SystemListKeys.parse(["--auth-file", path.path])

        let output = try await captureStandardOutput { try await cmd.run() }

        #expect(output == "NAME\tHASH-PREFIX\tCREATED\n")
    }

    @Test
    func generateKeyOutputDoesNotLeakHashOrPath() async throws {
        let path = tempAuthFile()
        let cmd = try SystemGenerateKey.parse(["--name", "dev", "--auth-file", path.path])

        let output = try await captureStandardOutput { try await cmd.run() }
        let store = try await FileAuthStore(path: path)
        let keys = await store.list()
        guard let key = keys.first else {
            Issue.record("Expected generated key")
            return
        }
        let hashPrefix = String(key.hash.prefix(8))

        #expect(output.contains("Copy it now"))
        #expect(output.contains("cc_v1_"))
        #expect(output.contains(hashPrefix))
        #expect(!output.contains(key.hash))
    }
}
