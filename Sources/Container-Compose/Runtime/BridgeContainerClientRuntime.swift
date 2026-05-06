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

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Foundation

// MARK: - BridgeContainerClientRuntime

/// `Runtime` conformer that delegates the read paths (`list`, `get`) to the
/// existing `ContainerClientProvider` (which talks to apple/container's
/// XPC daemon under the hood). Lifecycle / write paths
/// (`create` / `start` / `stop` / `kill` / `wait` / `remove`) intentionally
/// throw `RuntimeError.notSupported`: those continue to flow through
/// `RunCommandRunner` until Phase 2/3 migrates each command to the native
/// `AppleContainerizationRuntime`.
///
/// Why this conformer is the Phase 1 default
/// (`RuntimeEnvironment.current` initial value):
/// - Strategically, container-compose is moving AWAY from apple/container's
///   CLI/XPC daemon. Operationally, we cannot move the read paths there
///   yet because the native conformer needs macOS 26 + the virtualization
///   entitlement + a kernel binary — none of which is on a typical
///   contributor laptop or CI runner.
/// - The bridge gives us the `Runtime` seam at the call site of
///   `compose ps` with zero behavior change. When the deployment story is
///   solved, the default flips (or an explicit selector swaps in
///   `AppleContainerizationRuntime`).
///
/// Read translation: `ContainerSnapshot` → `RuntimeContainer`. We translate
/// once at the boundary so call sites observe only `RuntimeContainer`. The
/// translation is intentionally lossy on fields the Phase 1 surface does not
/// expose (e.g. `networks`, `health`, `platform`); add them to
/// `RuntimeContainer` as more commands migrate.
public struct BridgeContainerClientRuntime: Runtime {

    public init() {}

    // MARK: - Discovery

    public func version() async throws -> RuntimeVersion {
        RuntimeVersion(
            apiVersion: "v1",
            daemonVersion: Main.version,
            serverName: "container-compose",
            backendDescription: "bridge (apple/container CLI)",
            arch: BridgeContainerClientRuntime.runtimeArch
        )
    }

    public func list(filters: RuntimeListFilters) async throws -> [RuntimeContainer] {
        let provider = ContainerClientEnvironment.current
        let snapshots = try await provider.list(filters: .all)
        return snapshots
            .map(BridgeContainerClientRuntime.translate(snapshot:))
            .filter { filters.matches($0) }
    }

