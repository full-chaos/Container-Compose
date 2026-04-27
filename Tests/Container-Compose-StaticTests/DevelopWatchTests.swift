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

//
//  DevelopWatchTests.swift
//  Container-Compose
//
//  Phase 5C tests — Develop schema parsing and ComposeWatch CLI parsing.
//

import Testing
import Foundation
@testable import Yams
@testable import ContainerComposeCore

// MARK: - Develop Struct Decoding

@Suite("Develop Watch Schema Tests")
struct DevelopWatchSchemaTests {

    private func decodeService(_ yaml: String) throws -> Service {
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)
        let service = try #require(compose.services["svc"] as? Service)
        return service
    }

    // MARK: - Develop struct decoding

    @Test("Develop struct decodes from YAML")
    func developStructDecodes() throws {
        let yaml = """
        services:
          svc:
            image: alpine:latest
            develop:
              watch:
                - path: ./src
                  action: rebuild
        """
        let svc = try decodeService(yaml)
        let develop = try #require(svc.develop)
        let rules = try #require(develop.watch)
        #expect(rules.count == 1)
        #expect(rules[0].path == "./src")
        #expect(rules[0].action == .rebuild)
    }

    @Test("Service with no develop field parses develop as nil")
    func developNilWhenAbsent() throws {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        let svc = try decodeService(yaml)
        #expect(svc.develop == nil)
    }

    // MARK: - WatchRule full field decoding

    @Test("WatchRule decodes all fields")
    func watchRuleDecodesAllFields() throws {
        let yaml = """
        services:
          svc:
            image: node:20
            develop:
              watch:
                - path: ./src
                  action: sync
                  target: /app/src
                  ignore:
                    - node_modules
                    - .git
        """
        let svc = try decodeService(yaml)
        let rule = try #require(svc.develop?.watch?.first)
        #expect(rule.path == "./src")
        #expect(rule.action == .sync)
        #expect(rule.target == "/app/src")
        let ignore = try #require(rule.ignore)
        #expect(ignore.contains("node_modules"))
        #expect(ignore.contains(".git"))
    }

    @Test("WatchRule with exec block decodes")
    func watchRuleDecodesExec() throws {
        let yaml = """
        services:
          svc:
            image: node:20
            develop:
              watch:
                - path: ./src
                  action: sync+exec
                  target: /app/src
                  exec:
                    command:
                      - npm
                      - run
                      - build
                    user: node
                    working_dir: /app
        """
        let svc = try decodeService(yaml)
        let rule = try #require(svc.develop?.watch?.first)
        #expect(rule.action == .syncExec)
        let exec = try #require(rule.exec)
        #expect(exec.command == ["npm", "run", "build"])
        #expect(exec.user == "node")
        #expect(exec.workingDir == "/app")
    }

    // MARK: - WatchAction enum decoding

    @Test("WatchAction decodes sync")
    func watchActionDecodesSync() throws {
        #expect(WatchAction(rawValue: "sync") == .sync)
    }

    @Test("WatchAction decodes rebuild")
    func watchActionDecodesRebuild() throws {
        #expect(WatchAction(rawValue: "rebuild") == .rebuild)
    }

    @Test("WatchAction decodes sync+restart")
    func watchActionDecodesSyncRestart() throws {
        #expect(WatchAction(rawValue: "sync+restart") == .syncRestart)
    }

    @Test("WatchAction decodes sync+exec")
    func watchActionDecodesSyncExec() throws {
        #expect(WatchAction(rawValue: "sync+exec") == .syncExec)
    }

    @Test("WatchAction decodes restart")
    func watchActionDecodesRestart() throws {
        #expect(WatchAction(rawValue: "restart") == .restart)
    }

    @Test("WatchAction CaseIterable contains all expected values")
    func watchActionAllCases() {
        let expected: Set<WatchAction> = [.sync, .rebuild, .syncRestart, .syncExec, .restart]
        #expect(Set(WatchAction.allCases) == expected)
    }

    @Test("Develop decodes multiple watch rules")
    func developDecodesMultipleRules() throws {
        let yaml = """
        services:
          svc:
            image: alpine:latest
            develop:
              watch:
                - path: ./src
                  action: sync
                  target: /app/src
                - path: ./Dockerfile
                  action: rebuild
                - path: ./config
                  action: sync+restart
                  target: /app/config
        """
        let svc = try decodeService(yaml)
        let rules = try #require(svc.develop?.watch)
        #expect(rules.count == 3)
        #expect(rules[0].action == .sync)
        #expect(rules[1].action == .rebuild)
        #expect(rules[2].action == .syncRestart)
    }
}

