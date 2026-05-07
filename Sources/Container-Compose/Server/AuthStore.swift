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

import Crypto
import Foundation
import SystemPackage

#if canImport(Darwin)
import Darwin
#endif

// MARK: - StoredKey

/// Stored API key record. Hashed only — raw token is never persisted.
public struct StoredKey: Codable, Sendable, Hashable {
    /// User-provided label, unique within the store.
    public let name: String
    /// Hex-encoded SHA-256 of the raw token.
    public let hash: String
    /// Insertion timestamp.
    public let createdAt: Date

    public init(name: String, hash: String, createdAt: Date) {
        self.name = name
        self.hash = hash
        self.createdAt = createdAt
    }
}

// MARK: - AuthStore

/// Read/write surface for API key persistence. Sendable for concurrent route access.
public protocol AuthStore: Sendable {
    func find(hashHex: String) async -> StoredKey?
    func insert(_ key: StoredKey) async throws
    func remove(name: String) async throws -> Bool
    func list() async -> [StoredKey]
}

// MARK: - FileAuthStore

/// File-backed auth store. JSON document at `path`, atomic-rename writes, 0600 perms.
public actor FileAuthStore: AuthStore {
    private let path: String
    private var keys: [StoredKey]

    /// Throws if path's parent directory cannot be created or the file is malformed JSON.
    /// Returns an empty store if the file does not exist.
    public init(path: String) async throws {
        self.path = path

        try Self.ensureParentDirectory(for: path)

        guard FileManager.default.fileExists(atPath: path) else {
            self.keys = []
            return
        }

        do {
            let data = try Data(contentsOf: URL(filePath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.keys = try decoder.decode([StoredKey].self, from: data)
        } catch let decodingError as DecodingError {
            throw AuthStoreError.malformedFile(path, underlying: decodingError)
        } catch {
            throw error
        }
    }

    public init(path: URL) async throws {
        try await self.init(path: path.path(percentEncoded: false))
    }

    public func find(hashHex: String) async -> StoredKey? {
        keys.first { $0.hash == hashHex }
    }

    public func insert(_ key: StoredKey) async throws {
        guard !keys.contains(where: { $0.name == key.name }) else {
            throw AuthStoreError.duplicateName(key.name)
        }
        keys.append(key)
        try await persist()
    }

    @discardableResult
    public func remove(name: String) async throws -> Bool {
        guard let index = keys.firstIndex(where: { $0.name == name }) else {
            return false
        }
        keys.remove(at: index)
        try await persist()
        return true
    }

    public func list() async -> [StoredKey] {
        keys
    }

    /// Persists `keys` to `path` atomically.
    private func persist() async throws {
        try Self.ensureParentDirectory(for: path)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(keys)
        let tmp = "\(path).tmp"
        let fileManager = FileManager.default

        do {
            try data.write(to: URL(filePath: tmp), options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)

            guard rename(tmp, path) == 0 else {
                let code = Int(errno)
                throw NSError(domain: NSPOSIXErrorDomain, code: code)
            }
        } catch {
            try? fileManager.removeItem(atPath: tmp)
            throw error
        }
    }

    private static func ensureParentDirectory(for path: String) throws {
        let parent = FilePath(path).removingLastComponent().string
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: parent) else {
            return
        }

        try fileManager.createDirectory(
            at: URL(filePath: parent, directoryHint: .isDirectory),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

// MARK: - AuthStoreError

public enum AuthStoreError: Error, Equatable {
    case duplicateName(String)
    case malformedFile(String)

    fileprivate static func malformedFile(
        _ path: String,
        underlying: DecodingError
    ) -> AuthStoreError {
        _ = underlying
        return .malformedFile(path)
    }
}
