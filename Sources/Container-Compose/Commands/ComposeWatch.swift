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
//  ComposeWatch.swift
//  Container-Compose
//
//  Phase 5C — polling-based filesystem watcher for compose watch.
//  TODO: Upgrade to FSEvents or DispatchSource for lower-latency watching.
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import Yams

// MARK: - PathSnapshot

/// A lightweight snapshot of a directory (or file) used to detect changes by polling.
public struct PathSnapshot: Sendable {
    /// Most-recent modification time found in the tree (seconds since epoch).
    public var mtime: TimeInterval
    /// Number of files / entries enumerated in the tree.
    public var fileCount: Int
}

/// Snapshot a path by walking its contents with FileManager.
/// If the path is a plain file the snapshot reflects just that file.
/// - Parameter path: Absolute (or relative) path to snapshot.
/// - Returns: A `PathSnapshot` with `mtime` and `fileCount`.
public func snapshotPath(_ path: String) -> PathSnapshot {
    let fm = FileManager.default

    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
        return PathSnapshot(mtime: 0, fileCount: 0)
    }

    // Single file — just check its mtime.
    if !isDirectory.boolValue {
        let attrs = try? fm.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return PathSnapshot(mtime: mtime, fileCount: 1)
    }

    // Directory — walk the subtree.
    var latestMtime: TimeInterval = 0
    var count = 0

    guard let enumerator = fm.enumerator(atPath: path) else {
        return PathSnapshot(mtime: 0, fileCount: 0)
    }

    for case let relativePath as String in enumerator {
        let fullPath = (path as NSString).appendingPathComponent(relativePath)
        guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { continue }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if mtime > latestMtime { latestMtime = mtime }
        count += 1
    }

    return PathSnapshot(mtime: latestMtime, fileCount: count)
}

// MARK: - WatchLoop

/// An actor that owns polling state and drives the watch loop.
actor WatchLoop {
    /// Current snapshots keyed by watched path.
    var snapshots: [String: PathSnapshot] = [:]

    /// Set the initial snapshot for a path.
    func setSnapshot(_ snapshot: PathSnapshot, forPath path: String) {
        snapshots[path] = snapshot
    }

    /// Check a path against its stored snapshot. Returns the new snapshot if a
    /// change is detected, nil otherwise.
    func checkForChange(at path: String) -> PathSnapshot? {
        let current = snapshotPath(path)
        let previous = snapshots[path]
        let mtimeChanged = current.mtime > (previous?.mtime ?? 0)
        let countChanged = current.fileCount != (previous?.fileCount ?? 0)
        guard mtimeChanged || countChanged else { return nil }
        snapshots[path] = current
        return current
    }

    /// Run the polling loop indefinitely.
    /// - Parameters:
    ///   - rules: Tuples of (serviceName, WatchRule) to monitor.
    ///   - pollInterval: Seconds between polls (default 2 s).
    ///   - dryRun: If true, print actions but do not execute them.
    ///   - cwd: Working directory for shelling out.
    func run(
        rules: [(serviceName: String, rule: WatchRule)],
        pollInterval: TimeInterval = 2,
        dryRun: Bool,
        cwd: String
    ) async {
        // Initialise snapshots.
        for (_, rule) in rules {
            snapshots[rule.path] = snapshotPath(rule.path)
        }

        print("compose watch: monitoring \(rules.count) rule(s) — polling every \(Int(pollInterval))s")
        if dryRun {
            print("compose watch: --dry-run enabled; no actions will be executed")
        }

        while true {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            for (serviceName, rule) in rules {
                guard checkForChange(at: rule.path) != nil else { continue }

                print("[watch] \(serviceName): change detected at '\(rule.path)' → action: \(rule.action.rawValue)")

                await handleAction(rule.action, serviceName: serviceName, rule: rule, dryRun: dryRun, cwd: cwd)
            }
        }
    }

    // MARK: - Private helpers

    private func handleAction(
        _ action: WatchAction,
        serviceName: String,
        rule: WatchRule,
        dryRun: Bool,
        cwd: String
    ) async {
        switch action {
        case .rebuild:
            if dryRun {
                print("[dry-run] would run: container-compose build \(serviceName)")
                print("[dry-run] would run: container-compose up -d \(serviceName)")
            } else {
                print("[watch] rebuilding \(serviceName)…")
                await shell(["container-compose", "build", serviceName], cwd: cwd)
                print("[watch] restarting \(serviceName)…")
                await shell(["container-compose", "up", "-d", serviceName], cwd: cwd)
            }

        case .sync:
            // Full sync requires a `container cp`-equivalent which is not yet
            // available in the ContainerClient API. Log a clear diagnostic.
            if dryRun {
                print("[dry-run] would sync '\(rule.path)' → container:\(rule.target ?? "<no target>") for \(serviceName)")
            } else {
                print(
                    "[watch] Note: 'sync' action for '\(serviceName)' requires a 'container cp' equivalent " +
                    "which is not yet available. Consider using 'rebuild' instead."
                )
            }

        case .syncRestart:
            if dryRun {
                print("[dry-run] would sync '\(rule.path)' then restart \(serviceName)")
            } else {
                print(
                    "[watch] Note: 'sync+restart' for '\(serviceName)' is partially supported. " +
                    "File sync requires 'container cp' equivalent (not yet available). " +
                    "Only restart will be attempted."
                )
                await shell(["container-compose", "restart", serviceName], cwd: cwd)
            }

        case .syncExec:
            if dryRun {
                let cmd = rule.exec?.command?.joined(separator: " ") ?? "<no command>"
                print("[dry-run] would sync '\(rule.path)' then exec '\(cmd)' in \(serviceName)")
            } else {
                print(
                    "[watch] Note: 'sync+exec' for '\(serviceName)' is partially supported. " +
                    "File sync requires 'container cp' equivalent (not yet available). " +
                    "Only exec will be attempted if command is provided."
                )
                if let execCmd = rule.exec?.command, !execCmd.isEmpty {
                    await shell(["container-compose", "exec", serviceName] + execCmd, cwd: cwd)
                }
            }

        case .restart:
            if dryRun {
                print("[dry-run] would run: container-compose restart \(serviceName)")
            } else {
                print("[watch] restarting \(serviceName)…")
                await shell(["container-compose", "restart", serviceName], cwd: cwd)
            }
        }
    }

    /// Fire-and-forget shell execution.
    private func shell(_ args: [String], cwd: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = args
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            proc.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]) { _, new in new }
            proc.terminationHandler = { _ in continuation.resume() }
            do {
                try proc.run()
            } catch {
                print("[watch] shell error: \(error)")
                continuation.resume()
            }
        }
    }
}

