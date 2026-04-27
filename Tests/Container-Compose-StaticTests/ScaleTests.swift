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

/// Tests for Phase 3F — service.scale expansion.
///
/// The expansion logic lives in ComposeUp.run(), but we test it here by
/// replicating the same algorithm as a pure function so we can exercise it
/// without spinning up containers.
@Suite("Scale Expansion Tests")
struct ScaleTests {

    // MARK: - Helper: replicate the expansion logic from ComposeUp.run()

    /// Mirrors the exact expansion logic used in ComposeUp.run() after topo-sort.
    private func expandForScale(
        _ services: [(serviceName: String, service: Service)]
    ) -> [(serviceName: String, service: Service)] {
        var expanded: [(serviceName: String, service: Service)] = []
        for (name, svc) in services {
            if let scale = svc.scale, scale > 1 {
                for i in 1...scale {
                    expanded.append((serviceName: "\(name)-\(i)", service: svc))
                }
            } else {
                expanded.append((name, svc))
            }
        }
        return expanded
    }

    // MARK: - Parsing helper

    private func decodeService(image: String = "alpine:latest", scale: Int?) throws -> Service {
        return Service(image: image, scale: scale)
    }

    // MARK: - Tests

    @Test("scale = 1 produces a single entry with no numeric suffix")
    func scaleOne() throws {
        let svc = try decodeService(scale: 1)
        let result = expandForScale([("web", svc)])
        #expect(result.count == 1)
        #expect(result[0].serviceName == "web")
    }

    @Test("scale = 3 produces three entries named <svc>-1, <svc>-2, <svc>-3")
    func scaleThree() throws {
        let svc = try decodeService(scale: 3)
        let result = expandForScale([("worker", svc)])
        #expect(result.count == 3)
        #expect(result[0].serviceName == "worker-1")
        #expect(result[1].serviceName == "worker-2")
        #expect(result[2].serviceName == "worker-3")
    }

    @Test("scale absent (nil) produces a single entry with no suffix")
    func scaleNil() throws {
        let svc = try decodeService(scale: nil)
        let result = expandForScale([("db", svc)])
        #expect(result.count == 1)
        #expect(result[0].serviceName == "db")
    }

    @Test("scale = 0 is treated as no scaling (single entry, no suffix)")
    func scaleZero() throws {
        let svc = try decodeService(scale: 0)
        let result = expandForScale([("cache", svc)])
        // scale 0 is not > 1, so the original name is kept
        #expect(result.count == 1)
        #expect(result[0].serviceName == "cache")
    }

    @Test("Multiple services with different scale values expand correctly")
    func multipleServicesWithDifferentScales() throws {
        let web = try decodeService(image: "nginx:latest", scale: 2)
        let db = try decodeService(image: "postgres:15", scale: nil)
        let worker = try decodeService(image: "redis:7", scale: 3)

        let input: [(serviceName: String, service: Service)] = [
            ("web", web),
            ("db", db),
            ("worker", worker),
        ]
        let result = expandForScale(input)

        // web: 2 replicas → web-1, web-2
        // db: no scale → db
        // worker: 3 replicas → worker-1, worker-2, worker-3
        #expect(result.count == 6)

        let names = result.map(\.serviceName)
        #expect(names.contains("web-1"))
        #expect(names.contains("web-2"))
        #expect(names.contains("db"))
        #expect(names.contains("worker-1"))
        #expect(names.contains("worker-2"))
        #expect(names.contains("worker-3"))

        // Order: web entries come first, then db, then worker entries
        #expect(names[0] == "web-1")
        #expect(names[1] == "web-2")
        #expect(names[2] == "db")
        #expect(names[3] == "worker-1")
    }

    @Test("Scale YAML parsing: scale field is decoded correctly")
    func scaleYamlParsing() throws {
        let yaml = """
        services:
          worker:
            image: alpine:latest
            scale: 5
        """
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let svc = try #require(dc.services["worker"] as? Service)
        #expect(svc.scale == 5)
    }

    @Test("Scale value is preserved on all replicas")
    func scalePreservedOnReplicas() throws {
        let svc = try decodeService(scale: 3)
        let result = expandForScale([("api", svc)])
        for entry in result {
            #expect(entry.service.scale == 3)
        }
    }
}