    public func listNetworks() async throws -> [RuntimeNetwork] {
        // ContainerClientProvider currently exposes networkGet(id:) for
        // existence probing but no NetworkClient.list equivalent. Keep this
        // explicit so CHAOS-1347 Phase 3 can wire network enumeration when the
        // provider grows that API instead of silently returning partial data.
        throw RuntimeError.notSupported(
            operation: "listNetworks",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    public func get(id: String) async throws -> RuntimeContainer {
        let provider = ContainerClientEnvironment.current
        do {
            let snapshot = try await provider.get(id: id)
            return BridgeContainerClientRuntime.translate(snapshot: snapshot)
        } catch {
            throw RuntimeError.notFound(id: id)
        }
    }

    // MARK: - Lifecycle

    /// Create is intentionally not supported in the Bridge conformer.
    ///
    /// `ContainerClient.create(configuration:options:kernel:)` requires a
    /// `Kernel` binary reference (fetched via `ClientKernel.getDefaultKernel`)
    /// and a fully specified `ContainerConfiguration` (image descriptor,
    /// `ProcessConfiguration`, mounts, etc.) — a much richer surface than
    /// `RuntimeCreateConfiguration` exposes. Bridging these shapes requires
    /// knowing the system kernel path at create-time, which is not available
    /// in the REST API path without additional XPC calls and system state.
    ///
    /// The `AppleContainerizationRuntime` conformer fully implements `create()`
    /// (registry-backed in Phase 1, real lifecycle in Phase 2). Clients using
    /// the Bridge backend should use `compose up` (which calls `container run`
    /// via `RunCommandRunner`) rather than the REST API's `POST /containers/create`.
    ///
    /// Documented in `docs/plans/runtime-abstraction-leaks.md` as Leak #13.
    public func create(
        id: String,
        configuration: RuntimeCreateConfiguration
    ) async throws -> RuntimeContainer {
        throw RuntimeError.notSupported(
            operation: "create",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    // MARK: - Lifecycle Writes (CHAOS-1354)

    public func start(id: String) async throws {
        let provider = ContainerClientEnvironment.current
        do {
            try await provider.start(id: id)
        } catch {
            throw mapUpstreamError(error, id: id, context: "start failed for '\(id)'")
        }
    }

    public func stop(id: String, options: RuntimeStopOptions) async throws {
        let provider = ContainerClientEnvironment.current
        let opts = ContainerStopOptions(
            timeoutInSeconds: Int32(options.timeoutSeconds),
            signal: options.signal
        )
        try await provider.stop(id: id, opts: opts)
    }

    public func kill(id: String, signal: Int32) async throws {
        let provider = ContainerClientEnvironment.current
        do {
            try await provider.kill(id: id, signal: signal)
        } catch {
            throw mapUpstreamError(error, id: id, context: "kill failed for '\(id)' (signal \(signal))")
        }
    }

    public func wait(id: String, timeoutSeconds: Int) async throws -> RuntimeExitStatus {
        throw RuntimeError.notSupported(
            operation: "wait",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    public func remove(id: String, force: Bool) async throws {
        let provider = ContainerClientEnvironment.current
        try await provider.delete(id: id, force: force)
    }

    // MARK: - Observability

    public func logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame> {
        let provider = ContainerClientEnvironment.current
        let handles: [FileHandle]
        do {
            handles = try await provider.logs(
                id: id,
                options: ContainerLogOptions(since: options.since, timestamps: options.timestamps)
            )
        } catch {
            throw RuntimeError.notFound(id: id)
        }

        return BridgeContainerClientRuntime.streamLogs(from: handles, options: options)
    }

    public func events() async throws -> AsyncStream<RuntimeContainerEvent> {
        let provider = ContainerClientEnvironment.current
        return AsyncStream { continuation in
            let task = Task {
                var lastTimestamp: Date?

                // `ContainerClient.events()` returns the daemon's buffered
                // lifecycle event snapshot rather than a push stream. Poll at
                // the CLI's existing 1s cadence and yield only events newer
                // than the last emitted timestamp.
                while !Task.isCancelled {
                    do {
                        let events = try await provider.events()
                            .filter { event in
                                guard let lastTimestamp else { return true }
                                return event.timestamp > lastTimestamp
                            }
                            .sorted { $0.timestamp < $1.timestamp }

                        for event in events {
                            continuation.yield(BridgeContainerClientRuntime.translate(event: event))
                            if lastTimestamp == nil || event.timestamp > lastTimestamp! {
                                lastTimestamp = event.timestamp
                            }
                        }

                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch is CancellationError {
                        break
                    } catch {
                        continuation.finish()
                        break
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func statistics(for id: String) async throws -> RuntimeStatistics {
        let provider = ContainerClientEnvironment.current
        do {
            let raw = try await provider.stats(id: id)
            return BridgeContainerClientRuntime.translate(stats: raw)
        } catch {
            throw mapUpstreamError(error, id: id, context: "stats failed for '\(id)'")
        }
    }

    // MARK: - Commands

    public func exec(id: String, command: [String], options: RuntimeExecOptions) async throws -> RuntimeExecResult {
        var argv = ["container", "exec"]
        if options.detach { argv.append("-d") }
        if options.interactive { argv.append("-i") }
        if options.tty { argv.append("-t") }
        for env in options.environment {
            argv.append(contentsOf: ["-e", env])
        }
        if let user = options.user {
            argv.append(contentsOf: ["--user", user])
        }
        if let workingDirectory = options.workingDirectory {
            argv.append(contentsOf: ["--workdir", workingDirectory])
        }
        argv.append(id)
        argv.append(contentsOf: command)

        let lines = LockedCommandLines()
        let result = try await RunnerEnvironment.current.run(
            RunRequest(kind: .streaming, argv: argv),
            onStdout: { lines.appendStdout($0) },
            onStderr: { lines.appendStderr($0) }
        )
        return RuntimeExecResult(stdout: lines.stdoutSnapshot(), stderr: lines.stderrSnapshot(), exitCode: result.exitCode)
    }

    public func processes(id: String) async throws -> RuntimeProcessList {
        let result = try await exec(
            id: id,
            command: ["ps", "-ef"],
            options: RuntimeExecOptions(detach: false, interactive: false, tty: false)
        )
        guard result.exitCode == 0 else {
            throw RuntimeError.backendFailure(message: result.stderr.joined(separator: "\n"))
        }
        return RuntimeProcessList(containerId: id, output: result.stdout)
    }

    public func pushImage(reference: String) async throws -> RuntimeImagePushResult {
        let lines = LockedCommandLines()
        let result = try await RunnerEnvironment.current.run(
            RunRequest(kind: .streaming, argv: ["container", "image", "push", reference]),
            onStdout: { lines.appendStdout($0) },
            onStderr: { lines.appendStderr($0) }
        )
        return RuntimeImagePushResult(
            imageReference: reference,
            stdout: lines.stdoutSnapshot(),
            stderr: lines.stderrSnapshot(),
            exitCode: result.exitCode
        )
    }

    // MARK: - Stats translation

    static func translate(stats: ContainerStats) -> RuntimeStatistics {
        let network: [RuntimeStatistics.Network]
        if let rx = stats.networkRxBytes, let tx = stats.networkTxBytes {
            // The bridge rolls all interfaces into one aggregate "eth0" entry;
            // per-interface breakdown is not available via ContainerStats today.
            // Abstraction leak documented in docs/plans/runtime-abstraction-leaks.md.
            network = [RuntimeStatistics.Network(interface: "eth0", receivedBytes: rx, transmittedBytes: tx)]
        } else {
            network = []
        }
        return RuntimeStatistics(
            id: stats.id,
            cpuUsageUsec: stats.cpuUsageUsec,
            memoryUsageBytes: stats.memoryUsageBytes,
            memoryLimitBytes: stats.memoryLimitBytes,
            oomKillCount: nil, // Not available via ContainerStats; MemoryEventStatistics needed
            networks: network,
            sampledAt: Date()
        )
    }

    // MARK: - Translation

    /// Translate an upstream `ContainerSnapshot` into the apple-free
    /// `RuntimeContainer` shape. The `id` from `configuration.id` matches
    /// what the existing `compose ps` filter logic expects (project-prefix
    /// match), so call sites see byte-identical IDs.
    static func translate(snapshot: ContainerSnapshot) -> RuntimeContainer {
        RuntimeContainer(
            id: snapshot.configuration.id,
            imageReference: snapshot.configuration.image.reference,
            status: translate(status: snapshot.status),
            publishedPorts: snapshot.configuration.publishedPorts.map(translate(port:)),
            createdAt: nil,
            startedAt: snapshot.startedDate,
            lastExitCode: snapshot.lastExitCode
        )
    }

    static func translate(status: RuntimeStatus) -> RuntimeContainerStatus {
        switch status {
        case .running: return .running
        case .stopped: return .stopped
        case .stopping: return .stopping
        case .unknown: return .unknown
        }
    }

    static func translate(port: PublishPort) -> RuntimePublishedPort {
        RuntimePublishedPort(
            hostAddress: port.hostAddress.description,
            hostPort: port.hostPort,
            containerPort: port.containerPort,
            proto: port.proto == .udp ? .udp : .tcp,
            count: port.count
        )
    }

    static func translate(event: ContainerEvent) -> RuntimeContainerEvent {
        switch event.action {
        case .create:
            return .created(id: event.containerId, at: event.timestamp)
        case .start:
            return .started(id: event.containerId, at: event.timestamp)
        case .stop, .die:
            return .stopped(id: event.containerId, exitCode: 0, at: event.timestamp)
        case .destroy:
            return .removed(id: event.containerId, at: event.timestamp)
        }
    }

    /// Map an upstream error from apple/container's XPC surface into the
    /// backend-neutral `RuntimeError` vocabulary via the shared
    /// `RuntimeErrorMapper`. See `RuntimeErrorMapper.map(_:id:)` for the full
    /// mapping table.
    ///
    /// - Parameters:
    ///   - error: The upstream error to map.
    ///   - id: The container id involved in the operation. Used in `.notFound`
    ///     and as part of the `.backendFailure` message when `context` is given.
    ///   - context: An optional human-readable operation name (e.g.
    ///     `"stats failed for 'web'"`) prepended to the failure message, so
    ///     existing diagnostic strings are preserved unchanged.
    private func mapUpstreamError(
        _ error: Error,
        id: String? = nil,
        context: String? = nil
    ) -> RuntimeError {
        let mapped = RuntimeErrorMapper.map(error, id: id)
        // Prepend the context string to backendFailure messages so existing
        // diagnostic output is preserved unchanged.
        if let context, case .backendFailure(let msg) = mapped {
            return .backendFailure(message: "\(context): \(msg)")
        }
        return mapped
    }

    private static func streamLogs(
        from handles: [FileHandle],
        options: RuntimeLogOptions
    ) -> AsyncStream<RuntimeLogFrame> {
        AsyncStream { continuation in
            let task = Task {
                let frames = await collectLogFrames(from: handles)
                let selected = applyTail(options.tail, to: frames)
                for frame in selected {
                    continuation.yield(frame)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
                for handle in handles {
                    try? handle.close()
                }
            }
        }
    }

    private static func collectLogFrames(from handles: [FileHandle]) async -> [RuntimeLogFrame] {
        var frames: [RuntimeLogFrame] = []
        for (index, handle) in handles.enumerated() {
            let source: RuntimeLogFrame.Source = index == 0 ? .stdout : .stderr
            frames.append(contentsOf: await collectLogFrames(from: handle, source: source))
        }
        return frames.sorted { $0.timestamp < $1.timestamp }
    }

    private static func collectLogFrames(
        from handle: FileHandle,
        source: RuntimeLogFrame.Source
    ) async -> [RuntimeLogFrame] {
        var frames: [RuntimeLogFrame] = []
        var line = Data()

        do {
            for try await byte in handle.bytes {
                if Task.isCancelled { break }
                if byte == 10 {
                    appendLogFrame(line: &line, source: source, to: &frames)
                } else {
                    line.append(byte)
                }
            }
            appendLogFrame(line: &line, source: source, to: &frames)
        } catch {
            appendLogFrame(line: &line, source: source, to: &frames)
        }

        return frames
    }

    private static func appendLogFrame(
        line: inout Data,
        source: RuntimeLogFrame.Source,
        to frames: inout [RuntimeLogFrame]
    ) {
        if line.last == 13 {
            line.removeLast()
        }
        guard !line.isEmpty else { return }
        frames.append(RuntimeLogFrame(timestamp: Date(), source: source, data: line))
        line.removeAll(keepingCapacity: true)
    }

    private static func applyTail(_ tail: Int?, to frames: [RuntimeLogFrame]) -> [RuntimeLogFrame] {
        guard let tail, tail >= 0, tail < frames.count else { return frames }
        return Array(frames.suffix(tail))
    }

    private static var runtimeArch: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

// MARK: - Image lifecycle (CHAOS-1425, Leak #14)

extension BridgeContainerClientRuntime {

    /// Pull each spec sequentially via `RunCommandRunner.swiftAPI(name: "ImagePull")`,
    /// emitting `started` / `completed` / `failed` events. Per-blob progress is
    /// not surfaced — `ImagePull` runs in-process under `.swiftAPI` and prints
    /// its `ProgressBar` directly to host stdout, bypassing the runner's
    /// `onStdout` callback. Capturing that requires either bypassing the
    /// runner to call `ClientImage.pull(progressUpdate:)` directly, or
    /// redirecting host stdout — both are out of scope for CHAOS-1425.
    public func pull(
        specs: [RuntimePullSpec],
        ignoreFailures: Bool
    ) async throws -> AsyncStream<RuntimePullEvent> {
        AsyncStream { continuation in
            let task = Task {
                for spec in specs {
                    if Task.isCancelled { break }
                    let qualified = ComposeUp.qualifyImageReference(spec.imageReference)
                    let platform = spec.platform ?? defaultRuntimePlatform()
                    let argv = [qualified, "--platform", platform]

                    continuation.yield(RuntimePullEvent(
                        timestamp: Date(),
                        service: spec.service,
                        imageReference: qualified,
                        kind: .started
                    ))

                    do {
                        _ = try await RunnerEnvironment.current.run(
                            RunRequest(
                                kind: .swiftAPI(name: "ImagePull"),
                                argv: argv,
                                cwd: nil
                            ),
                            onStdout: nil,
                            onStderr: nil
                        )
                        continuation.yield(RuntimePullEvent(
                            timestamp: Date(),
                            service: spec.service,
                            imageReference: qualified,
                            kind: .completed
                        ))
                    } catch {
                        continuation.yield(RuntimePullEvent(
                            timestamp: Date(),
                            service: spec.service,
                            imageReference: qualified,
                            kind: .failed,
                            message: error.localizedDescription
                        ))
                        if !ignoreFailures { break }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Build images for the given specs via `RunCommandRunner.swiftAPI(name: "BuildCommand")`.
    ///
    /// ## Context resolution
    ///
    /// Each spec may carry a `projectName` pointing at a project ingested via
    /// `POST /projects/{name}` (CHAOS-1426). When present the bridge looks up
    /// build-context paths from `RuntimeEnvironment.projectRegistry`. When the
    /// spec already has `contextPath` set (CLI path, CHAOS-1427 territory) that
    /// takes precedence. If neither is available the service emits `notSupported`.
    ///
    /// ## Event shape
    ///
    /// Coarse-grained — one `started` + one `completed` (or `failed`) per spec,
    /// matching the `pull(...)` wire format from CHAOS-1425. Per-blob progress
    /// is deferred to a future ticket (see CHAOS-1425 PR comment re: ProgressBar
    /// writing directly to host stdout).
    public func build(
        specs: [RuntimeBuildSpec]
    ) async throws -> AsyncStream<RuntimeBuildEvent> {
        // Snapshot of the ProjectRegistry task-local — captured before the
        // AsyncStream closure so we can call it from the unstructured Task
        // (task-locals propagate into Task {} blocks, not detached tasks).
        let registry = RuntimeEnvironment.projectRegistry

        return AsyncStream { continuation in
            let task = Task {
                for spec in specs {
                    if Task.isCancelled { break }

                    // 1. Resolve the context path: spec field wins, then registry lookup.
                    let resolvedContext: BuildContext?
                    if let explicitPath = spec.contextPath {
                        // Caller already resolved paths (e.g., CLI codepath).
                        resolvedContext = BuildContext(contextPath: explicitPath, dockerfile: spec.dockerfile)
                    } else if let projectName = spec.projectName,
                              let contexts = try? await registry.buildContexts(for: projectName),
                              let ctx = contexts[spec.service] {
                        resolvedContext = ctx
                    } else {
                        resolvedContext = nil
                    }

                    guard let context = resolvedContext else {
                        // No context available — emit notSupported and continue.
                        continuation.yield(RuntimeBuildEvent(
                            timestamp: Date(),
                            service: spec.service,
                            kind: .notSupported,
                            message: "No build context available for service '\(spec.service)'. Ingest the project via POST /projects/{name} first."
                        ))
                        continue
                    }

                    // 2. Emit started.
                    continuation.yield(RuntimeBuildEvent(
                        timestamp: Date(),
                        service: spec.service,
                        kind: .started
                    ))

                    // 3. Build argv matching Application.BuildCommand.parse(_:) expectations.
                    // Convention mirrors ComposeBuild.buildService — context path first,
                    // then options. See Sources/Container-Compose/Commands/ComposeBuild.swift.
                    let imageTag = spec.imageTag ?? ComposeUp.qualifyImageReference("\(spec.service):latest")
                    var argv: [String] = [context.contextPath]
                    argv.append(contentsOf: ["--file", context.dockerfile ?? "Dockerfile"])
                    argv.append(contentsOf: ["--tag", imageTag])
                    if spec.noCache { argv.append("--no-cache") }

                    do {
                        _ = try await RunnerEnvironment.current.run(
                            RunRequest(kind: .swiftAPI(name: "BuildCommand"), argv: argv, cwd: nil),
                            onStdout: nil,
                            onStderr: nil
                        )
                        continuation.yield(RuntimeBuildEvent(
                            timestamp: Date(),
                            service: spec.service,
                            kind: .completed
                        ))
                    } catch {
                        continuation.yield(RuntimeBuildEvent(
                            timestamp: Date(),
                            service: spec.service,
                            kind: .failed,
                            message: error.localizedDescription
                        ))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class LockedCommandLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout: [String] = []
    private var stderr: [String] = []

    func appendStdout(_ line: String) {
        lock.withLock { stdout.append(line) }
    }

    func appendStderr(_ line: String) {
        lock.withLock { stderr.append(line) }
    }

    func stdoutSnapshot() -> [String] {
        lock.withLock { stdout }
    }

    func stderrSnapshot() -> [String] {
        lock.withLock { stderr }
    }
}

// MARK: - Resource CRUD (CHAOS-1353)

extension BridgeContainerClientRuntime {

    // MARK: Networks

    /// Create a network by delegating to `Application.NetworkCreate` in-process
    /// via the `RunnerEnvironment` seam (the same `.swiftAPI(name: "NetworkCreate")`
    /// path used by `ComposeCreate`).
    ///
    /// ## Design rationale (CHAOS-1408)
    ///
    /// `ContainerAPIClient` exposes only `NetworkClient.get(id:)` for network
    /// reads; there is no programmatic create/delete surface. The `container`
    /// CLI wraps platform networking internally, so we piggyback on
    /// `Application.NetworkCreate` (already in scope via `ContainerCommands`)
    /// via the `RunCommandRunner` seam rather than shelling out to the binary.
    /// This is functionally equivalent to the previous `RunnerEnvironment.current
    /// .run(RunRequest(kind: .swiftAPI(name: "NetworkCreate"), ...))` call in
    /// `ComposeUp.setupNetwork` — it just lives here so call sites can use the
    /// `Runtime` abstraction instead of building argv manually.
    ///
    /// The returned `RuntimeNetwork` is synthesized from the spec fields rather
    /// than round-tripped through `NetworkClient.get(id:)` because the `get`
    /// call is unreliable immediately after creation on some system versions and
    /// returns `NetworkState`, not `RuntimeNetwork`. The id is set to the name
    /// (matching apple/container's convention where the network name is its
    /// stable identity) until a richer list API becomes available.
    ///
    /// ## CHAOS-1409 IPAM round-trip
    ///
    /// `spec.subnet` and `spec.gateway` are forwarded to argv as `--subnet` /
    /// `--gateway` flags and copied onto the synthesized `RuntimeNetwork` so the
    /// IPAM round-trip contract holds for this conformer. The upstream
    /// `NetworkClient.get(id:)` response does not surface IPAM details, so the
    /// values come from the spec rather than a post-create inspect.
    ///
    /// Error translation:
    /// - If `Application.NetworkCreate.run()` throws because the network already
    ///   exists, the error message contains "already exists"; this is mapped to
    ///   `RuntimeError.alreadyExists(id: spec.name)` via `RuntimeErrorMapper`.
    /// - All other upstream errors become `RuntimeError.backendFailure`.
    public func createNetwork(spec: RuntimeCreateNetworkSpec) async throws -> RuntimeNetwork {
        // Build the argv that `Application.NetworkCreate.parse(_:)` expects.
        // Mirrors `ComposeUp.setupNetwork`'s argv construction, minus the
        // idempotency guard (the caller owns that).
        var argv: [String] = [spec.name]

        // Driver: map "bridge" (compose default) → no-op (apple/container
        // plugin default); any other driver is forwarded as --plugin.
        if !spec.driver.isEmpty && spec.driver != "bridge" {
            argv.append(contentsOf: ["--plugin", spec.driver])
        }

        // CHAOS-1409 IPAM passthrough.
        if let subnet = spec.subnet {
            argv.append(contentsOf: ["--subnet", subnet])
        }
        if let gateway = spec.gateway {
            argv.append(contentsOf: ["--gateway", gateway])
        }

        // Labels
        for (key, value) in spec.labels.sorted(by: { $0.key < $1.key }) {
            argv.append(contentsOf: ["--label", "\(key)=\(value)"])
        }

        do {
            _ = try await RunnerEnvironment.current.run(
                RunRequest(kind: .swiftAPI(name: "NetworkCreate"), argv: argv, cwd: nil),
                onStdout: nil,
                onStderr: nil
            )
        } catch {
            throw RuntimeErrorMapper.map(error, id: spec.name)
        }

        return RuntimeNetwork(
            id: spec.name,
            name: spec.name,
            driver: spec.driver,
            subnet: spec.subnet,
            gateway: spec.gateway,
            labels: spec.labels,
            attachedContainerIds: []
        )
    }

    /// Remove a network by id using `Application.NetworkRemove` via the
    /// `RunnerEnvironment` seam.
    ///
    /// Note: `apple/container`'s network remove command does not expose a
    /// programmatic Swift API as of Phase 8; this path continues to throw
    /// `.notSupported` until `ContainerCommands` gains a `NetworkRemove`
    /// type or a `NetworkClient.delete(id:)` method is available.
    ///
    /// Documented as abstraction leak in `docs/plans/runtime-abstraction-leaks.md`
    /// (Leak #9 — remove path only).
    public func removeNetwork(id: String) async throws {
        throw RuntimeError.notSupported(
            operation: "removeNetwork",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    // MARK: Volumes

    public func listVolumes() async throws -> [RuntimeVolume] {
        try await RuntimeVolumeClient.list()
    }

    public func createVolume(spec: RuntimeCreateVolumeSpec) async throws -> RuntimeVolume {
        try await RuntimeVolumeClient.create(spec: spec)
    }

    public func removeVolume(name: String) async throws {
        try await RuntimeVolumeClient.remove(name: name)
    }

    // MARK: Secrets

    /// The `apple/container` XPC client has no secret management API surface.
    /// Documented as abstraction leak in `docs/plans/runtime-abstraction-leaks.md`
    /// (Leak #11).
    public func listSecrets() async throws -> [RuntimeSecret] {
        throw RuntimeError.notSupported(
            operation: "listSecrets",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    /// See `listSecrets` for rationale. Documented as Leak #11.
    public func createSecret(spec: RuntimeCreateSecretSpec) async throws -> RuntimeSecret {
        throw RuntimeError.notSupported(
            operation: "createSecret",
            conformer: "BridgeContainerClientRuntime"
        )
    }

    /// See `listSecrets` for rationale. Documented as Leak #11.
    public func removeSecret(name: String) async throws {
        throw RuntimeError.notSupported(
            operation: "removeSecret",
            conformer: "BridgeContainerClientRuntime"
        )
    }
}
