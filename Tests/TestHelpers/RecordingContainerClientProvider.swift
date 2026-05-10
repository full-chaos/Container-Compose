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

import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import SystemPackage
@testable import ContainerComposeCore
import ContainerResource
import ContainerizationOCI
import Foundation
@testable import ContainerComposeCore

/// Recording fake for `ContainerClientProvider` (the second seam, per
/// `docs/plans/PLAN-recorder-seam.md` §10 Q2).
///
/// Every method appends an `Entry` to the actor's log in time order, then
/// returns a "harmless" stub. The two read methods (`get(id:)`,
/// `networkGet(id:)`) intentionally THROW (rather than return some bogus
/// value) so the existing `try?` wrappers at call sites coerce to `nil` —
/// matching the behavior of the real client when the requested container or
/// network does not exist. This is the contract that makes
/// `RuntimeArgvTests`'s `cmd.run()` calls reach the `RunCommandRunner` seam
/// without first crashing on a missing container snapshot.
///
/// CHAOS-1494: there is ONE exception to the throw-on-`get` rule. When the
/// requested id matches the embedded DNS sidecar naming convention
/// (`<projectName>-compose-dns`), `get(id:)` returns a synthesized running
/// snapshot attached to the project's implicit default network. CHAOS-1494
/// makes `ComposeUp.run()` synthesize an implicit project default network
/// for compose files with no top-level `networks:` declaration AND start the
/// sidecar on it. Without this auto-stub, every existing test that uses a
/// minimal compose file would block forever in `EmbeddedDNSSidecar.start`'s
/// post-create poll waiting for the sidecar to come up. Tests that need to
/// observe a missing/unhealthy sidecar use a custom provider (see
/// `ComposeUpDNSStabilityTests`) and don't go through this fake.
public actor RecordingContainerClientProvider: ContainerClientProvider {

    /// One entry per method call. Filters are serialized via `String(describing:)`
    /// because `ContainerListFilters` doesn't conform to `Equatable`.
    public enum Entry: Sendable, Equatable {
        case create(id: String, imageReference: String)
        case list(filters: String)
        case get(id: String)
        case stop(id: String)
        case delete(id: String, force: Bool)
        case logs(id: String)
        case events
        case networkGet(id: String)
        case imageList
        case kill(id: String, signal: Int32)
        case start(id: String)
    }

    public private(set) var entries: [Entry] = []
    private let imageReferences: [String]
    private let logHandles: [FileHandle]?
    private let containerEvents: [ContainerEvent]

    /// CHAOS-1446 Phase 3: ids the recorder should treat as already-existing
    /// containers (returns a synthetic stopped snapshot from `get(id:)`).
    /// Tests that drive `compose start` / `compose stop` / `compose restart`
    /// past the "container not found" early-return seed this set with the
    /// expected service container names so the per-service start/stop logic
    /// actually invokes `runner.run` / `provider.stop` and the resulting
    /// argv / .stop entries become observable for ordering assertions.
    private var stubbedRunningContainerIDs: Set<String> = []

    /// CHAOS-1446 Phase 3 BLOCK fix: number of `stop(id:)` invocations
    /// currently in-flight on this actor. Incremented on entry, decremented
    /// via `defer` on exit. Mirrors the Phase 1 RecordingRunner pattern.
    private var inFlightStops: Int = 0

    /// CHAOS-1446 Phase 3 BLOCK fix: high-water mark of `inFlightStops`.
    /// `parallelStopDiamondFanOut` asserts this is `>= 2` after running the
    /// diamond fixture (UltraBrain Critical #8) — a serial implementation
    /// would clamp this at 1 even with the ordering invariants holding.
    private var peakStopConcurrency: Int = 0

    public init(
        imageReferences: [String] = [],
        logHandles: [FileHandle]? = nil,
        containerEvents: [ContainerEvent] = []
    ) {
        self.imageReferences = imageReferences
        self.logHandles = logHandles
        self.containerEvents = containerEvents
    }

    // MARK: - ContainerClientProvider

    public func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> ContainerSnapshot {
        entries.append(.create(id: id, imageReference: configuration.imageReference))
        let process = ProcessConfiguration(
            executable: configuration.command.first ?? "/bin/sh",
            arguments: Array(configuration.command.dropFirst()),
            environment: configuration.environment,
            workingDirectory: configuration.workingDirectory ?? "/"
        )
        var containerConfiguration = ContainerConfiguration(
            id: id,
            image: ImageDescription(
                reference: configuration.imageReference,
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:\(String(repeating: "0", count: 64))",
                    size: 0
                )
            ),
            process: process
        )
        containerConfiguration.publishedPorts = try configuration.publishedPorts.map { port in
            try Parser.publishPort(Self.publishArg(for: port))
        }
        return ContainerSnapshot(
            configuration: containerConfiguration,
            status: .stopped,
            networks: []
        )
    }

    public func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] {
        entries.append(.list(filters: String(describing: filters)))
        // Empty list — call sites iterate, find nothing, and move on. This is
        // the same shape the real client returns on a host with no containers.
        return []
    }

    public func get(id: String) async throws -> ContainerSnapshot {
        entries.append(.get(id: id))
        // CHAOS-1494: auto-stub the embedded DNS sidecar so
        // `EmbeddedDNSSidecar.start`'s probe-then-adopt path completes
        // without timing out. See type-level docs for rationale.
        if let sidecarSnapshot = try? Self.makeRunningSidecarSnapshot(for: id) {
            return sidecarSnapshot
        }
        // CHAOS-1446 Phase 3: synthesize a `.stopped` snapshot for ids
        // explicitly stubbed via `stubRunningContainer(id:)`. Status `.stopped`
        // works for both ComposeStop (which doesn't gate on status) and
        // ComposeStart (which only starts containers that aren't .running).
        if stubbedRunningContainerIDs.contains(id) {
            return Self.makeStubStoppedSnapshot(for: id)
        }
        // Throw to mimic "container not found". Call sites use `try?` to
        // coerce this to `nil`, which is the same code path as a real
        // not-found response from `ContainerClient.get(id:)`.
        throw NSError(
            domain: "RecordingContainerClientProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no container '\(id)' (recorded fake)"]
        )
    }

    public func stop(id: String, opts: ContainerStopOptions) async throws {
        entries.append(.stop(id: id))

        // CHAOS-1446 Phase 3 BLOCK fix: track concurrency for the diamond
        // fan-out assertion. Increment BEFORE the explicit `Task.sleep`
        // below so racing stop(id:) calls observe each other's in-flight
        // increments while the actor is suspended.
        inFlightStops += 1
        peakStopConcurrency = max(peakStopConcurrency, inFlightStops)
        defer { inFlightStops -= 1 }

        // Brief explicit suspension to enable actor reentrancy. Identical
        // pattern + justification to Phase 2's RecordingRunner.run() change:
        // a bare `Task.yield()` is sufficient for direct multi-task call
        // patterns, but for fan-out scenarios where bodies arrive at the
        // actor after intermediate awaits (here: provider.get → provider.stop
        // chain), the yield-resume happens before the next stop(id:) lands
        // in the mailbox. 100µs sleep keeps the actor occupied just long
        // enough for late arrivals to land under reentrancy. Existing tests
        // are unaffected (same observable contract, ~100µs slower per call).
        try? await Task.sleep(nanoseconds: 100_000)
    }

    public func delete(id: String, force: Bool) async throws {
        entries.append(.delete(id: id, force: force))
    }

    public func logs(id: String) async throws -> [FileHandle] {
        entries.append(.logs(id: id))
        throw NSError(
            domain: "RecordingContainerClientProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no logs for container '\(id)' (recorded fake)"]
        )
    }

    public func logs(id: String, options: ContainerLogOptions) async throws -> [FileHandle] {
        entries.append(.logs(id: id))
        if let logHandles {
            return logHandles
        }
        throw NSError(
            domain: "RecordingContainerClientProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no logs for container '\(id)' (recorded fake)"]
        )
    }

    public func networkGet(id: String) async throws -> NetworkState {
        entries.append(.networkGet(id: id))
        // Throw to mimic "network not found"; call sites use `try? ... == nil`
        // as the "should I create the network?" gate. Throwing keeps the
        // existing flow honest: under the recorder, the recorded request
        // proceeds to `setupNetwork`'s subsequent `RunRequest.swiftAPI` call.
        throw NSError(
            domain: "RecordingContainerClientProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no network '\(id)' (recorded fake)"]
        )
    }

    public func imageList() async throws -> [ClientImage] {
        entries.append(.imageList)

        // CHAOS-1446 Phase 2: yield once before returning so concurrent
        // imageList() invocations from racing pull/build bodies can interleave
        // under actor reentrancy. Without this yield, the recorder serializes
        // every imageList() to completion (no awaits inside), which staggers
        // the downstream `runner.run(...)` calls in `pullImage` and prevents
        // tests like `parallelPullsAchieveConcurrency` from observing
        // peakConcurrency >= 2 at the runner. Mirrors the same reentrancy
        // pattern Phase 1 added to `RecordingRunner.run(...)`.
        await Task.yield()

        return imageReferences.map { reference in
            ClientImage(description: ImageDescription(
                reference: reference,
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:\(String(repeating: "0", count: 64))",
                    size: 0
                )
            ))
        }
    }

    public func events() async throws -> [ContainerEvent] {
        entries.append(.events)
        return containerEvents
    }

    public func stats(id: String) async throws -> ContainerStats {
        // Recording fake returns an empty stub so call sites that go through
        // BridgeContainerClientRuntime.statistics(for:) don't reach the live
        // ContainerClient XPC daemon during tests.
        ContainerStats(
            id: id,
            memoryUsageBytes: nil,
            memoryLimitBytes: nil,
            cpuUsageUsec: nil,
            networkRxBytes: nil,
            networkTxBytes: nil,
            blockReadBytes: nil,
            blockWriteBytes: nil,
            numProcesses: nil
        )
    }

    // MARK: - Lifecycle Provider Methods (CHAOS-1354)

    public func kill(id: String, signal: Int32) async throws {
        entries.append(.kill(id: id, signal: signal))
    }

    public func start(id: String) async throws {
        entries.append(.start(id: id))
    }

    // MARK: - Test affordances

    /// Snapshot of recorded entries in time order.
    public func entriesSnapshot() async -> [Entry] {
        entries
    }

    // MARK: - Unordered / parallel-friendly assertions (CHAOS-1446)

    /// Returns `true` iff the FIRST recorded entry matching
    /// `firstPredicate` was recorded BEFORE the FIRST entry matching
    /// `secondPredicate`. Returns `false` if either predicate is unmatched.
    ///
    /// Use this when parallel scheduling makes inter-service event ordering
    /// non-deterministic but you still need to assert intra-service ordering
    /// (e.g., "stop fires before delete for the SAME container, even if
    /// another service's stop interleaves").
    public func happensBefore(
        _ firstPredicate: @Sendable (Entry) -> Bool,
        _ secondPredicate: @Sendable (Entry) -> Bool
    ) -> Bool {
        guard let firstIdx = entries.firstIndex(where: firstPredicate),
              let secondIdx = entries.firstIndex(where: secondPredicate) else {
            return false
        }
        return firstIdx < secondIdx
    }

    /// All recorded entries matching `predicate`, in recorded (time) order.
    /// Use when set/multiset assertions are sufficient and inter-event
    /// ordering between matching events should be ignored by the caller.
    public func unorderedEntries(matching predicate: @Sendable (Entry) -> Bool) -> [Entry] {
        entries.filter(predicate)
    }

    /// CHAOS-1446 Phase 3: register `id` so subsequent `get(id:)` calls
    /// return a synthetic `.stopped` ContainerSnapshot instead of throwing
    /// "container not found". Used by `compose start` / `compose stop` /
    /// `compose restart` ordering tests so the per-service start/stop logic
    /// actually invokes `runner.run("container start")` /
    /// `provider.stop(id:)` and the resulting argv / .stop entries become
    /// observable for happens-before assertions.
    public func stubRunningContainer(id: String) {
        stubbedRunningContainerIDs.insert(id)
    }

    /// CHAOS-1446 Phase 3 BLOCK fix: high-water mark of concurrent
    /// `stop(id:)` invocations on this actor. Used by
    /// `parallelStopDiamondFanOut` to assert reverse-DAG fan-out actually
    /// achieves parallelism (`>= expected`, loose bound to avoid scheduler-
    /// timing flakes). `>= 1` whenever any stop was issued; `>= 2` requires
    /// concurrent invocations and the actor's `Task.sleep` reentrancy point.
    public func peakConcurrency() -> Int { peakStopConcurrency }

    /// CHAOS-1446 Phase 3 BLOCK fix: number of `stop(id:)` invocations
    /// currently in-flight on this actor. Equals 0 when the actor is idle.
    public func currentInFlightStops() -> Int { inFlightStops }

    private static func publishArg(for port: RuntimePublishedPort) -> String {
        let hostPort = port.count > 1 ? "\(port.hostPort)-\(port.hostPort + port.count - 1)" : "\(port.hostPort)"
        let containerPort = port.count > 1 ? "\(port.containerPort)-\(port.containerPort + port.count - 1)" : "\(port.containerPort)"
        let proto = port.proto == .udp ? "/udp" : ""
        return "\(port.hostAddress):\(hostPort):\(containerPort)\(proto)"
    }

    /// CHAOS-1494: synthesize a running embedded-DNS-sidecar snapshot when
    /// `id` matches the sidecar naming convention (`<projectName>-compose-dns`).
    /// Returns `nil` for non-sidecar ids so the caller falls through to the
    /// throw-on-not-found path. The synthesized attachment uses the project's
    /// implicit default network name (`<projectName>-default`) which is what
    /// `ComposeUp.computeImplicitDefaultNetworkName` emits when the compose
    /// file declares no top-level `networks:` (the dominant pattern in
    /// `RuntimeArgvTests` and similar argv-shape suites). Tests that exercise
    /// projects WITH explicit top-level networks use a custom provider
    /// (see `ComposeUpDNSStabilityTests`) and don't reach this path.
    private static func makeRunningSidecarSnapshot(for id: String) throws -> ContainerSnapshot? {
        let suffix = "-compose-dns"
        guard id.hasSuffix(suffix), id.count > suffix.count else { return nil }
        let projectName = String(id.dropLast(suffix.count))
        let implicitNetwork = "\(projectName)-default"
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            size: 0
        )
        let image = ImageDescription(reference: EmbeddedDNSSidecar.image, descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "/coredns",
            arguments: ["-conf", "/etc/coredns/Corefile"],
            environment: [],
            workingDirectory: "/"
        )
        let configuration = ContainerConfiguration(id: id, image: image, process: process)
        let attachment = ContainerResource.Attachment(
            network: implicitNetwork,
            hostname: id,
            ipv4Address: try CIDRv4("10.0.0.5/24"),
            ipv4Gateway: try IPv4Address("10.0.0.1"),
            ipv6Address: nil,
            macAddress: nil
        )
        return ContainerSnapshot(
            configuration: configuration,
            status: .running,
            networks: [attachment]
        )
    }

    /// CHAOS-1446 Phase 3: synthetic `.stopped` ContainerSnapshot for any
    /// id stubbed via `stubRunningContainer(id:)`. Status `.stopped` lets
    /// both ComposeStop (which doesn't gate on status) and ComposeStart
    /// (which only starts containers that aren't `.running`) execute their
    /// real per-service work, exposing `.stop` entries and `"container
    /// start"` runner argvs that ordering tests can assert on.
    private static func makeStubStoppedSnapshot(for id: String) -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            size: 0
        )
        let image = ImageDescription(reference: "alpine:latest", descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/"
        )
        let configuration = ContainerConfiguration(id: id, image: image, process: process)
        return ContainerSnapshot(
            configuration: configuration,
            status: .stopped,
            networks: []
        )
    }
}
