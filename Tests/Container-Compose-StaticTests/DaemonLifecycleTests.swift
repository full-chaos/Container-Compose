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

import Darwin
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ContainerComposeCore

@Suite(.serialized)
struct DaemonLifecycleTests {

    private enum BoundSocketError: Error {
        case pathTooLong(String)
        case socketCreationFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
    }

    private static func temporarySocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "container-compose-test-\(UUID().uuidString)")
            .appending(path: "api.sock")
            .path
    }

    private static func temporaryShortSocketPath() -> String {
        URL(fileURLWithPath: "/tmp")
            .appending(path: "container-compose-test-\(UUID().uuidString)")
            .appending(path: "api.sock")
            .path
    }

    private static func removeTemporaryTree(for path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
    }

    private static func createParentDirectory(for path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    @Test("resolveSocketPath returns default when override is nil")
    func resolveSocketPath_default() {
        #expect(ServeDaemon.resolveSocketPath(override: nil) == ServeDaemon.defaultSocketPath)
    }

    @Test("resolveSocketPath returns default when override is empty string")
    func resolveSocketPath_emptyOverride() {
        #expect(ServeDaemon.resolveSocketPath(override: "") == ServeDaemon.defaultSocketPath)
    }

    @Test("resolveSocketPath expands tilde in override")
    func resolveSocketPath_expandsTilde() {
        let resolved = ServeDaemon.resolveSocketPath(override: "~/foo/bar.sock")
        #expect(resolved.hasPrefix(NSHomeDirectory()))
        #expect(resolved.hasSuffix("/foo/bar.sock"))
    }

    @Test("resolveSocketPath passes through absolute path")
    func resolveSocketPath_absolutePath() {
        #expect(ServeDaemon.resolveSocketPath(override: "/tmp/test.sock") == "/tmp/test.sock")
    }

    @Test("isAlreadyServing returns false when socket file does not exist")
    func isAlreadyServing_noFile() {
        let path = Self.temporarySocketPath()
        defer { Self.removeTemporaryTree(for: path) }
        #expect(ServeDaemon.isAlreadyServing(at: path) == false)
    }

    @Test("isAlreadyServing returns false when path exists but is a regular file (stale leftover)")
    func isAlreadyServing_staleFile() throws {
        let path = Self.temporarySocketPath()
        defer { Self.removeTemporaryTree(for: path) }
        try Self.createParentDirectory(for: path)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path))

        #expect(ServeDaemon.isAlreadyServing(at: path) == false)
    }

    @Test("cleanupStaleSocketIfNeeded removes existing file")
    func cleanup_removesFile() throws {
        let path = Self.temporarySocketPath()
        defer { Self.removeTemporaryTree(for: path) }
        try Self.createParentDirectory(for: path)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path))

        try ServeDaemon.cleanupStaleSocketIfNeeded(at: path)

        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test("cleanupStaleSocketIfNeeded is no-op when file does not exist")
    func cleanup_noFile() throws {
        let path = Self.temporarySocketPath()
        defer { Self.removeTemporaryTree(for: path) }

        try ServeDaemon.cleanupStaleSocketIfNeeded(at: path)

        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test("ensureParentDirectory creates intermediate directories")
    func ensureParentDirectory_createsDirs() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "container-compose-test-\(UUID().uuidString)")
            .appending(path: "a/b/c/test.sock")
            .path
        defer { Self.removeTemporaryTree(for: path) }

        try ServeDaemon.ensureParentDirectory(for: path)

        let parent = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    @Test("isAlreadyServing returns true when something is bound and listening")
    func isAlreadyServing_realBoundSocket() async throws {
        let path = Self.temporaryShortSocketPath()
        defer { Self.removeTemporaryTree(for: path) }
        try Self.createParentDirectory(for: path)

        let fd = try Self.bindListeningUnixSocket(at: path)
        defer {
            close(fd)
            unlink(path)
        }

        #expect(ServeDaemon.isAlreadyServing(at: path))
    }

    @Test("GET /_ping returns 200 OK with container-compose JSON identity")
    func ping_route_returns200() async throws {
        let router = Router()
        ServeDaemon.registerCoreRoutes(router: router)
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/_ping", method: .get)
            #expect(response.status == .ok)

            let data = Data(String(buffer: response.body).utf8)
            let decoded = try JSONDecoder().decode(PingResponse.self, from: data)
            #expect(decoded.ok)
            #expect(decoded.server == "container-compose")
            #expect(decoded.version.isEmpty == false)
        }
    }

    @Test("Concurrent registry writes from multiple actors do not corrupt registry.json")
    func registry_concurrentWrites_noCorruption() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "container-compose-test-\(UUID().uuidString)")
            .appending(path: "registry.json")
            .path
        defer { Self.removeTemporaryTree(for: path) }

        let seededRegistry = try await ContainerRegistry(storagePath: path)
        for i in 0..<50 {
            try await seededRegistry.register(Self.runtimeRecord(index: i))
        }

        let registryA = try await ContainerRegistry(storagePath: path)
        let registryB = try await ContainerRegistry(storagePath: path)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                let registry = i.isMultiple(of: 2) ? registryA : registryB
                group.addTask {
                    try await registry.register(Self.runtimeRecord(index: i))
                }
            }
            try await group.waitForAll()
        }

        let registryC = try await ContainerRegistry(storagePath: path)
        let records = await registryC.list()
        #expect(records.count == 50)
        #expect(Set(records.map(\.id)).count == 50)
    }

    private static func bindListeningUnixSocket(at path: String) throws -> Int32 {
        let pathBytes = Array(path.utf8)
        var addr = sockaddr_un()
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxPathLen else {
            throw BoundSocketError.pathTooLong(path)
        }

        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            let bytePtr = UnsafeMutableRawPointer(tuplePtr)
                .assumingMemoryBound(to: UInt8.self)
            for (i, byte) in pathBytes.enumerated() { bytePtr[i] = byte }
            bytePtr[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BoundSocketError.socketCreationFailed(errno: errno)
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let bindErrno = errno
            close(fd)
            throw BoundSocketError.bindFailed(errno: bindErrno)
        }

        guard listen(fd, 1) == 0 else {
            let listenErrno = errno
            close(fd)
            throw BoundSocketError.listenFailed(errno: listenErrno)
        }

        return fd
    }

    private static func runtimeRecord(index: Int) -> RuntimeContainerRecord {
        RuntimeContainerRecord(
            id: "c-\(index)",
            imageReference: "alpine:3",
            createdAt: Date()
        )
    }
}
