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

@Suite(.serialized)
struct AuthStoreTests {

    // MARK: - Helpers

    private final class TempStorePath {
        let directory: URL
        let path: URL

        init() throws {
            self.directory = FileManager.default.temporaryDirectory
                .appending(path: "auth-store-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.path = directory.appending(path: "auth.json")
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func tempStorePath() throws -> TempStorePath {
        try TempStorePath()
    }

    private static func key(name: String, hash: String = String(repeating: "a", count: 64)) -> StoredKey {
        StoredKey(name: name, hash: hash, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - APIKeyGenerator

    @Test
    func generatorProducesValidShape() async throws {
        let (token, hash) = APIKeyGenerator.generate()
        #expect(token.hasPrefix("cc_v1_"))
        #expect(token.count > 6)
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { $0.isHexDigit })
        #expect(hash == hash.lowercased())
        #expect(APIKeyGenerator.hash(rawToken: token) == hash)
    }

    @Test
    func generatorProducesUniqueTokens() async throws {
        var tokens = Set<String>()
        for _ in 0..<100 {
            let (token, _) = APIKeyGenerator.generate()
            tokens.insert(token)
        }
        #expect(tokens.count == 100)
    }

    // MARK: - FileAuthStore

    @Test
    func insertAndFindRoundTrip() async throws {
        let temp = try Self.tempStorePath()
        let store = try await FileAuthStore(path: temp.path)
        let storedKey = Self.key(name: "local", hash: String(repeating: "b", count: 64))

        try await store.insert(storedKey)
        let found = await store.find(hashHex: storedKey.hash)

        #expect(found == storedKey)
    }

    @Test
    func findReturnsNilForUnknownHash() async throws {
        let temp = try Self.tempStorePath()
        let store = try await FileAuthStore(path: temp.path)

        try await store.insert(Self.key(name: "local"))

        #expect(await store.find(hashHex: String(repeating: "f", count: 64)) == nil)
    }

    @Test
    func insertDuplicateNameThrows() async throws {
        let temp = try Self.tempStorePath()
        let store = try await FileAuthStore(path: temp.path)
        try await store.insert(Self.key(name: "local", hash: String(repeating: "a", count: 64)))

        do {
            try await store.insert(Self.key(name: "local", hash: String(repeating: "b", count: 64)))
            Issue.record("Expected duplicateName error")
        } catch let error as AuthStoreError {
            #expect(error == .duplicateName("local"))
        } catch {
            Issue.record("Expected AuthStoreError, got \(error)")
        }
    }

    @Test
    func removeReturnsTrueWhenPresent() async throws {
        let temp = try Self.tempStorePath()
        let store = try await FileAuthStore(path: temp.path)

        try await store.insert(Self.key(name: "local"))

        #expect(try await store.remove(name: "local"))
        #expect(await store.list() == [])
    }

    @Test
    func removeReturnsFalseWhenAbsent() async throws {
        let temp = try Self.tempStorePath()
        let store = try await FileAuthStore(path: temp.path)

        #expect(try await !store.remove(name: "missing"))
    }

    @Test
    func listReturnsAllInsertedKeys() async throws {
        let temp = try Self.tempStorePath()
        let store = try await FileAuthStore(path: temp.path)
        let first = Self.key(name: "first", hash: String(repeating: "1", count: 64))
        let second = Self.key(name: "second", hash: String(repeating: "2", count: 64))

        try await store.insert(first)
        try await store.insert(second)

        #expect(await store.list() == [first, second])
    }

    @Test
    func persistsAcrossInstances() async throws {
        let temp = try Self.tempStorePath()
        let storedKey = Self.key(name: "persisted", hash: String(repeating: "c", count: 64))

        let firstStore = try await FileAuthStore(path: temp.path)
        try await firstStore.insert(storedKey)

        let secondStore = try await FileAuthStore(path: temp.path)
        #expect(await secondStore.list() == [storedKey])
    }

    @Test
    func filePermissionsAre0600() async throws {
        let temp = try Self.tempStorePath()
        let store = try await FileAuthStore(path: temp.path)

        try await store.insert(Self.key(name: "local"))

        let attrs = try FileManager.default.attributesOfItem(atPath: temp.path.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect(perms == 0o600)
    }

    @Test
    func parentDirectoryHas0700PermsOrIsLeftAlone() async throws {
        let temp = try Self.tempStorePath()
        let createdParent = temp.directory.appending(path: "created-by-store")
        let path = createdParent.appending(path: "auth.json")

        let store = try await FileAuthStore(path: path)
        try await store.insert(Self.key(name: "local"))

        let attrs = try FileManager.default.attributesOfItem(atPath: createdParent.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect(perms == 0o700)
    }

    @Test
    func malformedJSONThrowsOnInit() async throws {
        let temp = try Self.tempStorePath()
        try Data("not-json".utf8).write(to: temp.path, options: .atomic)

        do {
            _ = try await FileAuthStore(path: temp.path)
            Issue.record("Expected malformedFile error")
        } catch let error as AuthStoreError {
            #expect(error == .malformedFile(temp.path.path))
        } catch {
            Issue.record("Expected AuthStoreError, got \(error)")
        }
    }

    @Test
    func concurrentInsertsSerializeViaActor() async throws {
        let temp = try Self.tempStorePath()
        let store = try await FileAuthStore(path: temp.path)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    let hash = String(format: "%064x", index)
                    let key = StoredKey(
                        name: "key-\(index)",
                        hash: hash,
                        createdAt: Date(timeIntervalSince1970: Double(index))
                    )
                    try await store.insert(key)
                }
            }
            try await group.waitForAll()
        }

        let keys = await store.list()
        let names = Set(keys.map(\.name))
        #expect(keys.count == 50)
        #expect(names == Set((0..<50).map { "key-\($0)" }))
    }
}