// MARK: - ComposeWatch

public struct ComposeWatch: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "watch",
        abstract: "Monitor file changes and update services"
    )

    @Argument(help: "Specify the services to watch (default: all services with develop.watch)")
    var services: [String] = []

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @Flag(name: [.long], help: "Print actions that would be taken without executing them")
    var dryRun: Bool = false

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var logging: Flags.Logging

    // MARK: - Helpers

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    private var cwdURL: URL { URL(fileURLWithPath: cwd) }

    private static let supportedComposeFilenames = [
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    ]

    private var composePath: String {
        if let composeFilename {
            return resolvedPath(for: composeFilename, relativeTo: cwdURL)
        }
        for filename in Self.supportedComposeFilenames {
            let candidate = cwdURL.appending(path: filename).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return cwdURL.appending(path: Self.supportedComposeFilenames[0]).path
    }

    // MARK: - Run

    public mutating func run() async throws {
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        var resolvedServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, svc in
            guard let svc else { return nil }
            return (name, svc)
        }

        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        resolvedServices = Service.filterByProfiles(resolvedServices, activeProfiles: activeProfiles)

        // Filter to requested services when specified.
        if !services.isEmpty {
            resolvedServices = resolvedServices.filter { services.contains($0.serviceName) }
        }

        // Collect all watch rules.
        var watchRules: [(serviceName: String, rule: WatchRule)] = []
        for (serviceName, service) in resolvedServices {
            guard let rules = service.develop?.watch else { continue }
            for rule in rules {
                watchRules.append((serviceName: serviceName, rule: rule))
            }
        }

        if watchRules.isEmpty {
            print("compose watch: no services with 'develop.watch' rules found — nothing to watch.")
            return
        }

        // Resolve paths relative to the compose file directory.
        let composeDir = URL(fileURLWithPath: composePath).deletingLastPathComponent().path
        let resolvedRules: [(serviceName: String, rule: WatchRule)] = watchRules.map { serviceName, rule in
            let resolvedPath: String
            if rule.path.hasPrefix("/") {
                resolvedPath = rule.path
            } else {
                resolvedPath = URL(fileURLWithPath: rule.path, relativeTo: URL(fileURLWithPath: composeDir))
                    .standardized.path
            }
            let resolvedRule = WatchRule(
                path: resolvedPath,
                action: rule.action,
                target: rule.target,
                ignore: rule.ignore,
                exec: rule.exec
            )
            return (serviceName: serviceName, rule: resolvedRule)
        }

        let loop = WatchLoop()
        await loop.run(rules: resolvedRules, dryRun: dryRun, cwd: cwd)
    }
}
