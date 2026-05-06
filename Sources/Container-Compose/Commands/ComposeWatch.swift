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
//  Phase 5C — filesystem watcher for compose watch.
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
    struct RemoteContext: Sendable {
        let projectName: String
        let explicitContainerNames: [String: String]
    }

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
    func runPolling(
        rules: [(serviceName: String, rule: WatchRule)],
        pollInterval: TimeInterval = 2,
        dryRun: Bool,
        cwd: String,
        remoteContext: RemoteContext? = nil,
        maxPolls: Int? = nil
    ) async {
        // Initialise snapshots.
        for (_, rule) in rules {
            snapshots[rule.path] = snapshotPath(rule.path)
        }

        print("compose watch: monitoring \(rules.count) rule(s) — polling every \(Int(pollInterval))s")
        if dryRun {
            print("compose watch: --dry-run enabled; no actions will be executed")
        }

        var completedPolls = 0
        while !Task.isCancelled {
            if let maxPolls, completedPolls >= maxPolls { break }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if Task.isCancelled { break }
            completedPolls += 1

            for (serviceName, rule) in rules {
                guard checkForChange(at: rule.path) != nil else { continue }

                print("[watch] \(serviceName): change detected at '\(rule.path)' → action: \(rule.action.rawValue)")

                await handleAction(rule.action, serviceName: serviceName, rule: rule, dryRun: dryRun, cwd: cwd, remoteContext: remoteContext)
            }
        }
    }

    /// Run the FSEvents-backed watch loop indefinitely. FSEvents reports
    /// recursive file-level events for the watched root paths; action handling
    /// intentionally remains identical to the polling path once a rule matches.
    func runFSEvents(
        rules: [(serviceName: String, rule: WatchRule)],
        dryRun: Bool,
        cwd: String,
        remoteContext: RemoteContext? = nil,
        watcher: any FSWatcher = FSWatcherEnvironment.current
    ) async {
        let paths = Array(Set(rules.map { $0.rule.path })).sorted()

        print(
            "compose watch: monitoring \(rules.count) rule(s) — FSEvents " +
                "(\(Int(FSEventsWatcher.coalesceInterval * 1000))ms coalesce)"
        )
        if dryRun {
            print("compose watch: --dry-run enabled; no actions will be executed")
        }

        for await event in watcher.watch(paths: paths) {
            if Task.isCancelled { break }
            let matches = matchingRules(for: event, in: rules)
            for (serviceName, rule) in matches {
                print("[watch] \(serviceName): change detected at '\(rule.path)' → action: \(rule.action.rawValue)")
                await handleAction(rule.action, serviceName: serviceName, rule: rule, dryRun: dryRun, cwd: cwd, remoteContext: remoteContext)
            }
        }
    }

    // MARK: - Private helpers

    private func handleAction(
        _ action: WatchAction,
        serviceName: String,
        rule: WatchRule,
        dryRun: Bool,
        cwd: String,
        remoteContext: RemoteContext?
    ) async {
        if let remoteContext {
            await handleRemoteAction(action, serviceName: serviceName, rule: rule, dryRun: dryRun, context: remoteContext)
            return
        }

        switch action {
        case .rebuild:
            if dryRun {
                print("[dry-run] would run: container-compose build \(serviceName)")
                print("[dry-run] would run: container-compose up -d \(serviceName)")
            } else {
                print("[watch] rebuilding \(serviceName)…")
                await runWatchShell(["container-compose", "build", serviceName], cwd: cwd)
                print("[watch] restarting \(serviceName)…")
                await runWatchShell(["container-compose", "up", "-d", serviceName], cwd: cwd)
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
                await runWatchShell(["container-compose", "restart", serviceName], cwd: cwd)
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
                    await runWatchShell(["container-compose", "exec", serviceName] + execCmd, cwd: cwd)
                }
            }

        case .restart:
            if dryRun {
                print("[dry-run] would run: container-compose restart \(serviceName)")
            } else {
                print("[watch] restarting \(serviceName)…")
                await runWatchShell(["container-compose", "restart", serviceName], cwd: cwd)
            }
        }
    }

    private func handleRemoteAction(
        _ action: WatchAction,
        serviceName: String,
        rule: WatchRule,
        dryRun: Bool,
        context: RemoteContext
    ) async {
        let explicitName = context.explicitContainerNames[serviceName]
        let containerName = effectiveContainerName(
            projectName: context.projectName,
            serviceName: serviceName,
            explicit: explicitName
        )

        switch action {
        case .rebuild:
            if dryRun {
                print("[dry-run] would remotely build and restart \(serviceName)")
                return
            }
            guard let remote = RuntimeEnvironment.current as? RemoteRuntime else {
                print("[watch] remote rebuild requires RemoteRuntime")
                return
            }
            do {
                let frames = try await remote.buildProject(name: context.projectName, services: [serviceName], noCache: false, pull: false)
                for await frame in frames {
                    print("[watch] \(frame.service): \(frame.line)")
                }
                try? await RuntimeEnvironment.current.stop(id: containerName, options: .default)
                try await RuntimeEnvironment.current.start(id: containerName)
            } catch {
                print("[watch] remote rebuild error: \(error)")
            }

        case .restart, .syncRestart:
            if dryRun {
                print("[dry-run] would remotely restart \(serviceName)")
                return
            }
            if action == .syncRestart {
                print("[watch] Note: remote sync+restart cannot sync files; only restart will be attempted.")
            }
            do {
                try? await RuntimeEnvironment.current.stop(id: containerName, options: .default)
                try await RuntimeEnvironment.current.start(id: containerName)
            } catch {
                print("[watch] remote restart error: \(error)")
            }

        case .sync:
            if dryRun {
                print("[dry-run] would sync '\(rule.path)' -> container:\(rule.target ?? "<no target>") for \(serviceName)")
            } else {
                print("[watch] Note: remote sync requires a file-copy API and is not supported yet.")
            }

        case .syncExec:
            if dryRun {
                let cmd = rule.exec?.command?.joined(separator: " ") ?? "<no command>"
                print("[dry-run] would remotely exec '\(cmd)' in \(serviceName)")
                return
            }
            guard let execCmd = rule.exec?.command, !execCmd.isEmpty else { return }
            do {
                let result = try await RuntimeEnvironment.current.exec(
                    id: containerName,
                    command: execCmd,
                    options: RuntimeExecOptions(
                        detach: false,
                        interactive: false,
                        tty: false,
                        user: rule.exec?.user,
                        workingDirectory: rule.exec?.workingDir
                    )
                )
                for line in result.stdout {
                    print("[watch] \(serviceName): \(line)")
                }
                for line in result.stderr {
                    fputs("[watch] \(serviceName): \(line)\n", stderr)
                }
            } catch {
                print("[watch] remote exec error: \(error)")
            }
        }
    }

    private func matchingRules(
        for event: FSEvent,
        in rules: [(serviceName: String, rule: WatchRule)]
    ) -> [(serviceName: String, rule: WatchRule)] {
        rules.filter { _, rule in
            path(event.path, isInsideOrEqualTo: rule.path)
        }
    }

    private func path(_ eventPath: String, isInsideOrEqualTo watchedPath: String) -> Bool {
        let normalizedEventPath = URL(fileURLWithPath: eventPath).standardized.path
        let normalizedWatchedPath = URL(fileURLWithPath: watchedPath).standardized.path
        return normalizedEventPath == normalizedWatchedPath ||
            normalizedEventPath.hasPrefix(normalizedWatchedPath + "/")
    }

    /// Fire-and-forget shell execution routed through the
    /// `RunCommandRunner` seam (PR-5 of the recorder migration; see
    /// `docs/plans/PLAN-recorder-seam.md` §2 / §7 / §9 PR-5). The watch loop
    /// shells out to `container-compose` itself (re-entrant), not Apple
    /// `container`; argv[0] distinguishes the recording lane. The previous
    /// private `shell` helper swallowed launch errors via a `print(...)`
    /// diagnostic; that semantics is preserved here by wrapping the throwing
    /// runner call in a `do`/`catch` that logs and continues.
    private func runWatchShell(_ args: [String], cwd: String) async {
        let request = RunRequest(kind: .awaitOnly, argv: args, cwd: cwd)
        do {
            _ = try await RunnerEnvironment.current.run(
                request,
                onStdout: nil,
                onStderr: nil
            )
        } catch {
            print("[watch] shell error: \(error)")
        }
    }
}

