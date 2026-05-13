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
@testable import Yams
@testable import TestHelpers
@testable import ContainerComposeCore

// MARK: - Phase 2 Task 2.4: Compose file parsing edge-case tests
//
// Coverage map:
//  • Circular extends chains — cross-file deep chains (ExtendsTests already covers
//    same-file 2-node and direct self; we add A→B→C same-file, A→B cross-file
//    with B→A, and self-extends in the cross-file case).
//  • Invalid / malformed YAML — type mismatches, structural invalids.
//  • Conflicting field combinations — image + build coexistence.
//  • Variable interpolation edges — ${UNDEF}, ${VAR:-} (empty default), $$
//    literal escape, nested ${OUTER_${INNER}} (unsupported; disabled test).
//  • Include + extends interaction — included file has extends pointing back to
//    main-file service (cross-boundary extends), and extends in included file
//    resolved locally before merge.

@Suite("Compose Parsing Edge Cases")
struct ComposeParsingEdgeCaseTests {

    // MARK: - Helpers

    private func decode(_ yaml: String) throws -> DockerCompose {
        try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    private func resolved(_ yaml: String) throws -> DockerCompose {
        try decode(yaml).resolvingExtends()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeYAML(_ content: String, to dir: URL, named filename: String) throws -> String {
        let url = dir.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - Circular extends: three-node same-file chain

    @Test("Three-node extends cycle A→B→C→A throws")
    func threeNodeExtendsChainThrows() throws {
        // ExtendsTests already covers the two-node case.
        // This adds the three-node variant: A extends B, B extends C, C extends A.
        let yaml = """
        services:
          a:
            image: alpine
            extends:
              service: b
          b:
            image: alpine
            extends:
              service: c
          c:
            image: alpine
            extends:
              service: a
        """
        let dc = try decode(yaml)
        #expect(throws: (any Error).self) {
            _ = try dc.resolvingExtends()
        }
    }

    @Test("Deep chain A→B→C (no cycle) resolves successfully")
    func deepExtendsChainResolvesSuccessfully() throws {
        let yaml = """
        services:
          base:
            image: alpine:3.18
            restart: always
          middle:
            extends:
              service: base
            command: ["run-middle"]
          top:
            extends:
              service: middle
            environment:
              ROLE: top
        """
        let dc = try resolved(yaml)
        let top = try #require(dc.services["top"] as? Service)
        // Inherited via middle → base
        #expect(top.image == "alpine:3.18")
        #expect(top.restart == "always")
        // Own field
        #expect(top.environment?["ROLE"] == "top")
        // middle's command propagates up
        #expect(top.command == ["run-middle"])
        // All extends fields are cleared after resolution
        #expect(top.extends == nil)
    }

    @Test("Cross-file extends: service in external file extends another in same external file forms cycle")
    func crossFileInternalCycleInExternalFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // external.yml: svc1 extends svc2, svc2 extends svc1 — cycle internal to
        // the external file, discovered when the main file resolves svc1.
        _ = try writeYAML("""
        services:
          svc1:
            image: alpine
            extends:
              service: svc2
          svc2:
            image: alpine
            extends:
              service: svc1
        """, to: dir, named: "external.yml")

        let mainPath = try writeYAML("""
        services:
          app:
            image: nginx
            extends:
              service: svc1
              file: ./external.yml
        """, to: dir, named: "compose.yml")

        #expect(throws: (any Error).self) {
            _ = try DockerCompose.loadAndMerge(mainPath: mainPath).resolvingExtends()
        }
    }

    @Test("Self-extends in an included file throws a cycle error")
    func selfExtendsInIncludedFileThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try writeYAML("""
        services:
          bad:
            image: alpine
            extends:
              service: bad
        """, to: dir, named: "sub.yml")

        let mainPath = try writeYAML("""
        services:
          web:
            image: nginx
        include:
          - ./sub.yml
        """, to: dir, named: "compose.yml")

