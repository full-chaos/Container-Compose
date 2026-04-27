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
import Yams
@testable import ContainerComposeCore

/// Decodes every YAML file under `Sample Compose Files/` to confirm the
/// shipped examples remain valid as the schema evolves. If any sample
/// stops parsing this is a regression — either fix the sample or fix the
/// schema, but don't ignore it.
@Suite("Sample Compose Files decode")
struct SampleComposeFilesTests {

    /// Walk up from this source file to the package root, then enumerate
    /// `Sample Compose Files/`. Returns each *.yml / *.yaml URL.
    private static func sampleFiles() -> [URL] {
        // Tests/Container-Compose-StaticTests/SampleComposeFilesTests.swift
        // → packageRoot is two directories up from this file's directory.
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile
            .deletingLastPathComponent()    // …/Container-Compose-StaticTests
            .deletingLastPathComponent()    // …/Tests
            .deletingLastPathComponent()    // package root
        let samplesDir = packageRoot.appending(path: "Sample Compose Files")

        guard let enumerator = FileManager.default.enumerator(
            at: samplesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext == "yml" || ext == "yaml" {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    @Test("Every sample compose YAML decodes into DockerCompose")
    func everySampleDecodes() throws {
        let urls = Self.sampleFiles()
        try #require(!urls.isEmpty, "Expected at least one sample compose file under Sample Compose Files/")

        var decoded: [String: DockerCompose] = [:]
        for url in urls {
            let yaml = try String(contentsOf: url, encoding: .utf8)
            let dc: DockerCompose
            do {
                dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
            } catch {
                Issue.record("Failed to decode sample at \(url.path): \(error)")
                continue
            }
            decoded[url.lastPathComponent + " (" + url.deletingLastPathComponent().lastPathComponent + ")"] = dc
        }

        #expect(decoded.count == urls.count, "Some samples failed to decode: see recorded issues above.")
    }

    @Test("Healthchecked Web sample uses the depends_on object form (anchor)")
    func healthcheckedWebUsesObjectForm() throws {
        let urls = Self.sampleFiles().filter { $0.path.contains("Healthchecked Web") }
        try #require(!urls.isEmpty, "Healthchecked Web sample missing.")
        let yaml = try String(contentsOf: urls[0], encoding: .utf8)
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let app = try #require(dc.services["app"]!, "Sample must have an 'app' service.")
        let dependsOn = try #require(app.dependsOn, "'app' must declare depends_on.")
        let dbEntry = try #require(dependsOn.entries["db"], "'app' must depend on 'db'.")
        #expect(dbEntry.condition == .serviceHealthy)
        #expect(dbEntry.required == true)
        #expect(dbEntry.restart == true)
    }

    @Test("Profiles sample tags services with the expected profile names")
    func profilesSample() throws {
        let urls = Self.sampleFiles().filter { $0.path.contains("Profiles") }
        try #require(!urls.isEmpty)
        let yaml = try String(contentsOf: urls[0], encoding: .utf8)
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        // web has no profiles → always-on
        #expect(dc.services["web"]??.profiles == nil)
        // debugger only in dev
        #expect(dc.services["debugger"]??.profiles == ["dev"])
        // ops-shell in both dev and prod
        let opsShell = try #require(dc.services["ops-shell"]!)
        #expect(Set(opsShell.profiles ?? []) == ["dev", "prod"])
    }

    @Test("Resource limits sample uses every Phase 2B field group")
    func resourceLimitsSample() throws {
        let urls = Self.sampleFiles().filter { $0.path.contains("Resource limits") }
        try #require(!urls.isEmpty)
        let yaml = try String(contentsOf: urls[0], encoding: .utf8)
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let trainer = try #require(dc.services["trainer"]!)
        #expect(trainer.cpus_top == 1.5)
        #expect(trainer.mem_limit == "512m")
        #expect(trainer.pids_limit == 200)
        #expect(trainer.ulimits?["nofile"] != nil)
        #expect(trainer.ulimits?["nproc"]?.hard == 2048)
    }
}
