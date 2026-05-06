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

// MARK: - ProjectOrchestrator

/// Compose-aware orchestration layer between HTTP route handlers and the `Runtime`
/// protocol (CHAOS-1360, Phase 7).
///
/// **Design choice (Option B from the CHAOS-1360 ticket):**
/// Routes call `ProjectOrchestrator` methods, which internally use `Runtime`
/// protocol calls (`list`, `create`, `start`, `stop`, `remove`). The
/// `Runtime` protocol stays focused on single-container primitives; this
/// layer owns multi-container coordination (ordering, fanout, error handling).
///
/// **Compose-file source model (Decision #12):**
/// The orchestrator operates on containers *already known to the runtime* via
/// the project-name prefix convention (`<project>-<service>`). It does NOT
/// parse Compose YAML — that is out of scope per the CHAOS-1360 ticket
/// boundary. The `up` endpoint starts containers by creating them from the
/// image references already tracked; `down` stops/removes them; `scale`
/// adjusts replica counts. A pre-registered project registry (separate
/// ticket) can enrich this in a future phase.
///
/// **Sync vs async (Decision #11):**
/// All operations are synchronous from the HTTP caller's perspective:
/// - `up`: creates missing containers, starts stopped ones, returns 200 with
///   the resulting service states. Long-running real pull/build activity belongs
///   to the `build` and `pull` streaming endpoints.
/// - `down`/`restart`/`scale`: synchronous 200 responses.
/// - `build`/`pull`: NDJSON progress streams (the only truly long operations).
///
/// This avoids the complexity of async task tracking while preventing blocking
/// on real pull/build by deferring those to their dedicated streaming routes.
public struct ProjectOrchestrator: Sendable {

    // MARK: - Errors

    /// Errors that `ProjectOrchestrator` can surface to the route layer.
    /// Route handlers map these to appropriate HTTP status codes.
    public enum OrchestratorError: Error, Sendable, Equatable {
        /// No containers with the project prefix exist in the runtime.
        case projectNotFound(name: String)
        /// Requested service was not found within the project.
        case serviceNotFound(project: String, service: String)
        /// `replicas` field was < 0.
        case invalidReplicaCount(Int)
        /// Uploaded YAML failed to parse — surfaces decoder error message.
        case malformedComposeYAML(String)
        /// Uploaded YAML contained `include:` directives (which require a local
        /// filesystem and aren't meaningful for a remote upload).
        case includesNotPermitted
        /// Uploaded YAML had no services.
        case emptyComposeDocument
        /// Project name in URL collides with an already-ingested project whose
        /// content differs.
        case projectAlreadyIngested(name: String)
    }

    // MARK: - Ingest (CHAOS-1426)

    /// Ingest a compose YAML body and store it under the given project name.
    ///
    /// Architecture: this is the daemon-side counterpart to the CLI's
    /// `compose up` parsing pass. The daemon parses + validates the YAML,
    /// stores the resulting `DockerCompose` document in `ProjectRegistry`,
    /// and returns a summary. Subsequent `up`/`down`/`restart` calls can
    /// then operate against the ingested project state.
    ///
    /// Idempotency: if the project is already stored AND the new YAML
    /// hashes byte-identically, returns `.unchanged`. If the content
    /// differs, throws `projectAlreadyIngested` so the route can emit 409.
    /// Clients must explicitly delete + re-upload to replace.
    ///
    /// Validation:
    /// - `include:` directives → `includesNotPermitted` (no filesystem context)
    /// - zero services → `emptyComposeDocument`
    /// - YAML decode failure → `malformedComposeYAML(String)` carrying the
    ///   underlying message safe to surface in 400 responses (no Swift
    ///   internals leaked).
    public static func ingest(
        projectName: String,
        yaml: Data,
        registry: ProjectRegistry,
        now: Date = Date()
    ) async throws -> (response: APIProjectIngestResponse, outcome: ProjectRegistry.IngestOutcome) {
        guard let yamlString = String(data: yaml, encoding: .utf8) else {
            throw OrchestratorError.malformedComposeYAML("Body is not valid UTF-8")
        }
        let trimmed = yamlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OrchestratorError.malformedComposeYAML("Body is empty")
        }

        let document: DockerCompose
        do {
            document = try DockerCompose.from(yaml: yamlString)
        } catch let error as DecodingError {
            throw OrchestratorError.malformedComposeYAML(decodingErrorSummary(error))
        } catch {
            throw OrchestratorError.malformedComposeYAML(error.localizedDescription)
        }

