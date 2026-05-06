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

import Testing
import Foundation
import TestHelpers
@testable import ContainerComposeCore

/// CHAOS-1430 — Tests for `DockerCompose.from(yaml:)` entry point.
///
/// Covers:
///  - Happy paths: `String` overload and `Data` overload produce consistent results
///  - Round-trip parity: `from(yaml:)` decodes the same key fields as
///    `loadAndMerge(mainPath:)` for a simple compose file with no includes
///  - Error path: malformed YAML throws `DecodingError`
///  - Documented divergence: a document with `include:` or `extends: {file:}`
///    is returned **unresolved** (the entries are present as raw data, not expanded)
@Suite("DockerCompose.from(yaml:) entry point")
struct DockerComposeFromYAMLTests {

    // MARK: - Fixtures

    private static let simpleYAML = """
    version: '3.8'
    name: test-project
    services:
      web:
        image: nginx:1.27
      db:
        image: postgres:16
    volumes:
      db-data:
    """

    private static let simpleYAMLData: Data = {
        Data(simpleYAML.utf8)
    }()

    // MARK: - Happy path: String overload

    @Test("from(yaml: String) decodes version, name, services, and volumes")
    func fromYAMLStringDecodes() throws {
        let compose = try DockerCompose.from(yaml: Self.simpleYAML)

        #expect(compose.version == "3.8")
        #expect(compose.name == "test-project")
        #expect(compose.services.count == 2)
        #expect(compose.services["web"]??.image == "nginx:1.27")
        #expect(compose.services["db"]??.image == "postgres:16")
        #expect(compose.volumes?["db-data"] != nil)
    }

    // MARK: - Happy path: Data overload

    @Test("from(yaml: Data) produces the same result as the String overload")
    func fromYAMLDataMatchesStringOverload() throws {
        let fromString = try DockerCompose.from(yaml: Self.simpleYAML)
        let fromData   = try DockerCompose.from(yaml: Self.simpleYAMLData)

        #expect(fromString.version == fromData.version)
        #expect(fromString.name    == fromData.name)
        #expect(fromString.services.count == fromData.services.count)
        #expect(fromString.services["web"]??.image == fromData.services["web"]??.image)
        #expect(fromString.services["db"]??.image  == fromData.services["db"]??.image)
        #expect(fromString.volumes?.keys.sorted() == fromData.volumes?.keys.sorted())
    }

    // MARK: - Round-trip parity with loadAndMerge

    @Test("from(yaml: Data) and loadAndMerge(mainPath:) decode the same key fields for a file with no includes")
    func roundTripParityWithLoadAndMerge() throws {
        // Write the compose YAML to a temp file so we can drive loadAndMerge.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chaos-1430-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let filePath = dir.appendingPathComponent("docker-compose.yml").path
        try Self.simpleYAML.write(toFile: filePath, atomically: true, encoding: .utf8)

        let viaFile   = try DockerCompose.loadAndMerge(mainPath: filePath)
        let viaData   = try DockerCompose.from(yaml: Self.simpleYAMLData)

        // Key fields must match.
        #expect(viaFile.version == viaData.version)
        #expect(viaFile.name    == viaData.name)
        #expect(viaFile.services.count == viaData.services.count)
        #expect(viaFile.services["web"]??.image == viaData.services["web"]??.image)
        #expect(viaFile.services["db"]??.image  == viaData.services["db"]??.image)
        #expect(viaFile.volumes?.keys.sorted() == viaData.volumes?.keys.sorted())
    }

    // MARK: - Error path: malformed YAML

    @Test("from(yaml: String) throws DecodingError on structurally invalid YAML")
    func fromYAMLStringThrowsOnMalformed() throws {
        let malformed = """
        services:
          web:
            image: nginx:1.27
            ports:
              - "not a port: yet
        """
        #expect(throws: (any Error).self) {
            try DockerCompose.from(yaml: malformed)
        }
    }

    @Test("from(yaml: Data) throws DecodingError on structurally invalid YAML bytes")
    func fromYAMLDataThrowsOnMalformed() throws {
        let malformed = Data("""
        services:
          web:
            image: nginx:1.27
            ports:
              - "not a port: yet
        """.utf8)
        #expect(throws: (any Error).self) {
            try DockerCompose.from(yaml: malformed)
        }
    }

    @Test("from(yaml: Data) throws when data is not valid UTF-8")
    func fromYAMLDataThrowsOnInvalidUTF8() {
        // 0xFF is not valid UTF-8.
        let invalidUTF8 = Data([0xFF, 0xFE, 0x00])
        #expect(throws: (any Error).self) {
            try DockerCompose.from(yaml: invalidUTF8)
        }
    }

    // MARK: - Documented divergence: include directives are unresolved

    @Test("from(yaml:) returns include entries unresolved — normalization divergence is documented behavior")
    func includeEntriesAreNotResolved() throws {
        // A document that references another file via `include:` (shorthand form).
        // from(yaml:) has no filesystem context, so it returns the raw entry.
        let yamlWithInclude = """
        include:
          - common.yml
        services:
          web:
            image: nginx:1.27
        """
        let compose = try DockerCompose.from(yaml: yamlWithInclude)

        // The include entry is present in the decoded document — it was NOT
        // resolved (no filesystem access occurred, no error was thrown).
        #expect(compose.include != nil)
        #expect(compose.include?.isEmpty == false)

        // The service from *this* document is still present.
        #expect(compose.services["web"]??.image == "nginx:1.27")
    }

    @Test("from(yaml:) returns extends.file reference unresolved — normalization divergence is documented behavior")
    func extendsFileReferenceIsNotResolved() throws {
        // A service that extends a service defined in another file.
        // from(yaml:) has no filesystem context, so it returns the raw reference.
        let yamlWithExtendsFile = """
        services:
          web:
            extends:
              file: base.yml
              service: base-web
            image: nginx:1.27
        """
        let compose = try DockerCompose.from(yaml: yamlWithExtendsFile)

        let webService = try #require(compose.services["web"] as? Service)

        // The extends reference is present as decoded — no file was loaded,
        // no error was thrown, no field inheritance occurred.
        #expect(webService.extends != nil)
        // The image set on this service itself is intact.
        #expect(webService.image == "nginx:1.27")
    }
}
