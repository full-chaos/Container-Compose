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

// MARK: - GET /projects  (Compose-aware extension)

public struct APIProjectSummary: Codable, Sendable, Hashable {
    public let name: String
    public let serviceCount: Int
    public let runningCount: Int
    public let createdAt: Date?

    public init(name: String, serviceCount: Int, runningCount: Int, createdAt: Date?) {
        self.name = name
        self.serviceCount = serviceCount
        self.runningCount = runningCount
        self.createdAt = createdAt
    }
}

// MARK: - GET /projects/{name}/services  (Compose-aware extension)

public struct APIServiceSummary: Codable, Sendable, Hashable {
    public let project: String
    public let name: String
    public let container: APIContainerSummary

    public init(project: String, name: String, container: APIContainerSummary) {
        self.project = project
        self.name = name
        self.container = container
    }
}

// MARK: - POST /projects/{name}  (Compose YAML ingestion — CHAOS-1426)

/// Response body for `POST /projects/{name}` (compose YAML ingest).
///
/// Wire shape mirrors the rest of the project family — `name`, a count of
/// declared services, the ingestion timestamp, and an `outcome` field that
/// distinguishes a fresh ingestion (201 Created) from an idempotent re-upload
/// of byte-identical YAML (200 OK).
public struct APIProjectIngestResponse: Codable, Sendable, Hashable {
    public let name: String
    public let serviceCount: Int
    public let services: [String]
    public let ingestedAt: Date
    /// `"created"` for new ingestion (201 status); `"unchanged"` for idempotent
    /// re-upload of identical content (200 status).
    public let outcome: String

    public init(name: String, serviceCount: Int, services: [String], ingestedAt: Date, outcome: String) {
        self.name = name
        self.serviceCount = serviceCount
        self.services = services
        self.ingestedAt = ingestedAt
        self.outcome = outcome
    }
}

/// Detailed response body for `GET /projects/{name}` when the project has
/// been ingested via `POST /projects/{name}`. Includes the parsed service list
/// so clients can reflect the daemon-side compose state without re-parsing
/// their local YAML.
public struct APIProjectDetail: Codable, Sendable, Hashable {
    public let name: String
    public let source: String
    public let serviceCount: Int
    public let services: [String]
    public let ingestedAt: Date?

    public init(name: String, source: String, serviceCount: Int, services: [String], ingestedAt: Date?) {
        self.name = name
        self.source = source
        self.serviceCount = serviceCount
        self.services = services
        self.ingestedAt = ingestedAt
    }
}

// MARK: - Project Lifecycle Schemas (CHAOS-1360)

// MARK: POST /projects/{name}/up

/// Request body for `POST /projects/{name}/up`.
/// All fields are optional; `detached` defaults to `true` (run services in the
/// background — the standard compose up mode). `profiles` filters which services
/// participate. `build` rebuilds images before starting. `pull` controls the
/// pull policy.
public struct APIProjectUpRequest: Codable, Sendable, Hashable {
    /// When `true` (default) services start detached; the route returns once all
    /// containers reach the `.running` state. When `false` the caller is expected
    /// to stream logs separately; the route still returns 200 once containers are
    /// running (no indefinite block — a separate logs follow-up is needed).
    public let detached: Bool?
    /// Compose profiles to activate. Nil means activate no profiles (only
    /// services without `profiles:` declarations start).
    public let profiles: [String]?
    /// When `true`, rebuild images before starting (equivalent to `--build`).
    public let build: Bool?
    /// Pull policy: `"always"`, `"missing"`, `"never"`. Nil uses the service's
    /// declared `pull_policy` (or `"missing"` as the built-in default).
    public let pull: String?

    public init(
        detached: Bool? = nil,
        profiles: [String]? = nil,
        build: Bool? = nil,
        pull: String? = nil
    ) {
        self.detached = detached
        self.profiles = profiles
        self.build = build
        self.pull = pull
    }
}

/// Per-service state entry in `APIProjectUpResponse`.
public struct APIProjectServiceState: Codable, Sendable, Hashable {
    public let service: String
    public let containerId: String
    public let status: String

    public init(service: String, containerId: String, status: String) {
        self.service = service
        self.containerId = containerId
        self.status = status
    }
}

/// Response body for `POST /projects/{name}/up` (200 OK).
public struct APIProjectUpResponse: Codable, Sendable, Hashable {
    public let project: String
    public let services: [APIProjectServiceState]

    public init(project: String, services: [APIProjectServiceState]) {
        self.project = project
        self.services = services
    }
}

// MARK: POST /projects/{name}/down

/// Request body for `POST /projects/{name}/down`.
public struct APIProjectDownRequest: Codable, Sendable, Hashable {
    /// When `true`, also remove named volumes declared in the compose file.
    /// Defaults to `false`.
    public let removeVolumes: Bool?
    /// When `true` (default), stop and remove containers not declared in the
    /// compose file but sharing the project name prefix.
    public let removeOrphans: Bool?
    /// Seconds to wait for each container to stop gracefully before SIGKILL.
    public let timeout: Int?