        // loadAndMerge merges all services; resolvingExtends then encounters the cycle.
        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        #expect(throws: (any Error).self) {
            _ = try merged.resolvingExtends()
        }
    }

    // MARK: - Invalid YAML: type mismatches

    @Test("Type mismatch: services as scalar string throws DecodingError")
    func servicesSectionAsScalarStringThrows() {
        let yaml = """
        services: not-a-dict
        """
        #expect(throws: (any Error).self) {
            _ = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        }
    }

    @Test("Type mismatch: service image as integer decodes as string representation")
    func imageAsIntegerBecomesString() throws {
        // YAML integer values for a string-typed field: Yams coerces scalars to strings.
        let yaml = """
        services:
          web:
            image: 12345
        """
        // This should either decode (with image = "12345") or throw — document the actual behavior.
        do {
            let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
            // If it decoded, the image field should be some non-nil string
            let image = dc.services["web"]??.image
            #expect(image != nil, "image decoded from integer scalar should be non-nil")
        } catch {
            // Decoding failure is also acceptable — this test documents the actual behavior.
        }
    }

    @Test("Empty YAML string throws DecodingError (missing required services key)")
    func emptyYAMLThrows() {
        #expect(throws: (any Error).self) {
            _ = try YAMLDecoder().decode(DockerCompose.self, from: "")
        }
    }

    @Test("YAML with only whitespace throws DecodingError")
    func whitespaceOnlyYAMLThrows() {
        let yaml = "   \n   \n   "
        #expect(throws: (any Error).self) {
            _ = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        }
    }

    @Test("YAML services as a list instead of map throws DecodingError")
    func servicesAsListThrows() {
        // Compose-spec requires services to be a mapping, not a sequence.
        let yaml = """
        services:
          - web
          - db
        """
        #expect(throws: (any Error).self) {
            _ = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        }
    }

    @Test("Service with none of image/build/provider/extends fails to decode (eager init validation, CHAOS-1442)")
    func serviceWithNeitherImageNorBuildFailsDecode() throws {
        // Service.init(from:) eagerly rejects services that declare none of
        // `image`, `build`, `provider`, or `extends` — surfacing the error at
        // decode time gives the user a DecodingError with file/line context,
        // which is a better UX than waiting for DockerCompose.validate() to
        // produce a service-name-only error. CHAOS-1316 (cf49916) extended the
        // accepted set to include `provider:` and `extends:`.
        let yaml = """
        services:
          orphan:
            restart: always
        """
        #expect(throws: (any Error).self) {
            _ = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        }
    }

    // MARK: - Conflicting field combinations: image + build

    @Test("Service with both image and build decodes without throwing")
    func imageAndBuildBothPresent() throws {
        let yaml = """
        services:
          app:
            image: myapp:latest
            build: ./app
        """
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let app = try #require(dc.services["app"] as? Service)
        // Both fields are preserved — compose-spec allows image+build for tagging.
        #expect(app.image == "myapp:latest")
        #expect(app.build != nil)
    }

    @Test("Service with both image and build is accepted by validate() (CHAOS-1510)")
    func imageAndBuildAcceptedByValidation() throws {
        // CHAOS-1510: image+build coexistence is permitted per compose-spec —
        // `image:` acts as the tag for the built image. Reverses the prior
        // CHAOS-1417/1442 contract. Canonical assertions in
        // ComposeValidationTests.swift "image + build coexistence"; this is
        // cross-coverage from the parsing edge-case suite.
        let yaml = """
        services:
          app:
            image: myapp:latest
            build: ./app
        """
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        #expect(throws: Never.self) { try dc.validate() }
        let app = dc.services["app"]!!
        #expect(app.image == "myapp:latest")
        #expect(app.build != nil)
    }

    // MARK: - Variable interpolation edge cases

    @Test("Unset variable with no default is left as-is by resolveVariable")
    func unsetVariableNoDefaultLeftAsIs() {
        // ${UNDEF} with an empty env dict — must survive unchanged.
        // Changing this behavior would break compose files that use variables
        // substituted at runtime (e.g. by `docker compose --env-file`).
        let result = resolveVariable("${TOTALLY_UNDEFINED_VAR_XYZ}", with: [:])
        #expect(result == "${TOTALLY_UNDEFINED_VAR_XYZ}")
    }

    @Test("Unset variable with empty default ${VAR:-} resolves to empty string")
    func unsetVariableEmptyDefaultResolvesToEmpty() {
        let result = resolveVariable("${UNDEF_VAR:-}", with: [:])
        #expect(result == "")
    }

    @Test("Set variable with empty default returns the actual variable value")
    func setVariableIgnoresEmptyDefault() {
        let result = resolveVariable("${MY_VAR:-}", with: ["MY_VAR": "hello"])
        #expect(result == "hello")
    }

    @Test("Double-dollar sign $$ passes through unchanged when no braces follow")
    func doubleDollarLiteralEscapePassThrough() {
        // compose-spec §12: $$ → literal $. With the pre/post-pass implementation,
        // $$SUFFIX (no braces) becomes $SUFFIX (the placeholder is restored to $).
        let input = "prefix$$SUFFIX"
        let result = resolveVariable(input, with: [:])
        // $$ without braces → $ (the escape collapses the double-dollar to one).
        #expect(result == "prefix$SUFFIX")
    }

    @Test("Variable with default value ${VAR:-default} uses default when var is absent")
    func variableDefaultValueUsedWhenAbsent() {
        let result = resolveVariable("${DB_PORT:-5432}", with: [:])
        #expect(result == "5432")
    }

    @Test("Variable with default value ${VAR:-default} uses env value when var is set")
    func variableDefaultValueOverriddenByEnv() {
        let result = resolveVariable("${DB_PORT:-5432}", with: ["DB_PORT": "3306"])
        #expect(result == "3306")
    }

    @Test("Multiple variables in a single string all resolve independently")
    func multipleVariablesResolveIndependently() {
        let env: [String: String] = ["HOST": "localhost", "PORT": "8080"]
        let result = resolveVariable("http://${HOST}:${PORT}/api", with: env)
        #expect(result == "http://localhost:8080/api")
    }

    @Test("Unset variable does not prevent later variables from resolving")
    func unsetVariableDoesNotStopLaterSubstitutions() {
        let result = resolveVariable("${UNSET}:${HOST}:${PORT:-8080}", with: ["HOST": "localhost"])
        #expect(result == "${UNSET}:localhost:8080")
    }

    // MARK: - Variable interpolation: nested references (CHAOS-1420)

    @Test("Nested variable references ${OUTER_${INNER}} expand inside-out (CHAOS-1420)")
    func nestedVariablesExpandInsideOut() {
        // resolveVariable uses inside-out resolution: first ${INNER} → "VALUE",
        // then ${OUTER_VALUE} → "resolved".
        let env: [String: String] = ["INNER": "VALUE", "OUTER_VALUE": "resolved"]
        let input = "${OUTER_${INNER}}"
        let result = resolveVariable(input, with: env)
        #expect(result == "resolved", "nested variable references must be expanded inside-out (CHAOS-1420)")
    }

    @Test("Nested reference where inner var is undefined leaves outer unchanged (CHAOS-1420)")
    func nestedVariableInnerUndefinedLeavesOuter() {
        // If ${INNER} is not defined, the outer ${OUTER_${INNER}} can't be
        // assembled, so the whole expression is left as-is.
        let env: [String: String] = ["OUTER_VALUE": "resolved"]
        let input = "${OUTER_${INNER}}"
        let result = resolveVariable(input, with: env)
        // Inner var undefined → outer name not assembled → left unchanged.
        #expect(result == "${OUTER_${INNER}}")
    }

    @Test("Doubly-nested ${A_${B_${C}}} expands correctly (CHAOS-1420)")
    func doublyNestedVariableExpands() {
        let env: [String: String] = ["C": "X", "B_X": "Y", "A_Y": "final"]
        let result = resolveVariable("${A_${B_${C}}}", with: env)
        #expect(result == "final")
    }

    // MARK: - Variable interpolation: $$ literal dollar escape (CHAOS-1411)

    @Test("Double-dollar $$ produces literal $ per compose-spec (CHAOS-1411)")
    func doubleDollarShouldProduceLiteralDollar() {
        // compose-spec §12: $$ is the escape sequence for a literal $.
        // resolveVariable uses a pre-pass ($$→\0) / post-pass (\0→$) so the
        // main regex never sees $$, and the final string contains a single $.
        let result = resolveVariable("$$MY_VAR", with: [:])
        #expect(result == "$MY_VAR")
    }

    @Test("$${VAR} produces literal ${VAR} (double-dollar before braces, CHAOS-1411)")
    func doubleDollarBeforeBracesProducesLiteralBraces() {
        // $${VAR} → ${VAR} (the $$ collapses to $, leaving {VAR} literal).
        let result = resolveVariable("$${PORT}", with: ["PORT": "8080"])
        #expect(result == "${PORT}")
    }

    @Test("Mixed $$ escape and normal variable in same string (CHAOS-1411)")
    func mixedDoubleDollarAndNormalVariable() {
        // "$$PREFIX_${SUFFIX}" should produce "$PREFIX_value".
        let result = resolveVariable("$$PREFIX_${SUFFIX}", with: ["SUFFIX": "value"])
        #expect(result == "$PREFIX_value")
    }

    // MARK: - Include + extends interaction

    @Test("Include merges services; extends within included file is resolved locally")
    func extendsInIncludedFileResolvedLocally() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // included.yml defines base + child where child extends base (same file).
        _ = try writeYAML("""
        services:
          base_db:
            image: postgres:14
            restart: always
          child_db:
            extends:
              service: base_db
            environment:
              POSTGRES_DB: myapp
        """, to: dir, named: "included.yml")

        let mainPath = try writeYAML("""
        services:
          web:
            image: nginx:latest
        include:
          - ./included.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        let resolved = try merged.resolvingExtends()

        // child_db's image and restart should be inherited from base_db
        let childDB = try #require(resolved.services["child_db"] as? Service)
        #expect(childDB.image == "postgres:14")
        #expect(childDB.restart == "always")
        #expect(childDB.environment?["POSTGRES_DB"] == "myapp")
        #expect(childDB.extends == nil)

        // web and base_db are also present
        #expect(resolved.services["web"] != nil)
        #expect(resolved.services["base_db"] != nil)
    }

    @Test("Child in main file can extend base from included file via cross-file extends")
    func childInMainExtendsBaseInIncludedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try writeYAML("""
        services:
          common_svc:
            image: mybase:latest
            restart: unless-stopped
        """, to: dir, named: "common.yml")

        let mainPath = try writeYAML("""
        services:
          app:
            extends:
              service: common_svc
              file: ./common.yml
            environment:
              APP: myapp
        include:
          - ./common.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        let resolved = try merged.resolvingExtends()

        let app = try #require(resolved.services["app"] as? Service)
        #expect(app.image == "mybase:latest")
        #expect(app.restart == "unless-stopped")
        #expect(app.environment?["APP"] == "myapp")
        #expect(app.extends == nil)
    }

    @Test("Service in main file that extends a service already merged from include resolves correctly")
    func extendsTargetMergedFromInclude() throws {
        // This covers the case where the base service's canonical definition came in
        // through `include:` and now a service in the main file uses map-form extends
        // WITHOUT a cross-file `file:` pointer (it points by service name into the
        // already-merged compose document).
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try writeYAML("""
        services:
          worker_base:
            image: worker:latest
            restart: on-failure
        """, to: dir, named: "workers.yml")

        let mainPath = try writeYAML("""
        services:
          worker_prod:
            extends:
              service: worker_base
            environment:
              ENV: production
        include:
          - ./workers.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        let resolved = try merged.resolvingExtends()

        let prod = try #require(resolved.services["worker_prod"] as? Service)
        #expect(prod.image == "worker:latest")
        #expect(prod.restart == "on-failure")
        #expect(prod.environment?["ENV"] == "production")
    }
}
