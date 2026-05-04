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
@testable import ContainerComposeCore

// MARK: - CHAOS-1419: Pin extends-in-included-file resolution behavior (F4)
//
// Context:
//   When a compose file uses `include:`, all included services are merged into
//   a single DockerCompose document BEFORE `resolvingExtends()` is called.
//   (See DockerCompose.loadAndMerge + resolvingExtends in DockerCompose.swift.)
//
//   This means that:
//   (a) extends chains within a single included file are resolved in the merged
//       document (not pre-resolved in isolation per file).
//   (b) extends chains that span files (A in included.yml extends B in main.yml)
//       are also resolved correctly after merge.
//
//   These tests pin that contract so that future refactors to loadAndMerge or
//   resolvingExtends cannot silently break the resolution order.
//
//   If any test below reveals an actual bug (rather than pinning current behavior),
//   it should NOT be fixed in this PR — file a follow-up ticket and mark the test
//   with .disabled(reason:).

@Suite("Extends in Included File Resolution")
struct ExtendsInIncludedFileTests {

    // MARK: - Helpers

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

    // MARK: - A → B → C chain, all in same included file

    @Test("Three-service chain A→B→C in included file all inherit from base correctly (CHAOS-1419)")
    func threeServiceChainInIncludedFileResolves() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // included.yml: C is the base; B extends C; A extends B.
        // Resolution must correctly propagate C's fields through B to A.
        _ = try writeYAML("""
        services:
          svc_c:
            image: base-image:3.18
            restart: always
            environment:
              BASE_KEY: base_val
          svc_b:
            extends:
              service: svc_c
            environment:
              MID_KEY: mid_val
          svc_a:
            extends:
              service: svc_b
            environment:
              TOP_KEY: top_val
        """, to: dir, named: "chain.yml")

