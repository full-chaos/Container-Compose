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

/// Tests for Phase 3D: LabelsArgs.build — service-level label argv emission.
@Suite("LabelsArgs Tests")
struct LabelsArgsTests {

    // MARK: - Helpers

    private let emptyCompose: DockerCompose = {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        return try! YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }()

    private func makeContext(service: Service) -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "proj",
            containerName: "proj-svc",
            detach: false,
            environmentVariables: [:],
            dockerCompose: emptyCompose,
            composeFilename: nil
        )
    }

    private func build(_ service: Service) -> [String] {
        ComposeUp.LabelsArgs.build(makeContext(service: service))
    }

    // MARK: - nil labels → no flags

    @Test("nil labels produces no args")
    func nilLabelsProducesNoArgs() {
        let svc = Service(image: "alpine", labels: nil)
        #expect(build(svc).isEmpty)
    }

    // MARK: - single label

    @Test("single label emits one --label flag pair")
    func singleLabelEmitsFlag() {
        let svc = Service(image: "alpine", labels: ["com.example.version": "1.0"])
        let args = build(svc)
        #expect(args.count == 2)
        #expect(args[0] == "--label")
        #expect(args[1] == "com.example.version=1.0")
    }

    // MARK: - labels map sorted by key

    @Test("multiple labels are sorted by key")
    func multipleLabelsAreSortedByKey() {
        let svc = Service(image: "alpine", labels: [
            "z.key": "last",
            "a.key": "first",
            "m.key": "middle",
        ])
        let args = build(svc)
        // Expect 3 pairs = 6 elements
        #expect(args.count == 6)
        // Extract the values of each --label pair
        let pairs: [(String, String)] = stride(from: 0, to: args.count - 1, by: 2).map { i in
            (args[i], args[i + 1])
        }
        // All flags should be --label
        #expect(pairs.allSatisfy { $0.0 == "--label" })
        // Values should be in ascending key order
        let labelValues = pairs.map { $0.1 }
        #expect(labelValues == ["a.key=first", "m.key=middle", "z.key=last"])
    }

    // MARK: - empty labels dictionary → no flags

    @Test("empty labels dictionary produces no args")
    func emptyLabelsDictionaryProducesNoArgs() {
        let svc = Service(image: "alpine", labels: [:])
        #expect(build(svc).isEmpty)
    }

    // MARK: - combo: labels + stop_signal

    @Test("labels combine correctly with stop_signal (no interference)")
    func labelsComboWithStopSignal() {
        let svc = Service(image: "alpine", labels: ["env": "test"], stop_signal: "SIGUSR1")

        let labelsArgs = ComposeUp.LabelsArgs.build(makeContext(service: svc))
        let lifecycleArgs = ComposeUp.LifecycleArgs.build(makeContext(service: svc))

        // Labels side: exactly one --label pair
        let labelPairs = stride(from: 0, to: labelsArgs.count - 1, by: 2).map { i in
            (labelsArgs[i], labelsArgs[i + 1])
        }
        #expect(labelPairs.count == 1)
        #expect(labelPairs[0].0 == "--label")
        #expect(labelPairs[0].1 == "env=test")

        // Lifecycle side: --stop-signal warn-skipped after CHAOS-1397 Tier 0 R2
        // (apple/container does not accept --stop-signal). The original
        // intent of this test — "labels and lifecycle don't cross-contaminate
        // each other's args" — is preserved by asserting both sides are clean.
        #expect(!lifecycleArgs.contains("--stop-signal"))
        #expect(!lifecycleArgs.contains("SIGUSR1"))

        // No cross-contamination: labels args must not contain --stop-signal
        #expect(!labelsArgs.contains("--stop-signal"))
        // Lifecycle args must not contain --label
        #expect(!lifecycleArgs.contains("--label"))
    }

    // MARK: - label value with equals sign

    @Test("label value containing '=' is preserved verbatim")
    func labelValueWithEqualsPreserved() {
        let svc = Service(image: "alpine", labels: ["annotation": "key=value"])
        let args = build(svc)
        #expect(args.count == 2)
        #expect(args[1] == "annotation=key=value")
    }
}