        // Validation lives here (orchestrator) rather than inside the actor so
        // the actor only deals with already-Sendable inputs (yaml string +
        // service-name list). Keeps DockerCompose out of the actor boundary.
        if let includes = document.include, !includes.isEmpty {
            throw OrchestratorError.includesNotPermitted
        }
        let services = document.services.keys.sorted()
        guard !services.isEmpty else {
            throw OrchestratorError.emptyComposeDocument
        }

        do {
            let result = try await registry.ingest(
                name: projectName,
                yaml: yamlString,
                services: services,
                now: now
            )
            let outcomeString: String = (result.outcome == .created) ? "created" : "unchanged"
            let response = APIProjectIngestResponse(
                name: projectName,
                serviceCount: result.entry.services.count,
                services: result.entry.services,
                ingestedAt: result.entry.ingestedAt,
                outcome: outcomeString
            )
            return (response, result.outcome)
        } catch ProjectRegistry.IngestError.conflict(let name) {
            throw OrchestratorError.projectAlreadyIngested(name: name)
        }
    }

    /// Translate a `DecodingError` into a single-line summary safe to surface
    /// in HTTP 400 messages — keys + minimal context, no full call stacks.
    private static func decodingErrorSummary(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "Missing required key '\(key.stringValue)' at \(pathString(ctx.codingPath))"
        case .typeMismatch(_, let ctx):
            return "Type mismatch at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
        case .valueNotFound(_, let ctx):
            return "Missing value at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
        case .dataCorrupted(let ctx):
            return "Data corrupted at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return "Compose YAML decoding failed"
        }
    }

    private static func pathString(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return "<root>" }
        return path.map { $0.stringValue }.joined(separator: ".")
    }

    // MARK: - Up

    /// Bring the project up.
    ///
    /// Discovers all containers in the runtime whose id starts with
    /// `<project>-`. For each running or stopped container, transitions it to
    /// `.running`. Creates a placeholder container for any service provided in
    /// `serviceSpecs` that has no container yet.
    ///
    /// Because the API operates on an already-running daemon's registry (not a
    /// Compose YAML), `serviceSpecs` is optional. When absent, the orchestrator
    /// only acts on containers already in the registry.
    ///
    /// - Parameters:
    ///   - project: Project name (the naming-convention prefix).
    ///   - serviceSpecs: Optional map of `serviceName → imageReference` for
    ///     containers that should be created if not already present.
    ///   - runtime: The `Runtime` to use.
    /// - Returns: Service state for every affected container.
    public static func up(
        project: String,
        serviceSpecs: [String: String] = [:],
        runtime: any Runtime
    ) async throws -> [APIProjectServiceState] {
        var states: [APIProjectServiceState] = []

        // Create missing containers from serviceSpecs
        for (serviceName, imageRef) in serviceSpecs.sorted(by: { $0.key < $1.key }) {
            let containerId = "\(project)-\(serviceName)"
            let existing = try? await runtime.get(id: containerId)
            if existing == nil {
                let config = RuntimeCreateConfiguration(imageReference: imageRef)
                _ = try await runtime.create(id: containerId, configuration: config)
            }
        }

        // List all project containers
        let allContainers = try await runtime.list(
            filters: RuntimeListFilters(status: nil, namePrefix: "\(project)-")
        )

        guard !allContainers.isEmpty && !serviceSpecs.isEmpty || !allContainers.isEmpty else {
            if serviceSpecs.isEmpty {
                throw OrchestratorError.projectNotFound(name: project)
            }
            throw OrchestratorError.projectNotFound(name: project)
        }

        // Start each container that's not yet running
        for container in allContainers.sorted(by: { $0.id < $1.id }) {
            switch container.status {
            case .created:
                try await runtime.start(id: container.id)
                states.append(APIProjectServiceState(
                    service: extractServiceName(from: container.id, project: project),
                    containerId: container.id,
                    status: RuntimeContainerStatus.running.rawValue
                ))
            case .running:
                states.append(APIProjectServiceState(
                    service: extractServiceName(from: container.id, project: project),
                    containerId: container.id,
                    status: RuntimeContainerStatus.running.rawValue
                ))
            case .stopped, .exited:
                // Stopped containers need to be reset to created before starting.
                // Since the Runtime protocol doesn't have a reset method in the
                // base protocol, we remove and recreate if possible. For now,
                // we report as stopped and let the client handle.
                states.append(APIProjectServiceState(
                    service: extractServiceName(from: container.id, project: project),
                    containerId: container.id,
                    status: container.status.rawValue
                ))
            default:
                states.append(APIProjectServiceState(
                    service: extractServiceName(from: container.id, project: project),
                    containerId: container.id,
                    status: container.status.rawValue
                ))
            }
        }

        if states.isEmpty {
            throw OrchestratorError.projectNotFound(name: project)
        }

        return states
    }

    // MARK: - Down

    /// Tear the project down.
    ///
    /// Stops all running containers in the project, then removes them.
    ///
    /// - Parameters:
    ///   - project: Project name prefix.
    ///   - timeout: Grace period in seconds before SIGKILL. Defaults to 10.
    ///   - runtime: The `Runtime` to use.
    /// - Returns: IDs of containers that were stopped and removed.
    public static func down(
        project: String,
        timeout: Int = 10,
        runtime: any Runtime
    ) async throws -> (stopped: [String], removed: [String]) {
        let allContainers = try await runtime.list(
            filters: RuntimeListFilters(status: nil, namePrefix: "\(project)-")
        )

        guard !allContainers.isEmpty else {
            throw OrchestratorError.projectNotFound(name: project)
        }

        var stopped: [String] = []
        var removed: [String] = []

        let stopOptions = RuntimeStopOptions(signal: 15, timeoutSeconds: timeout)

        // Stop in reverse order (approximate: by id descending)
        for container in allContainers.sorted(by: { $0.id > $1.id }) {
            if container.status == .running {
                try? await runtime.stop(id: container.id, options: stopOptions)
                stopped.append(container.id)
            }
        }

        // Remove all
        for container in allContainers {
            try? await runtime.remove(id: container.id, force: true)
            removed.append(container.id)
        }

        return (stopped: stopped.sorted(), removed: removed.sorted())
    }

    // MARK: - Restart

    /// Restart project services.
    ///
    /// For each container matching the filter, transitions back to `.running`
    /// using only `Runtime` protocol primitives. Because the protocol's
    /// `start(id:)` is contractually limited to `.created` containers (see
    /// `Runtime.swift`), a "restart" of an already-started container is
    /// expressed as `stop → remove → create → start`, reusing the snapshot's
    /// `imageReference` and `publishedPorts`. A `.created` container that
    /// has never started is simply started in place.
    ///
    /// Tolerated races: `stop` and `remove` use `try?` so a container that
    /// exited between snapshot and call (or was already removed) does not
    /// abort the whole restart. Failures from `create` or `start` propagate
    /// — only containers that completed the full cycle are reported as
    /// restarted.
    ///
    /// Note: any container metadata not exposed on `RuntimeContainer` (env,
    /// command, resources) is not preserved across the recreate. Only fields
    /// observable on the snapshot survive.
    ///
    /// - Parameters:
    ///   - project: Project name prefix.
    ///   - services: Optional service name filter. Nil means all.
    ///   - timeout: Grace period in seconds before SIGKILL during stop.
    ///   - runtime: The `Runtime` to use.
    /// - Returns: Container IDs that were successfully restarted.
    public static func restart(
        project: String,
        services: [String]?,
        timeout: Int = 10,
        runtime: any Runtime
    ) async throws -> [String] {
        let allContainers = try await runtime.list(
            filters: RuntimeListFilters(status: nil, namePrefix: "\(project)-")
        )

        guard !allContainers.isEmpty else {
            throw OrchestratorError.projectNotFound(name: project)
        }

        let stopOptions = RuntimeStopOptions(signal: 15, timeoutSeconds: timeout)
        var restarted: [String] = []

        // Filter to requested services (or all if nil/empty)
        let filtered: [RuntimeContainer]
        if let services, !services.isEmpty {
            filtered = allContainers.filter { container in
                let svcName = extractServiceName(from: container.id, project: project)
                return services.contains(svcName)
            }
        } else {
            filtered = allContainers
        }

        for container in filtered.sorted(by: { $0.id < $1.id }) {
            if container.status == .created {
                // Never-started container: a single start() satisfies the protocol.
                try await runtime.start(id: container.id)
                restarted.append(container.id)
                continue
            }

            // Running / stopping / stopped / exited / unknown all need the full
            // recreate cycle since `start()` only accepts `.created`.
            if container.status == .running || container.status == .stopping {
                try? await runtime.stop(id: container.id, options: stopOptions)
            }
            try? await runtime.remove(id: container.id, force: true)

            let config = RuntimeCreateConfiguration(
                imageReference: container.imageReference,
                publishedPorts: container.publishedPorts
            )
            _ = try await runtime.create(id: container.id, configuration: config)
            try await runtime.start(id: container.id)
            restarted.append(container.id)
        }

        return restarted.sorted()
    }

    // MARK: - Scale

    /// Scale a single service within the project to the requested replica count.
    ///
    /// Current implementation adjusts the number of running containers matching
    /// `<project>-<service>` or `<project>-<service>-N` (replica-suffixed) by
    /// creating or removing containers.
    ///
    /// - Parameters:
    ///   - project: Project name prefix.
    ///   - service: Service name (without project prefix).
    ///   - replicas: Target replica count (≥ 0).
    ///   - imageReference: Image reference to use when creating new replicas.
    ///   - runtime: The `Runtime` to use.
    /// - Returns: Container IDs running for this service after scaling.
    public static func scale(
        project: String,
        service: String,
        replicas: Int,
        imageReference: String = "unknown",
        runtime: any Runtime
    ) async throws -> [String] {
        guard replicas >= 0 else {
            throw OrchestratorError.invalidReplicaCount(replicas)
        }

        // Discover existing replicas for this service
        let prefix = "\(project)-\(service)"
        let allContainers = try await runtime.list(
            filters: RuntimeListFilters(status: nil, namePrefix: "\(project)-")
        )

        // Match containers belonging to this service (exact or replica-suffixed)
        let existing = allContainers.filter { container in
            container.id == prefix ||
            container.id.hasPrefix("\(prefix)-")
        }.sorted(by: { $0.id < $1.id })

        let currentCount = existing.count
        var currentIds = existing.map(\.id)

        if currentCount < replicas {
            // Scale up: create and start missing replicas
            for i in (currentCount + 1)...replicas {
                let newId = currentCount == 0 && i == 1
                    ? prefix
                    : "\(prefix)-\(i)"
                let config = RuntimeCreateConfiguration(imageReference: imageReference)
                _ = try await runtime.create(id: newId, configuration: config)
                try await runtime.start(id: newId)
                currentIds.append(newId)
            }
        } else if currentCount > replicas {
            // Scale down: stop and remove excess replicas (remove from end)
            let excess = existing.suffix(currentCount - replicas)
            for container in excess {
                try? await runtime.stop(id: container.id, options: .default)
                try? await runtime.remove(id: container.id, force: true)
                currentIds.removeAll { $0 == container.id }
            }
        }

        return currentIds.sorted()
    }

    // MARK: - Build (NDJSON progress stream)

    /// Produce an NDJSON progress stream for a conceptual build operation.
    ///
    /// Because the API operates on the daemon's container registry (no Compose
    /// YAML), the actual OCI image build (`container image build`) is not
    /// available in this orchestration layer — it requires the CLI runner seam
    /// (`RunCommandRunner`). This method emits synthetic `"notSupported"` frames
    /// per service and a `"done"` terminal frame. A future ticket can wire the
    /// real `container image build` execution through `Runtime.build(...)` when
    /// that method is added to the protocol.
    ///
    /// Decision #13: build/pull streaming uses the same NDJSON ByteBuffer pattern
    /// as `LogsRoutes` and `StatsRoutes`.
    public static func buildStream(
        project: String,
        services: [String]?,
        noCache: Bool,
        pull: Bool,
        runtime: any Runtime
    ) -> AsyncStream<APIProjectBuildFrame> {
        AsyncStream { continuation in
            let task = Task {
                let allContainers = try? await runtime.list(
                    filters: RuntimeListFilters(status: nil, namePrefix: "\(project)-")
                )

                let serviceNames: [String]
                if let services, !services.isEmpty {
                    serviceNames = services
                } else if let containers = allContainers {
                    let names = Set(containers.map { extractServiceName(from: $0.id, project: project) })
                    serviceNames = names.sorted()
                } else {
                    serviceNames = []
                }

                if serviceNames.isEmpty {
                    continuation.yield(APIProjectBuildFrame(
                        service: project,
                        line: "No services to build",
                        timestamp: Date(),
                        type: "error"
                    ))
                    continuation.finish()
                    return
                }

                // CHAOS-1425: delegate to Runtime.build(...). Today every
                // conformer responds `notSupported` because the daemon does
                // not yet receive compose-file context (Dockerfile path,
                // build context dir) — that's CHAOS-1426. Translate each
                // event back to APIProjectBuildFrame so the wire format
                // stays unchanged for clients.
                let specs = serviceNames.map {
                    RuntimeBuildSpec(
                        service: $0,
                        noCache: noCache,
                        pullBaseImages: pull
                    )
                }
                do {
                    let stream = try await runtime.build(specs: specs)
                    for await event in stream {
                        if Task.isCancelled { break }
                        continuation.yield(translate(event: event))
                    }
                } catch let error as RuntimeError {
                    continuation.yield(APIProjectBuildFrame(
                        service: project,
                        line: error.localizedDescription,
                        timestamp: Date(),
                        type: "error"
                    ))
                } catch {
                    continuation.yield(APIProjectBuildFrame(
                        service: project,
                        line: error.localizedDescription,
                        timestamp: Date(),
                        type: "error"
                    ))
                }
                continuation.yield(APIProjectBuildFrame(
                    service: project,
                    line: "Build dispatch complete",
                    timestamp: Date(),
                    type: "done"
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func translate(event: RuntimeBuildEvent) -> APIProjectBuildFrame {
        let type: String
        let line: String
        switch event.kind {
        case .started:
            type = "log"
            line = event.message ?? "Build started"
        case .completed:
            type = "log"
            line = event.message ?? "Build completed"
        case .failed:
            type = "error"
            line = event.message ?? "Build failed"
        case .notSupported:
            type = "notSupported"
            line = event.message ?? "Build not supported"
        }
        return APIProjectBuildFrame(
            service: event.service,
            line: line,
            timestamp: event.timestamp,
            type: type
        )
    }

    // MARK: - Pull (NDJSON progress stream)

    /// Produce an NDJSON progress stream for a conceptual pull operation.
    ///
    /// Similar to `buildStream`, the daemon API layer does not have direct access
    /// to the `container image pull` runner. This emits frames describing the
    /// images referenced by the project's containers so clients see which images
    /// *would* be pulled. A future ticket can wire real pull through a
    /// `Runtime.pull(...)` extension.
    public static func pullStream(
        project: String,
        services: [String]?,
        ignoreFailures: Bool,
        runtime: any Runtime
    ) -> AsyncStream<APIProjectPullFrame> {
        AsyncStream { continuation in
            let task = Task {
                let allContainers = try? await runtime.list(
                    filters: RuntimeListFilters(status: nil, namePrefix: "\(project)-")
                )

                let containers: [RuntimeContainer]
                if let services, !services.isEmpty {
                    containers = (allContainers ?? []).filter { container in
                        let svcName = extractServiceName(from: container.id, project: project)
                        return services.contains(svcName)
                    }
                } else {
                    containers = allContainers ?? []
                }

                guard !containers.isEmpty else {
                    continuation.yield(APIProjectPullFrame(
                        service: project,
                        image: "none",
                        timestamp: Date(),
                        type: "error",
                        message: "No containers found for project '\(project)'"
                    ))
                    continuation.finish()
                    return
                }

                // CHAOS-1425: delegate to Runtime.pull(...). One spec per
                // resolved container; the conformer iterates and emits
                // started/completed/failed events. Coarse-grained progress
                // (no per-blob frames) — see RuntimePullEvent doc comment.
                let specs = containers
                    .sorted(by: { $0.id < $1.id })
                    .map { container in
                        RuntimePullSpec(
                            service: extractServiceName(from: container.id, project: project),
                            imageReference: container.imageReference
                        )
                    }
                do {
                    let stream = try await runtime.pull(specs: specs, ignoreFailures: ignoreFailures)
                    for await event in stream {
                        if Task.isCancelled { break }
                        continuation.yield(translate(event: event))
                    }
                } catch let error as RuntimeError {
                    continuation.yield(APIProjectPullFrame(
                        service: project,
                        image: "none",
                        timestamp: Date(),
                        type: "error",
                        message: error.localizedDescription
                    ))
                } catch {
                    continuation.yield(APIProjectPullFrame(
                        service: project,
                        image: "none",
                        timestamp: Date(),
                        type: "error",
                        message: error.localizedDescription
                    ))
                }
                continuation.yield(APIProjectPullFrame(
                    service: project,
                    image: "done",
                    timestamp: Date(),
                    type: "done",
                    message: nil
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func translate(event: RuntimePullEvent) -> APIProjectPullFrame {
        let type: String
        switch event.kind {
        case .started:
            type = "pulling"
        case .completed:
            type = "log"
        case .failed:
            type = "error"
        }
        return APIProjectPullFrame(
            service: event.service,
            image: event.imageReference,
            timestamp: event.timestamp,
            type: type,
            message: event.message
        )
    }

    // MARK: - Private helpers

    /// Extract the service name from a container id using the project prefix
    /// convention. Mirrors `ProjectRoutes.extractServiceName`.
    static func extractServiceName(from containerId: String, project: String) -> String {
        let prefix = "\(project)-"
        guard containerId.hasPrefix(prefix) else { return containerId }
        let service = String(containerId.dropFirst(prefix.count))
        // Collapse numeric replica suffix: "web-1" → "web"
        let parts = service.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count > 1, let last = parts.last, Int(last) != nil else {
            return service
        }
        return parts.dropLast().joined(separator: "-")
    }
}