        let mainPath = try writeYAML("""
        services:
          coordinator:
            image: nginx:latest
        include:
          - ./chain.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        let resolved = try merged.resolvingExtends()

        // svc_a should inherit image and restart from svc_c (via svc_b)
        // and carry its own environment key.
        let svcA = try #require(resolved.services["svc_a"] as? Service)
        #expect(svcA.image == "base-image:3.18",
                "svc_a must inherit image from svc_c through svc_b")
        #expect(svcA.restart == "always",
                "svc_a must inherit restart from svc_c through svc_b")
        // Each service in the chain adds its own env key; after extends merging
        // svc_a should see its own TOP_KEY.
        #expect(svcA.environment?["TOP_KEY"] == "top_val")
        // extends field is cleared after resolution.
        #expect(svcA.extends == nil)

        // svc_b should inherit from svc_c only.
        let svcB = try #require(resolved.services["svc_b"] as? Service)
        #expect(svcB.image == "base-image:3.18")
        #expect(svcB.restart == "always")
        #expect(svcB.environment?["MID_KEY"] == "mid_val")
        #expect(svcB.extends == nil)

        // svc_c is the untouched base.
        let svcC = try #require(resolved.services["svc_c"] as? Service)
        #expect(svcC.image == "base-image:3.18")
        #expect(svcC.extends == nil)

        // coordinator from main file is unaffected.
        #expect(resolved.services["coordinator"] != nil)
    }

    // MARK: - A in included.yml extends B in different included.yml

    @Test("Service in one included file can extend service in second included file after merge (CHAOS-1419)")
    func crossIncludeExtendsResolves() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // base.yml provides the base service.
        _ = try writeYAML("""
        services:
          db_base:
            image: postgres:14
            restart: on-failure
        """, to: dir, named: "base.yml")

        // derived.yml extends from db_base which is in base.yml (a different include).
        // After merge, db_base is present in the merged document, so this should resolve.
        _ = try writeYAML("""
        services:
          db_prod:
            extends:
              service: db_base
            environment:
              POSTGRES_DB: production
        """, to: dir, named: "derived.yml")

        let mainPath = try writeYAML("""
        services: {}
        include:
          - ./base.yml
          - ./derived.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        let resolved = try merged.resolvingExtends()

        let dbProd = try #require(resolved.services["db_prod"] as? Service)
        #expect(dbProd.image == "postgres:14",
                "db_prod must inherit image from db_base in base.yml")
        #expect(dbProd.restart == "on-failure",
                "db_prod must inherit restart from db_base")
        #expect(dbProd.environment?["POSTGRES_DB"] == "production")
        #expect(dbProd.extends == nil)
    }

    // MARK: - A in included file extends B in main file (cross-boundary)

    @Test("Service in included file can extend service defined only in main file (CHAOS-1419)")
    func includedServiceExtendsMainFileService() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // worker.yml has a service that extends `base_worker` — but base_worker
        // is only defined in the main compose.yml, not in the included file.
        // After loadAndMerge, base_worker is in the merged document, so this works.
        _ = try writeYAML("""
        services:
          task_runner:
            extends:
              service: base_worker
            environment:
              ROLE: task
        """, to: dir, named: "workers.yml")

        let mainPath = try writeYAML("""
        services:
          base_worker:
            image: worker:latest
            restart: unless-stopped
        include:
          - ./workers.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        let resolved = try merged.resolvingExtends()

        let runner = try #require(resolved.services["task_runner"] as? Service)
        #expect(runner.image == "worker:latest")
        #expect(runner.restart == "unless-stopped")
        #expect(runner.environment?["ROLE"] == "task")
        #expect(runner.extends == nil)
    }

    // MARK: - Child field precedence in included file chain

    @Test("Child's own fields override inherited fields in an A→B chain in included file (CHAOS-1419)")
    func childOverridesInheritedFieldInIncludedChain() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try writeYAML("""
        services:
          service_base:
            image: alpine:3.18
            restart: always
            command: ["/bin/sh"]
          service_child:
            extends:
              service: service_base
            image: alpine:edge
            restart: unless-stopped
        """, to: dir, named: "services.yml")

        let mainPath = try writeYAML("""
        services: {}
        include:
          - ./services.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        let resolved = try merged.resolvingExtends()

        let child = try #require(resolved.services["service_child"] as? Service)
        // child's own image wins over base's image
        #expect(child.image == "alpine:edge",
                "child image must override base image")
        // child's own restart wins over base's restart
        #expect(child.restart == "unless-stopped",
                "child restart must override base restart")
        // command is inherited (child does not override it)
        #expect(child.command == ["/bin/sh"],
                "child must inherit command from base when not overriding")
        #expect(child.extends == nil)
    }

    // MARK: - Cycle detection within included file

    @Test("Cycle A→B, B→A within a single included file throws (CHAOS-1419)")
    func cycleWithinIncludedFileThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try writeYAML("""
        services:
          alpha:
            image: alpine
            extends:
              service: beta
          beta:
            image: alpine
            extends:
              service: alpha
        """, to: dir, named: "loop.yml")

        let mainPath = try writeYAML("""
        services:
          web:
            image: nginx
        include:
          - ./loop.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        #expect(throws: (any Error).self) {
            _ = try merged.resolvingExtends()
        }
    }

    // MARK: - extends.file pointer in included file context

    @Test("Service in included file using extends.file pointer resolves from the external file (CHAOS-1419)")
    func extendsFilePointerInIncludedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // base.yml is the cross-file extends target.
        _ = try writeYAML("""
        services:
          cross_base:
            image: cross:latest
            restart: on-failure
        """, to: dir, named: "base.yml")

        // consumers.yml references base.yml via extends.file.
        _ = try writeYAML("""
        services:
          consumer:
            extends:
              service: cross_base
              file: ./base.yml
            environment:
              CONSUMER: yes
        """, to: dir, named: "consumers.yml")

        let mainPath = try writeYAML("""
        services: {}
        include:
          - ./consumers.yml
        """, to: dir, named: "compose.yml")

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath)
        let resolved = try merged.resolvingExtends()

        let consumer = try #require(resolved.services["consumer"] as? Service)
        #expect(consumer.image == "cross:latest")
        #expect(consumer.restart == "on-failure")
        #expect(consumer.environment?["CONSUMER"] == "yes")
        #expect(consumer.extends == nil)
    }
}