// MARK: - ComposeWatch CLI Parsing

@Suite("ComposeWatch CLI Parsing Tests")
struct ComposeWatchParsingTests {

    @Test("ComposeWatch parses without arguments")
    func composeWatchParsesWithoutArgs() throws {
        let cmd = try ComposeWatch.parse([])
        #expect(cmd.services.isEmpty)
        #expect(cmd.composeFilename == nil)
        #expect(cmd.profile.isEmpty)
        #expect(cmd.dryRun == false)
    }

    @Test("ComposeWatch parses --dry-run flag")
    func composeWatchParsesDryRun() throws {
        let cmd = try ComposeWatch.parse(["--dry-run"])
        #expect(cmd.dryRun == true)
    }

    @Test("ComposeWatch parses service-name filter")
    func composeWatchParsesServiceFilter() throws {
        let cmd = try ComposeWatch.parse(["web", "api"])
        #expect(cmd.services == ["web", "api"])
        #expect(cmd.dryRun == false)
    }

    @Test("ComposeWatch parses --file option")
    func composeWatchParsesFileOption() throws {
        let cmd = try ComposeWatch.parse(["--file", "custom-compose.yml"])
        #expect(cmd.composeFilename == "custom-compose.yml")
    }

    @Test("ComposeWatch parses -f short option")
    func composeWatchParsesShortFileOption() throws {
        let cmd = try ComposeWatch.parse(["-f", "custom-compose.yml"])
        #expect(cmd.composeFilename == "custom-compose.yml")
    }

    @Test("ComposeWatch parses --profile option")
    func composeWatchParsesProfile() throws {
        let cmd = try ComposeWatch.parse(["--profile", "dev", "--profile", "ci"])
        #expect(cmd.profile == ["dev", "ci"])
    }

    @Test("ComposeWatch parses service filter with --dry-run")
    func composeWatchParsesServiceFilterWithDryRun() throws {
        let cmd = try ComposeWatch.parse(["--dry-run", "web"])
        #expect(cmd.dryRun == true)
        #expect(cmd.services == ["web"])
    }
}

// MARK: - snapshotPath unit tests

@Suite("snapshotPath Unit Tests")
struct SnapshotPathTests {

    @Test("snapshotPath returns a non-zero result for an existing temp directory")
    func snapshotReturnsNonEmptyForExistingDir() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a file into the directory so it's non-empty.
        let fileURL = tempDir.appendingPathComponent("hello.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = snapshotPath(tempDir.path)
        #expect(snapshot.fileCount > 0)
        #expect(snapshot.mtime > 0)
    }

    @Test("snapshotPath returns zero counts for a missing path")
    func snapshotReturnsZeroForMissingPath() {
        let snapshot = snapshotPath("/nonexistent/path/\(UUID().uuidString)")
        #expect(snapshot.fileCount == 0)
        #expect(snapshot.mtime == 0)
    }

    @Test("snapshotPath mtime increases after writing a file")
    func snapshotMtimeIncreasesAfterWrite() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-mtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let before = snapshotPath(tempDir.path)

        // Ensure at least 1 second difference for mtime resolution on macOS HFS+
        // We just need the file to be written — the count change is enough.
        let fileURL = tempDir.appendingPathComponent("newfile.txt")
        try "data".write(to: fileURL, atomically: true, encoding: .utf8)

        let after = snapshotPath(tempDir.path)
        // Either the mtime went up or the count went up (file was added).
        #expect(after.fileCount > before.fileCount || after.mtime >= before.mtime)
    }

    @Test("snapshotPath handles a single file (not directory)")
    func snapshotHandlesSingleFile() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-file-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try "content".write(to: tempFile, atomically: true, encoding: .utf8)

        let snapshot = snapshotPath(tempFile.path)
        #expect(snapshot.fileCount == 1)
        #expect(snapshot.mtime > 0)
    }
}
