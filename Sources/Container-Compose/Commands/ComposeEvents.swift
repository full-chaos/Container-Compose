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
//  ComposeEvents.swift
//  Container-Compose
//

import ArgumentParser
import ContainerCommands
import ContainerAPIClient
import Foundation
import Yams

// MARK: - EventStreamPoller

internal struct EventStreamPoller: Sendable {
    internal struct Snapshot: Sendable, Equatable {
        var id: String
        var image: String
        var name: String
        var status: String
    }

    internal struct Event: Codable, Sendable, Equatable {
        var timestamp: String
        var type: String
        var action: String
        var id: String
        var image: String
        var name: String
    }

    func diff(prev previous: [Snapshot], current: [Snapshot], at date: Date = Date()) -> [Event] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let timestamp = Self.timestamp(from: date)
        var events: [Event] = []

        for snapshot in current.sorted(by: { $0.id < $1.id }) where previousByID[snapshot.id] == nil {
            events.append(event("create", snapshot: snapshot, timestamp: timestamp))
            if Self.isRunning(snapshot.status) {
                events.append(event("start", snapshot: snapshot, timestamp: timestamp))
            }
        }

        for snapshot in previous.sorted(by: { $0.id < $1.id }) where currentByID[snapshot.id] == nil {
            if Self.isRunning(snapshot.status) {
                events.append(event("die", snapshot: snapshot, timestamp: timestamp))
            }
            events.append(event("destroy", snapshot: snapshot, timestamp: timestamp))
        }

        for snapshot in current.sorted(by: { $0.id < $1.id }) {
            guard let old = previousByID[snapshot.id], old.status != snapshot.status else { continue }
            events.append(contentsOf: transitionEvents(from: old, to: snapshot, timestamp: timestamp))
        }

        return events
    }

    private func transitionEvents(from old: Snapshot, to new: Snapshot, timestamp: String) -> [Event] {
        if !Self.isRunning(old.status), Self.isRunning(new.status) {
            return [event("start", snapshot: new, timestamp: timestamp)]
        }
        if Self.isRunning(old.status), Self.isStopped(new.status) {
            return [
                event("stop", snapshot: new, timestamp: timestamp),
                event("die", snapshot: new, timestamp: timestamp),
            ]
        }
        if Self.isStopping(old.status), Self.isStopped(new.status) {
            return [event("die", snapshot: new, timestamp: timestamp)]
        }
        if Self.isRunning(old.status), Self.isStopping(new.status) {
            return [event("stop", snapshot: new, timestamp: timestamp)]
        }
        return []
    }

    private func event(_ action: String, snapshot: Snapshot, timestamp: String) -> Event {
        Event(
            timestamp: timestamp,
            type: "container",
            action: action,
            id: snapshot.id,
            image: snapshot.image,
            name: snapshot.name
        )
    }

    private static func isRunning(_ status: String) -> Bool { status == "running" }

    private static func isStopped(_ status: String) -> Bool { status == "stopped" }

    private static func isStopping(_ status: String) -> Bool { status == "stopping" }

    private static func timestamp(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - ComposeEvents

public struct ComposeEvents: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "events",
        abstract: "Stream container lifecycle events for this Compose project"
    )

    @Argument(help: "Filter events to specific services")
    var services: [String] = []

    @Flag(name: [.long], help: "Emit events as newline-delimited JSON")
    var json: Bool = false

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    /// Project root for outside-container relative-path resolution. Honors
    /// `--project-directory`, falls back to the compose file's directory.
    private var effectiveProjectDirectory: String {
        resolveProjectDirectory(
            cliOverride: projectFlags.projectDirectory,
            composeFilePath: composePath,
            cwd: cwd
        )
    }

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

    // MARK: - Path B (polling fallback)

    /// The upstream `ContainerClientProvider` exposes list/get/stop/delete/logs,
    /// but no native event or subscription method, so this command synthesizes
    /// lifecycle events by diffing `ContainerClient.list()` snapshots every 1s.
    public mutating func run() async throws {
        printFallbackWarning()

        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        let projectName = resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )
        let targetNames = targetContainerNames(in: dockerCompose, projectName: projectName)
        let provider = ContainerClientEnvironment.current
        let poller = EventStreamPoller()
        var previous = try await currentSnapshots(provider: provider, projectName: projectName, targetNames: targetNames)
        let encoder = JSONEncoder()

        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let current = try await currentSnapshots(provider: provider, projectName: projectName, targetNames: targetNames)
            for event in poller.diff(prev: previous, current: current) {
                emit(event, encoder: encoder)
            }
            previous = current
        }
    }

    private func targetContainerNames(in dockerCompose: DockerCompose, projectName: String) -> Set<String> {
        var serviceList: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }

        if !services.isEmpty {
            serviceList = serviceList.filter { services.contains($0.serviceName) }
        }

        return Set(serviceList.map { serviceName, service in
            service.container_name ?? "\(projectName)-\(serviceName)"
        })
    }

    private func currentSnapshots(
        provider: any ContainerClientProvider,
        projectName: String,
        targetNames: Set<String>
    ) async throws -> [EventStreamPoller.Snapshot] {
        let allContainers = try await provider.list(filters: .all)
        return allContainers.compactMap { container in
            guard matches(containerID: container.configuration.id, projectName: projectName, targetNames: targetNames) else {
                return nil
            }
            return EventStreamPoller.Snapshot(
                id: container.configuration.id,
                image: container.configuration.image.reference,
                name: container.configuration.id,
                status: container.status.rawValue
            )
        }
    }

    private func matches(containerID: String, projectName: String, targetNames: Set<String>) -> Bool {
        if services.isEmpty {
            return targetNames.contains(containerID) || containerID.hasPrefix("\(projectName)-")
        }
        return targetNames.contains { targetName in
            containerID == targetName || containerID.hasPrefix("\(targetName)-")
        }
    }

    private func emit(_ event: EventStreamPoller.Event, encoder: JSONEncoder) {
        if json {
            guard let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8) else { return }
            print(line)
        } else {
            print("\(event.timestamp) container \(event.action) \(event.id) (image=\(event.image), name=\(event.name))")
        }
    }

    private func printFallbackWarning() {
        print(
            "compose events: native event stream unavailable upstream — falling back to 1s polling. " +
            "Detected, But Partially Supported"
        )
    }
}
