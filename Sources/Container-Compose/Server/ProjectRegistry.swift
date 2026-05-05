//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
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

import Foundation

// MARK: - ProjectRegistry

/// CHAOS-1426 — In-memory store of compose YAML documents ingested via
/// `POST /projects/{name}`.
///
/// Per Decision #12 (`docs/plans/native-api-server.md`), the daemon's project
/// view has historically been **synthesized** from container ids using the
/// project-prefix convention. This registry adds a **second** source of truth:
/// projects whose compose YAML was uploaded by a client. Routes that need
/// to know "what services should this project have?" prefer the registry
/// when present and fall back to the synthesized view otherwise.
///
/// Persistence is in-memory only for v1; a daemon restart drops ingested
/// projects. A future ticket can add disk-backed persistence (likely under
/// `~/.container-compose/projects/`) parallel to `ContainerRegistry`.
public actor ProjectRegistry {

    // MARK: - Errors

    public enum IngestError: Error, Sendable, Equatable {
        /// A project with this name already exists and the new content
        /// differs from the stored content.
        case conflict(name: String)
    }

    // MARK: - Stored entry

    /// Stored representation of an ingested compose project. We deliberately
    /// **do not store the parsed `DockerCompose` here** — it isn't `Sendable`
    /// (its nested Service/Volume/Network types are non-Sendable today) and
    /// crossing the actor boundary with it would require `@unchecked` escape
    /// hatches. The YAML string IS Sendable; routes that need a parsed view
    /// re-decode from `yaml` (cheap, deterministic, idempotent).
    public struct Entry: Sendable {
        public let name: String
        public let yaml: String
        public let services: [String]
        public let ingestedAt: Date
        public let yamlHash: Int

        public init(name: String, yaml: String, services: [String], ingestedAt: Date) {
            self.name = name
            self.yaml = yaml
            self.services = services
            self.ingestedAt = ingestedAt
            self.yamlHash = yaml.hashValue
        }
    }

    public enum IngestOutcome: Sendable, Equatable {
        /// New project — caller should respond 201 Created.
        case created
        /// Project existed with byte-identical YAML — caller should respond 200 OK.
        /// Idempotent re-upload, friendly for retried `compose up` flows.
        case unchanged
    }

    // MARK: - State

    private var entries: [String: Entry] = [:]

    public init() {}

    // MARK: - Operations

    /// Ingest (or re-confirm) a compose project under `name`.
    ///
    /// Caller must have already decoded and validated the YAML — this method
    /// only owns persistence + idempotency:
    ///
    /// - If the project is already stored AND the new YAML hashes identically,
    ///   returns `.unchanged` with the existing entry.
    /// - If content differs, throws `IngestError.conflict` so the route can
    ///   emit 409 — clients must explicitly delete + re-upload to replace.
    public func ingest(
        name: String,
        yaml: String,
        services: [String],
        now: Date = Date()
    ) throws -> (entry: Entry, outcome: IngestOutcome) {
        if let existing = entries[name] {
            if existing.yamlHash == yaml.hashValue && existing.yaml == yaml {
                return (existing, .unchanged)
            }
            throw IngestError.conflict(name: name)
        }

        let entry = Entry(name: name, yaml: yaml, services: services, ingestedAt: now)
        entries[name] = entry
        return (entry, .created)
    }

    public func get(name: String) -> Entry? {
        entries[name]
    }

    public func remove(name: String) -> Bool {
        entries.removeValue(forKey: name) != nil
    }

    public func names() -> [String] {
        entries.keys.sorted()
    }

    /// Test affordance — clear all entries between unit tests so the
    /// `@TaskLocal` shared instance does not leak state across cases.
    public func _testReset() {
        entries.removeAll()
    }
}

// MARK: - RuntimeEnvironment plumbing

extension RuntimeEnvironment {
    /// Daemon-process-wide project ingestion store. Routes that consume or
    /// produce ingested project state read from this task-local. Tests
    /// override it with a fresh `ProjectRegistry()` per case.
    @TaskLocal public static var projectRegistry: ProjectRegistry = ProjectRegistry()
}