// MARK: - ComposeWatch

public struct ComposeWatch: AsyncParsableCommand, ComposeCommand, @unchecked Sendable {
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

    /// Explicit CLI fallback knob for CI/debugging and hosts where FSEvents is
    /// undesirable. Chosen over an env var so the behavior is visible in
    /// `container-compose watch --help` and straightforward to exercise in tests.
    @Flag(name: [.long], help: "Use legacy polling instead of the default FSEvents watcher")
    var polling: Bool = false

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    // MARK: - Helpers

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    // MARK: - Run

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()

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

        // Resolve paths relative to the project directory (--project-directory
        // override, falling back to the compose file's directory).
        let composeDir = effectiveProjectDirectory
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
        let remoteContext = RuntimeExecutionMode.isRemote
            ? WatchLoop.RemoteContext(
                projectName: resolveProjectName(for: dockerCompose),
                explicitContainerNames: Dictionary(
                    uniqueKeysWithValues: resolvedServices.compactMap { serviceName, service in
                        service.container_name.map { (serviceName, $0) }
                    }
                )
            )
            : nil
        if polling {
            await loop.runPolling(rules: resolvedRules, dryRun: dryRun, cwd: cwd, remoteContext: remoteContext)
        } else {
            await loop.runFSEvents(rules: resolvedRules, dryRun: dryRun, cwd: cwd, remoteContext: remoteContext)
        }
    }
}