    public init(removeVolumes: Bool? = nil, removeOrphans: Bool? = nil, timeout: Int? = nil) {
        self.removeVolumes = removeVolumes
        self.removeOrphans = removeOrphans
        self.timeout = timeout
    }
}

/// Response body for `POST /projects/{name}/down` (200 OK).
public struct APIProjectDownResponse: Codable, Sendable, Hashable {
    public let project: String
    public let stopped: [String]
    public let removed: [String]

    public init(project: String, stopped: [String], removed: [String]) {
        self.project = project
        self.stopped = stopped
        self.removed = removed
    }
}

// MARK: POST /projects/{name}/restart

/// Request body for `POST /projects/{name}/restart`.
public struct APIProjectRestartRequest: Codable, Sendable, Hashable {
    /// Restrict restart to named services. Nil or empty means restart all
    /// services in the project.
    public let services: [String]?
    /// Seconds to wait for each container to stop gracefully before SIGKILL.
    public let timeout: Int?

    public init(services: [String]? = nil, timeout: Int? = nil) {
        self.services = services
        self.timeout = timeout
    }
}

/// Response body for `POST /projects/{name}/restart` (200 OK).
public struct APIProjectRestartResponse: Codable, Sendable, Hashable {
    public let project: String
    public let restarted: [String]

    public init(project: String, restarted: [String]) {
        self.project = project
        self.restarted = restarted
    }
}

// MARK: POST /projects/{name}/build  (NDJSON streaming)

/// Request body for `POST /projects/{name}/build`.
/// Response is NDJSON `APIProjectBuildFrame` lines, `Content-Type: application/x-ndjson`.
public struct APIProjectBuildRequest: Codable, Sendable, Hashable {
    /// Restrict build to named services. Nil or empty means build all services
    /// with a `build:` block.
    public let services: [String]?
    /// Skip the layer cache.
    public let noCache: Bool?
    /// Pull fresh base images before building.
    public let pull: Bool?

    public init(services: [String]? = nil, noCache: Bool? = nil, pull: Bool? = nil) {
        self.services = services
        self.noCache = noCache
        self.pull = pull
    }
}

/// One NDJSON line emitted by `POST /projects/{name}/build`.
public struct APIProjectBuildFrame: Codable, Sendable, Hashable {
    /// The service being built.
    public let service: String
    /// Log line from the build output (stdout/stderr merged).
    public let line: String
    /// ISO-8601 timestamp.
    public let timestamp: Date
    /// `"log"` during the build, `"done"` on success, `"error"` on failure.
    public let type: String

    public init(service: String, line: String, timestamp: Date, type: String) {
        self.service = service
        self.line = line
        self.timestamp = timestamp
        self.type = type
    }
}

// MARK: POST /projects/{name}/pull  (NDJSON streaming)

/// Request body for `POST /projects/{name}/pull`.
/// Response is NDJSON `APIProjectPullFrame` lines.
public struct APIProjectPullRequest: Codable, Sendable, Hashable {
    /// Restrict pull to named services. Nil or empty means pull all services.
    public let services: [String]?
    /// When `true`, continue pulling other services even if one fails.
    public let ignoreFailures: Bool?

    public init(services: [String]? = nil, ignoreFailures: Bool? = nil) {
        self.services = services
        self.ignoreFailures = ignoreFailures
    }
}

/// One NDJSON line emitted by `POST /projects/{name}/pull`.
public struct APIProjectPullFrame: Codable, Sendable, Hashable {
    /// The service whose image is being pulled.
    public let service: String
    /// Image reference being pulled.
    public let image: String
    /// Timestamp of this frame.
    public let timestamp: Date
    /// `"pulling"` while in progress, `"done"` on success, `"error"` on failure.
    public let type: String
    /// Optional progress or error message.
    public let message: String?

    public init(service: String, image: String, timestamp: Date, type: String, message: String? = nil) {
        self.service = service
        self.image = image
        self.timestamp = timestamp
        self.type = type
        self.message = message
    }
}

// MARK: POST /projects/{name}/services/{service}/scale

/// Request body for `POST /projects/{name}/services/{service}/scale`.
public struct APIProjectScaleRequest: Codable, Sendable, Hashable {
    /// Desired number of replicas for the service.
    public let replicas: Int

    public init(replicas: Int) {
        self.replicas = replicas
    }
}

/// Response body for `POST /projects/{name}/services/{service}/scale` (200 OK).
public struct APIProjectScaleResponse: Codable, Sendable, Hashable {
    public let project: String
    public let service: String
    public let replicas: Int
    /// Container IDs now running for this service.
    public let containers: [String]

    public init(project: String, service: String, replicas: Int, containers: [String]) {
        self.project = project
        self.service = service
        self.replicas = replicas
        self.containers = containers
    }
}
