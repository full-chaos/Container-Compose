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
import ContainerResource
import Foundation
import Yams

// MARK: - ComposeEvents

public struct ComposeEvents: AsyncParsableCommand, ComposeCommand {
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

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    public mutating func run() async throws {
        let dockerCompose = try loadAndResolve()

        let projectName = resolveProjectName(for: dockerCompose)
        let targetNames = targetContainerNames(in: dockerCompose, projectName: projectName)
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()

        if RuntimeExecutionMode.isRemote {
            let stream = try await RuntimeEnvironment.current.events()
            for await event in stream {
                guard let fields = runtimeEventFields(event) else { continue }
                guard matchesProject(containerId: fields.id, projectName: projectName, targetNames: targetNames) else { continue }
                emitRuntimeEvent(id: fields.id, action: fields.action, timestamp: fields.timestamp, encoder: encoder, formatter: formatter)
            }
            return
        }

        let provider = ContainerClientEnvironment.current
        var lastTimestamp: Date? = nil

        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let allEvents = try await provider.events()
            let newEvents = allEvents.filter { event in
                if let last = lastTimestamp, event.timestamp <= last {
                    return false
                }
                return matchesProject(containerId: event.containerId, projectName: projectName, targetNames: targetNames)
            }

            for event in newEvents {
                emit(event, encoder: encoder, formatter: formatter)
                if lastTimestamp == nil || event.timestamp > lastTimestamp! {
                    lastTimestamp = event.timestamp
                }
            }
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
            effectiveContainerName(projectName: projectName, serviceName: serviceName, explicit: service.container_name)
        })
    }

    private func matchesProject(containerId: String, projectName: String, targetNames: Set<String>) -> Bool {
        if services.isEmpty {
            return targetNames.contains(containerId) || containerId.hasPrefix("\(projectName)-")
        }
        return targetNames.contains { targetName in
            containerId == targetName || containerId.hasPrefix("\(targetName)-")
        }
    }

    private func emit(_ event: ContainerEvent, encoder: JSONEncoder, formatter: ISO8601DateFormatter) {
        let timestamp = formatter.string(from: event.timestamp)
        if json {
            let jsonEvent = JSONEvent(
                timestamp: timestamp,
                type: "container",
                action: event.action.rawValue,
                id: event.containerId
            )
            guard let data = try? encoder.encode(jsonEvent), let line = String(data: data, encoding: .utf8) else { return }
            print(line)
        } else {
            print("\(timestamp) container \(event.action.rawValue) \(event.containerId)")
        }
    }

    private func emitRuntimeEvent(id: String, action: String, timestamp: Date, encoder: JSONEncoder, formatter: ISO8601DateFormatter) {
        let timestampString = formatter.string(from: timestamp)
        if json {
            let jsonEvent = JSONEvent(timestamp: timestampString, type: "container", action: action, id: id)
            guard let data = try? encoder.encode(jsonEvent), let line = String(data: data, encoding: .utf8) else { return }
            print(line)
        } else {
            print("\(timestampString) container \(action) \(id)")
        }
    }

    private func runtimeEventFields(_ event: RuntimeContainerEvent) -> (id: String, action: String, timestamp: Date)? {
        switch event {
        case .created(let id, let at):
            return (id, "created", at)
        case .started(let id, let at):
            return (id, "started", at)
        case .stopped(let id, _, let at):
            return (id, "stopped", at)
        case .killed(let id, _, let at):
            return (id, "killed", at)
        case .oomKilled(let id, let at):
            return (id, "oomKilled", at)
        case .removed(let id, let at):
            return (id, "removed", at)
        }
    }
}

private struct JSONEvent: Codable {
    var timestamp: String
    var type: String
    var action: String
    var id: String
}
