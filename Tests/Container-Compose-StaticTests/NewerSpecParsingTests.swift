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
