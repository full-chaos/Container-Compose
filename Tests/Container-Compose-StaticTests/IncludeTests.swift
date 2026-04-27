//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
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
@testable import Yams
@testable import ContainerComposeCore

// MARK: - Helpers

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeYAML(_ content: String, to dir: URL, named filename: String) -> String {
    let url = dir.appendingPathComponent(filename)
    try! content.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

// MARK: - Suite

@Suite("Include Entry Codable Tests")
struct IncludeEntryTests {

    @Test("IncludeEntry decodes from shorthand string")
    func decodeShorthand() throws {
        let yaml = """
        - ./other.yml
        """
        let entries = try YAMLDecoder().decode([IncludeEntry].self, from: yaml)
        #expect(entries.count == 1)
        #expect(entries[0].path == ["./other.yml"])
        #expect(entries[0].env_file == nil)
        #expect(entries[0].project_directory == nil)
    }

    @Test("IncludeEntry decodes from object form with path string")
    func decodeObjectFormPathString() throws {
        let yaml = """
        - path: ./other.yml
          project_directory: ./subdir
        """
        let entries = try YAMLDecoder().decode([IncludeEntry].self, from: yaml)
        #expect(entries.count == 1)
        #expect(entries[0].path == ["./other.yml"])
        #expect(entries[0].project_directory == "./subdir")
    }

    @Test("IncludeEntry decodes from object form with path array")
    func decodeObjectFormPathArray() throws {
        let yaml = """
        - path:
            - ./a.yml
            - ./b.yml
        """
        let entries = try YAMLDecoder().decode([IncludeEntry].self, from: yaml)
        #expect(entries.count == 1)
        #expect(entries[0].path == ["./a.yml", "./b.yml"])
    }

    @Test("IncludeEntry decodes env_file as string")
    func decodeEnvFileString() throws {
        let yaml = """
        - path: ./other.yml
          env_file: ./override.env
        """
        let entries = try YAMLDecoder().decode([IncludeEntry].self, from: yaml)
        #expect(entries[0].env_file == ["./override.env"])
    }

    @Test("IncludeEntry decodes env_file as array")
    func decodeEnvFileArray() throws {
        let yaml = """
        - path: ./other.yml
          env_file:
            - ./a.env
            - ./b.env
        """
        let entries = try YAMLDecoder().decode([IncludeEntry].self, from: yaml)
        #expect(entries[0].env_file == ["./a.env", "./b.env"])
    }
}

@Suite("DockerCompose include: field parsing")
struct DockerComposeIncludeFieldTests {

    @Test("Compose with no include section decodes normally (regression)")
    func noIncludeSection() throws {
        let yaml = """
        version: '3.8'
        services:
          web:
            image: nginx:latest
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        #expect(compose.include == nil)
        #expect(compose.services["web"]??.image == "nginx:latest")
    }

    @Test("Compose with include: list decodes include entries")
    func decodeIncludeField() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
        include:
          - ./other.yml
          - path: ./another.yml
            env_file: ./override.env
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        #expect(compose.include?.count == 2)
        #expect(compose.include?[0].path == ["./other.yml"])
        #expect(compose.include?[1].path == ["./another.yml"])
        #expect(compose.include?[1].env_file == ["./override.env"])
    }
}

@Suite("DockerCompose.loadAndMerge integration tests")
struct LoadAndMergeTests {

    // MARK: Shorthand include

    @Test("Shorthand include merges services from included file")
    func shorthandIncludeMergesServices() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = writeYAML("""
        services:
          db:
            image: postgres:14
        """, to: dir, named: "other.yml")

        let mainPath = writeYAML("""
        services:
          web:
            image: nginx:latest
        include:
          - ./other.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        #expect(merged.services.count == 2)
        #expect(merged.services["web"]??.image == "nginx:latest")
        #expect(merged.services["db"]??.image == "postgres:14")
    }

    // MARK: Object form include

    @Test("Object-form include { path: ... } merges services")
    func objectFormIncludeMergesServices() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = writeYAML("""
        services:
          cache:
            image: redis:alpine
        """, to: dir, named: "other.yml")

        let mainPath = writeYAML("""
        services:
          api:
            image: myapp:latest
        include:
          - path: ./other.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        #expect(merged.services.count == 2)
        #expect(merged.services["api"]??.image == "myapp:latest")
        #expect(merged.services["cache"]??.image == "redis:alpine")
    }

    // MARK: Networks and volumes merge

    @Test("Include merges networks and volumes from included file")
    func includesMergesNetworksAndVolumes() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = writeYAML("""
        services:
          db:
            image: postgres:14
        volumes:
          db_data:
        networks:
          backend:
        """, to: dir, named: "other.yml")

        let mainPath = writeYAML("""
        services:
          web:
            image: nginx:latest
        volumes:
          static_files:
        networks:
          frontend:
        include:
          - ./other.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        #expect(merged.volumes?["db_data"] != nil)
        #expect(merged.volumes?["static_files"] != nil)
        #expect(merged.networks?["backend"] != nil)
        #expect(merged.networks?["frontend"] != nil)
    }

    // MARK: Collision — main file wins

    @Test("Service name collision: main file wins over included file")
    func collisionMainWins() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = writeYAML("""
        services:
          web:
            image: nginx:1.24
        """, to: dir, named: "other.yml")

        let mainPath = writeYAML("""
        services:
          web:
            image: nginx:latest
        include:
          - ./other.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        // Main file's version should win
        #expect(merged.services["web"]??.image == "nginx:latest")
    }

    // MARK: Recursive / deep merge

    @Test("Recursive include: A includes B, B includes C — all services merged")
    func recursiveInclude() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = writeYAML("""
        services:
          c:
            image: alpine:c
        """, to: dir, named: "c.yml")

        _ = writeYAML("""
        services:
          b:
            image: alpine:b
        include:
          - ./c.yml
        """, to: dir, named: "b.yml")

        let mainPath = writeYAML("""
        services:
          a:
            image: alpine:a
        include:
          - ./b.yml
        """, to: dir, named: "a.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        #expect(merged.services.count == 3)
        #expect(merged.services["a"]??.image == "alpine:a")
        #expect(merged.services["b"]??.image == "alpine:b")
        #expect(merged.services["c"]??.image == "alpine:c")
    }

    // MARK: Cycle detection

    @Test("Cycle A → B → A throws IncludeError.cyclicInclude")
    func cycleDetection() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // We need to write both files; b.yml references a.yml, so write a placeholder first
        let aPath = dir.appendingPathComponent("a.yml").path
        let bPath = dir.appendingPathComponent("b.yml").path

        // Write b.yml referencing a.yml
        try """
        services:
          b:
            image: alpine:b
        include:
          - ./a.yml
        """.write(toFile: bPath, atomically: true, encoding: .utf8)

        // Write a.yml referencing b.yml
        try """
        services:
          a:
            image: alpine:a
        include:
          - ./b.yml
        """.write(toFile: aPath, atomically: true, encoding: .utf8)

        #expect(throws: IncludeError.self) {
            _ = try DockerCompose.loadAndMerge(mainPath: aPath)
        }
    }

    @Test("Self-referencing file throws IncludeError.cyclicInclude")
    func selfCycle() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainPath = writeYAML("""
        services:
          web:
            image: nginx:latest
        include:
          - ./compose.yml
        """, to: dir, named: "compose.yml")

        #expect(throws: IncludeError.self) {
            _ = try DockerCompose.loadAndMerge(mainPath: mainPath)
        }
    }

    // MARK: Missing file

    @Test("Including a non-existent file throws IncludeError.fileNotFound")
    func missingIncludedFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainPath = writeYAML("""
        services:
          web:
            image: nginx:latest
        include:
          - ./does-not-exist.yml
        """, to: dir, named: "compose.yml")

        #expect(throws: Error.self) {
            _ = try DockerCompose.loadAndMerge(mainPath: mainPath)
        }
    }

    // MARK: No include — same as direct decode (regression)

    @Test("File without include: returns result identical to YAMLDecoder (regression)")
    func noIncludeRegressionLoadAndMerge() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let yaml = """
        version: '3.8'
        name: myproject
        services:
          web:
            image: nginx:latest
          db:
            image: postgres:14
        volumes:
          data:
        networks:
          frontend:
        """

        let mainPath = writeYAML(yaml, to: dir, named: "compose.yml")

        let viaLoadAndMerge = try DockerCompose.loadAndMerge(mainPath: mainPath)
        let viaDecoder = try YAMLDecoder().decode(DockerCompose.self, from: yaml)

        #expect(viaLoadAndMerge.version == viaDecoder.version)
        #expect(viaLoadAndMerge.name == viaDecoder.name)
        #expect(viaLoadAndMerge.services.keys.sorted() == viaDecoder.services.keys.sorted())
        #expect(viaLoadAndMerge.volumes?.keys.sorted() == viaDecoder.volumes?.keys.sorted())
        #expect(viaLoadAndMerge.networks?.keys.sorted() == viaDecoder.networks?.keys.sorted())
    }
}
