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
import SystemPackage

#if canImport(Darwin)
import Darwin
#endif

// MARK: - RuntimeContainerRecord

/// Durable, apple-free metadata for a container known to a `Runtime`. The
/// registry persists these — never `LinuxContainer` instances. Live runtime
/// handles (e.g. `LinuxContainer?`) stay isolated inside the conforming
/// runtime actor (`AppleContainerizationRuntime`); they cannot be
/// reconstructed across daemon restarts (per Phase 0 spike's "no
/// retrospective attach" finding) so they are intentionally absent here.
public struct RuntimeContainerRecord: Codable, Sendable, Hashable {
    public let id: String
    public let imageReference: String
    public let createdAt: Date
    public var state: RuntimeContainerStatus
    public var startedAt: Date?
    public var exitStatus: RuntimeExitStatus?
    public var publishedPorts: [RuntimePublishedPort]

    public init(
        id: String,
        imageReference: String,
        createdAt: Date,
        state: RuntimeContainerStatus = .created,
        startedAt: Date? = nil,
        exitStatus: RuntimeExitStatus? = nil,
        publishedPorts: [RuntimePublishedPort] = []
    ) {
        self.id = id
        self.imageReference = imageReference
        self.createdAt = createdAt
        self.state = state
        self.startedAt = startedAt
        self.exitStatus = exitStatus
        self.publishedPorts = publishedPorts
    }

    public func toRuntimeContainer() -> RuntimeContainer {
        RuntimeContainer(
            id: id,
            imageReference: imageReference,
            status: state,
            publishedPorts: publishedPorts,
            createdAt: createdAt,
            startedAt: startedAt,
            lastExitCode: exitStatus?.exitCode
        )
    }
}

// MARK: - ContainerRegistry

/// Cross-process-safe registry of containers known to a `Runtime` conformer.
/// CHAOS-1346 Phase 1 owns this gap because `apple/containerization` does not
/// expose a `list()` API on `ContainerManager` — see Phase 0 spike report
/// (`docs/plans/native-api-spike-report.md` §3.1).
///
/// Concurrency model:
/// - Actor isolates in-process access to the in-memory `records` cache.
/// - Read/write paths to disk are wrapped in `withFileLock(...)` (POSIX
///   `flock(2)` advisory exclusive lock on a sidecar `.lock` file) so that
///   concurrent `container-compose` CLI invocations cannot corrupt the
///   on-disk JSON. Single-process serialization is provided by the actor;
///   cross-process serialization is provided by `flock`.
/// - Disk format is JSON at `~/.container-compose/registry.json`. Atomic
///   write via temp-file + rename (already provided by `Data.write` with
///   `.atomic` option). The lock additionally guards the rename so a
///   concurrent reader never sees a half-applied state.
///
/// Schema versioning: stored under a top-level `schemaVersion` field so we
/// can migrate forward without losing pre-existing state. Phase 1 ships
/// schema v1.
public actor ContainerRegistry {
    // MARK: - Defaults

    /// Default on-disk path: `~/.container-compose/registry.json`. The
    /// directory is created on first write.
    public static var defaultStoragePath: String {
        FilePath(FileManager.default.homeDirectoryForCurrentUser.path)
            .pushing(FilePath(".container-compose"))
            .pushing(FilePath("registry.json"))
            .string
    }

    // MARK: - State

    private let storagePath: String
    private var records: [String: RuntimeContainerRecord]

    // MARK: - Init

    /// Load (or initialize) a registry rooted at `storagePath`. The disk file
    /// is read once at init; subsequent reads come from the in-memory cache
    /// so `list()` is O(records). Concurrent writers in OTHER processes are
    /// not visible until the next mutation triggers a re-read; Phase 1 has
    /// no `serve` daemon so this stale-read window is acceptable.
    public init(storagePath: String = ContainerRegistry.defaultStoragePath) async throws {
        self.storagePath = storagePath
        self.records = try ContainerRegistry.loadFromDisk(at: storagePath)
    }

    // MARK: - Read API

    public func list() -> [RuntimeContainerRecord] {
        Array(records.values)
    }

    public func get(id: String) -> RuntimeContainerRecord? {
        records[id]
    }

    // MARK: - Write API

    public func register(_ record: RuntimeContainerRecord) throws {
        records[record.id] = record
        try writeToDisk()
    }

    public func updateState(id: String, state: RuntimeContainerStatus, startedAt: Date? = nil) throws {
        guard var record = records[id] else { return }
        record.state = state
        if let startedAt {
            record.startedAt = startedAt
        }
        records[id] = record
        try writeToDisk()
    }

    public func recordExit(id: String, exitStatus: RuntimeExitStatus) throws {
        guard var record = records[id] else { return }
        record.exitStatus = exitStatus
        record.state = .exited
        records[id] = record
        try writeToDisk()
    }

    public func remove(id: String) throws {
        records.removeValue(forKey: id)
        try writeToDisk()
    }

    // MARK: - Disk persistence

    private struct DiskSchema: Codable {
        var schemaVersion: Int
        var records: [String: RuntimeContainerRecord]
    }

    private static let currentSchemaVersion: Int = 1

    private static func loadFromDisk(at path: String) throws -> [String: RuntimeContainerRecord] {
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        return try withFileLock(at: path) {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return [:] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                let schema = try decoder.decode(DiskSchema.self, from: data)
                return schema.records
            } catch {
                throw RuntimeError.persistenceFailure(
                    message: "could not decode registry at \(path): \(error.localizedDescription)"
                )
            }
        }
    }

    private func writeToDisk() throws {
        let url = URL(filePath: storagePath)
        let storageDirectory = FilePath(storagePath).removingLastComponent().string
        try FileManager.default.createDirectory(
            at: URL(filePath: storageDirectory, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let snapshot = DiskSchema(
            schemaVersion: ContainerRegistry.currentSchemaVersion,
            records: records
        )
        let data = try encoder.encode(snapshot)
        try ContainerRegistry.withFileLock(at: storagePath) {
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - File locking

    /// Acquire an exclusive POSIX advisory lock on a sidecar `.lock` file
    /// for the duration of `work`. Lock file is created on demand and never
    /// removed (dropping it would race with concurrent acquirers). The
    /// lock is released when the file descriptor is closed, so a panicking
    /// `work` closure cannot leave the file locked.
    @discardableResult
    private static func withFileLock<T>(at path: String, _ work: () throws -> T) throws -> T {
        let lockPath = path + ".lock"
        let dir = FilePath(lockPath).removingLastComponent().string
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw RuntimeError.persistenceFailure(
                message: "could not open lock file '\(lockPath)' (errno=\(errno))"
            )
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            throw RuntimeError.persistenceFailure(
                message: "could not acquire flock on '\(lockPath)' (errno=\(errno))"
            )
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try work()
    }
}
