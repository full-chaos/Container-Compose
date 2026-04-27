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

/// Tests for Phase 3F — service.extends resolution.
@Suite("Extends Resolution Tests")
struct ExtendsTests {

    // MARK: - Helpers

    private func decode(_ yaml: String) throws -> DockerCompose {
        try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    private func resolved(_ yaml: String) throws -> DockerCompose {
        try decode(yaml).resolvingExtends()
    }

    // MARK: - Map-form extends

    @Test("Service inherits image and command from base via map-form extends")
    func mapFormExtends() throws {
        let yaml = """
        services:
          base:
            image: alpine:3.18
            command: ["echo", "hello"]
          child:
            extends:
              service: base
        """
        let dc = try resolved(yaml)
        let child = try #require(dc.services["child"] as? Service)
        #expect(child.image == "alpine:3.18")
        #expect(child.command == ["echo", "hello"])
    }

    @Test("Child's own fields override base fields")
    func childOverridesBase() throws {
        let yaml = """
        services:
          base:
            image: alpine:3.18
            command: ["echo", "hello"]
            restart: always
          child:
            image: alpine:edge
            extends:
              service: base
        """
        let dc = try resolved(yaml)
        let child = try #require(dc.services["child"] as? Service)
        // child.image wins over base.image
        #expect(child.image == "alpine:edge")
        // command is inherited from base
        #expect(child.command == ["echo", "hello"])
        // restart is inherited from base
        #expect(child.restart == "always")
    }

    // MARK: - Shorthand string extends

    @Test("Shorthand extends (just a string) works like map-form extends")
    func shorthandExtends() throws {
        let yaml = """
        services:
          base:
            image: nginx:latest
            restart: unless-stopped
          child:
            extends: base
        """
        let dc = try resolved(yaml)
        let child = try #require(dc.services["child"] as? Service)
        #expect(child.image == "nginx:latest")
        #expect(child.restart == "unless-stopped")
    }

    @Test("ExtendsConfig decodes shorthand string form")
    func extendsConfigShorthand() throws {
        let yaml = "base"
        let cfg = try YAMLDecoder().decode(ExtendsConfig.self, from: yaml)
        #expect(cfg.service == "base")
        #expect(cfg.file == nil)
    }

    @Test("ExtendsConfig decodes map form with file")
    func extendsConfigMapWithFile() throws {
        let yaml = """
        service: base
        file: ./other.yml
        """
        let cfg = try YAMLDecoder().decode(ExtendsConfig.self, from: yaml)
        #expect(cfg.service == "base")
        #expect(cfg.file == "./other.yml")
    }

    // MARK: - Cycle detection

    @Test("Cycle detection: A extends B, B extends A throws")
    func cycleDetected() throws {
        let yaml = """
        services:
          a:
            image: alpine
            extends:
              service: b
          b:
            image: alpine
            extends:
              service: a
        """
        let dc = try decode(yaml)
        #expect(throws: (any Error).self) {
            _ = try dc.resolvingExtends()
        }
    }

    @Test("Direct self-extends throws a cycle error")
    func selfExtendsCycle() throws {
        let yaml = """
        services:
          a:
            image: alpine
            extends:
              service: a
        """
        let dc = try decode(yaml)
        #expect(throws: (any Error).self) {
            _ = try dc.resolvingExtends()
        }
    }

    // MARK: - Missing service

    @Test("Extending a non-existent service throws")
    func missingBaseService() throws {
        let yaml = """
        services:
          child:
            extends:
              service: nonexistent
        """
        // Note: the `child` service has no image/build/extends-resolved, so
        // parsing might throw first. We test resolvingExtends if parsing passes.
        do {
            let dc = try decode(yaml)
            #expect(throws: (any Error).self) {
                _ = try dc.resolvingExtends()
            }
        } catch {
            // Decoding itself threw — that's also acceptable since there's no image/build.
            // The important thing is that it did throw.
        }
    }

    // MARK: - Cross-file extends (warn + skip)

    @Test("Cross-file extends is skipped with a warning (no crash)")
    func crossFileExtendsSkipped() throws {
        let yaml = """
        services:
          child:
            image: alpine:latest
            extends:
              service: base
              file: ./other.yml
        """
        // Should not throw — cross-file extends is warned and skipped.
        let dc = try resolved(yaml)
        let child = try #require(dc.services["child"] as? Service)
        // The child's own image should still be present.
        #expect(child.image == "alpine:latest")
        // extends should be cleared after resolution.
        #expect(child.extends == nil)
    }

    // MARK: - Post-resolution cleanup

    @Test("Resolved services have extends field cleared")
    func extendsFieldClearedAfterResolution() throws {
        let yaml = """
        services:
          base:
            image: alpine:latest
          child:
            extends: base
        """
        let dc = try resolved(yaml)
        let child = try #require(dc.services["child"] as? Service)
        #expect(child.extends == nil)

        let base = try #require(dc.services["base"] as? Service)
        #expect(base.extends == nil)
    }
}
