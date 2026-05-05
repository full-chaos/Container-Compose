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

@Suite("Newer compose-spec parsing tests")
struct NewerSpecParsingTests {
    private func decode(_ yaml: String) throws -> DockerCompose {
        try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    private func service(named name: String = "svc", in compose: DockerCompose) throws -> Service {
        try #require(compose.services[name] ?? nil)
    }

    @Test("Parse top-level models block")
    func parseTopLevelModels() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
        models:
          llama:
            name: local-llama
            model: ai/llama:latest
            context_size: 4096
            runtime_flags:
              - --gpu
        """

        let compose = try decode(yaml)
        let model = try #require(compose.models?["llama"])
        #expect(model.name == "local-llama")
        #expect(model.model == "ai/llama:latest")
        #expect(model.context_size == 4096)
        #expect(model.runtime_flags == ["--gpu"])
    }

    @Test("File loading preserves top-level models")
    func fileLoadingPreservesTopLevelModels() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let composePath = dir.appendingPathComponent("compose.yaml")
        try """
        services:
          app:
            image: alpine:latest
        models:
          llama:
            model: ai/llama:latest
        """.write(to: composePath, atomically: true, encoding: .utf8)

        let compose = try DockerCompose.loadAndMerge(mainPath: composePath.path)
        #expect(compose.models?["llama"]?.model == "ai/llama:latest")
    }

    @Test("loadAndMerge preserves and overrides top-level models across include")
    func loadAndMergeMergesTopLevelModels() throws {
        // Per DockerCompose.mergeTwo (and the loadAndMerge callsite that
        // applies the main file last), the override wins on key collision.
        // For include:, the main file is the override — so a model defined in
        // both places must end up with the main file's definition, while
        // models present only in the included file are preserved.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let includedPath = dir.appendingPathComponent("included.yaml")
        try """
        services:
          worker:
            image: alpine:worker
        models:
          llama:
            model: ai/llama:included
          embed:
            model: ai/embed:latest
        """.write(to: includedPath, atomically: true, encoding: .utf8)

        let mainPath = dir.appendingPathComponent("compose.yaml")
        try """
        services:
          app:
            image: alpine:latest
        models:
          llama:
            model: ai/llama:main
        include:
          - ./included.yaml
        """.write(to: mainPath, atomically: true, encoding: .utf8)

        let merged = try DockerCompose.loadAndMerge(mainPath: mainPath.path)

        // Both models must be present in the merged document.
        #expect(merged.models?.count == 2)

        // `embed` exists only in the included file — must survive the merge.
        #expect(merged.models?["embed"]?.model == "ai/embed:latest")

        // `llama` exists in both files — main (override) wins per mergeTwo.
        #expect(merged.models?["llama"]?.model == "ai/llama:main")
    }

    @Test("Encoding preserves top-level models")
    func encodingPreservesTopLevelModels() throws {
        let compose = DockerCompose(
            version: nil,
            name: nil,
            services: ["app": Service(image: "alpine:latest")],
            models: ["llama": Model(name: nil, model: "ai/llama:latest", context_size: nil, runtime_flags: nil)],
            volumes: nil,
            networks: nil,
            configs: nil,
            secrets: nil
        )

        let encoded = try YAMLEncoder().encode(compose)
        #expect(encoded.contains("models:"))
        #expect(encoded.contains("llama:"))
        #expect(encoded.contains("model: ai/llama:latest"))
    }

    @Test("Parse service.models list form")
    func parseServiceModelsList() throws {
        let yaml = """
        services:
          svc:
            image: alpine:latest
            models:
              - llama
              - embeddings
        """

        let svc = try service(in: decode(yaml))
        #expect(svc.models == ["llama", "embeddings"])
    }

    @Test("Parse service.provider object form")
    func parseServiceProviderObject() throws {
        let yaml = """
        services:
          svc:
            image: alpine:latest
            provider:
              type: model-runner
              options:
                model: llama
                endpoint: http://localhost:8080
        """

        let provider = try #require(service(in: decode(yaml)).provider)
        #expect(provider.type == "model-runner")
        #expect(provider.options?["model"] == "llama")
        #expect(provider.options?["endpoint"] == "http://localhost:8080")
    }

    @Test("Parse provider-only service without image or build")
    func parseProviderOnlyService() throws {
        let yaml = """
        services:
          svc:
            provider:
              type: model-runner
              options:
                model: llama
        """

        let svc = try service(in: decode(yaml))
        #expect(svc.image == nil)
        #expect(svc.build == nil)
        #expect(svc.provider?.type == "model-runner")
    }
}
