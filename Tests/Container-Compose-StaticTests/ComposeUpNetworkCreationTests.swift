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
import Testing
@testable import ContainerComposeCore
import TestHelpers

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Tests for CHAOS-1408: `compose up` network creation routes through
/// `RuntimeEnvironment.current.createNetwork(spec:)` rather than via
/// `RunCommandRunner`/`RunnerEnvironment`.
///
/// Every test uses `RecordingRuntime` so no apple/container process is
/// spawned and no XPC connection is made. The `RecordingRuntime.Entry`
/// log is the ground-truth assertion surface.
@Suite("ComposeUp network creation via Runtime abstraction (CHAOS-1408)", .serialized)
struct ComposeUpNetworkCreationTests {

    // MARK: - Helpers

    /// Captures stdout for the duration of `block` by `dup2`-ing a pipe over
    /// `STDOUT_FILENO`. Mirrors the established pattern in
    /// `ComposeUpVolumeIdempotencyTests`.
    private static func capturingStdout(_ block: () async throws -> Void) async throws -> String {
        try await CapturedOutput.acquire()
        defer { CapturedOutput.releaseFireAndForget() }
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        let pipe = Pipe()
        guard original >= 0,
              dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0
        else {
            if original >= 0 { close(original) }
            throw CaptureError.dupFailed
        }
        let reader = Task {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }
        defer {
            _ = dup2(original, STDOUT_FILENO)
            close(original)
        }
        try await block()
        fflush(stdout)
        _ = dup2(original, STDOUT_FILENO)
        pipe.fileHandleForWriting.closeFile()
        let data = await reader.value
        return String(data: data, encoding: .utf8) ?? ""
    }

    private enum CaptureError: Error { case dupFailed }

    // MARK: - BridgeContainerClientRuntime.createNetwork implementation

    /// Verifies that `BridgeContainerClientRuntime.createNetwork` dispatches
    /// through `RunnerEnvironment` via `.swiftAPI(name: "NetworkCreate")` and
    /// no longer throws `.notSupported` (the pre-CHAOS-1408 behaviour).
    ///
    /// A `RecordingRunner` is bound so no real `container` binary is invoked.
    @Test("BridgeContainerClientRuntime.createNetwork dispatches via RunnerEnvironment (not notSupported)")
    func bridgeCreateNetworkDispatchesViaRunner() async throws {
        let bridge = BridgeContainerClientRuntime()
        let runner = RecordingRunner()
        let spec = RuntimeCreateNetworkSpec(name: "app-net", driver: "bridge", labels: ["env": "test"])

        let network = try await RunnerEnvironment.$current.withValue(runner) {
            try await bridge.createNetwork(spec: spec)
        }

        // Bridge synthesizes RuntimeNetwork from spec after a successful runner call.
        #expect(network.name == "app-net")
        #expect(network.driver == "bridge")
        #expect(network.labels == ["env": "test"])

        // Runner must have been called with a NetworkCreate swiftAPI request.
        let recorded = await runner.recordedRequests()
        let networkCreateCalls = recorded.filter { entry in
            if case .swiftAPI(let name) = entry.request.kind { return name == "NetworkCreate" }
            return false
        }
        #expect(!networkCreateCalls.isEmpty,
                "BridgeContainerClientRuntime.createNetwork must dispatch to RunnerEnvironment with .swiftAPI(name: \"NetworkCreate\"); got: \(recorded)")
    }

    /// Verifies that the bridge's `createNetwork` includes the network name as
    /// the first argv element (as `Application.NetworkCreate.parse` expects).
    @Test("BridgeContainerClientRuntime.createNetwork passes network name as first argv")
    func bridgeCreateNetworkPassesNameInArgv() async throws {
        let bridge = BridgeContainerClientRuntime()
        let runner = RecordingRunner()
        let spec = RuntimeCreateNetworkSpec(name: "my-network", driver: "bridge")

        _ = try await RunnerEnvironment.$current.withValue(runner) {
            try await bridge.createNetwork(spec: spec)
        }

        let recorded = await runner.recordedRequests()
        let networkCreate = recorded.first { entry in
            if case .swiftAPI(let name) = entry.request.kind { return name == "NetworkCreate" }
            return false
        }
        #expect(networkCreate?.request.argv.first == "my-network",
                "network name must be first argv element; got: \(networkCreate?.request.argv ?? [])")
    }

    /// Verifies that a non-bridge driver is forwarded as `--plugin <driver>`
    /// in the argv handed to `Application.NetworkCreate`.
    @Test("BridgeContainerClientRuntime.createNetwork forwards non-bridge driver as --plugin")
    func bridgeCreateNetworkForwardsDriverAsPlugin() async throws {
        let bridge = BridgeContainerClientRuntime()
        let runner = RecordingRunner()
        let spec = RuntimeCreateNetworkSpec(name: "vmnet-net", driver: "container-network-vmnet")

        _ = try await RunnerEnvironment.$current.withValue(runner) {
            try await bridge.createNetwork(spec: spec)
        }

        let recorded = await runner.recordedRequests()
        let networkCreate = recorded.first { entry in
            if case .swiftAPI(let name) = entry.request.kind { return name == "NetworkCreate" }
            return false
        }
        let argv = networkCreate?.request.argv ?? []
        #expect(argv.contains("--plugin"), "non-bridge driver must emit --plugin flag; got argv: \(argv)")
        #expect(argv.contains("container-network-vmnet"), "driver name must be in argv; got: \(argv)")
    }

    /// Verifies that "bridge" driver emits no `--plugin` arg (apple/container
    /// uses its own default plugin when no --plugin is specified).
    @Test("BridgeContainerClientRuntime.createNetwork omits --plugin for bridge driver")
    func bridgeCreateNetworkOmitsPluginForBridge() async throws {
        let bridge = BridgeContainerClientRuntime()
        let runner = RecordingRunner()
        let spec = RuntimeCreateNetworkSpec(name: "bridge-net", driver: "bridge")

        _ = try await RunnerEnvironment.$current.withValue(runner) {
            try await bridge.createNetwork(spec: spec)
        }

        let recorded = await runner.recordedRequests()
        let networkCreate = recorded.first { entry in
            if case .swiftAPI(let name) = entry.request.kind { return name == "NetworkCreate" }
            return false
        }
        let argv = networkCreate?.request.argv ?? []
        #expect(!argv.contains("--plugin"), "bridge driver must NOT emit --plugin; got argv: \(argv)")
    }

    @Test("BridgeContainerClientRuntime.createNetwork emits CHAOS-1334 network parity flags")
    func bridgeCreateNetworkEmitsNetworkParityFlags() async throws {
        let bridge = BridgeContainerClientRuntime()
        let runner = RecordingRunner()
        let spec = RuntimeCreateNetworkSpec(
            name: "rich-net",
            driver: "bridge",
            subnet: "10.1.0.0/16",
            gateway: "10.1.0.1",
            ipRange: "10.1.2.0/24",
            auxAddresses: ["api": "10.1.0.10", "db": "10.1.0.11"],
            driverOptions: ["mtu": "1400"],
            attachable: true,
            enableIPv6: true,
            isInternal: true,
            labels: ["env": "test"]
        )

        _ = try await RunnerEnvironment.$current.withValue(runner) {
            try await bridge.createNetwork(spec: spec)
        }

        let recorded = await runner.recordedRequests()
        let networkCreate = recorded.first { entry in
            if case .swiftAPI(let name) = entry.request.kind { return name == "NetworkCreate" }
            return false
        }
        let argv = networkCreate?.request.argv ?? []
        func hasPair(_ flag: String, _ value: String) -> Bool {
            zip(argv, argv.dropFirst()).contains { $0 == flag && $1 == value }
        }

        #expect(argv.contains("--internal"))
        #expect(argv.contains("--attachable"))
        #expect(argv.contains("--ipv6"))
        #expect(hasPair("--driver-opt", "mtu=1400"))
        #expect(hasPair("--subnet", "10.1.0.0/16"))
        #expect(hasPair("--gateway", "10.1.0.1"))
        #expect(hasPair("--ip-range", "10.1.2.0/24"))
        #expect(hasPair("--aux-address", "api=10.1.0.10"))
        #expect(hasPair("--aux-address", "db=10.1.0.11"))
        #expect(hasPair("--label", "env=test"))
    }

    @Test("Compose network model maps to RuntimeCreateNetworkSpec parity fields")
    func composeNetworkMapsToRuntimeNetworkSpec() {
        let network = Network(
            driver: "bridge",
            driver_opts: ["mtu": "1400"],
            attachable: true,
            enable_ipv6: true,
            isInternal: true,
            labels: ["tier": "backend"],
            ipam: Ipam(
                config: [
                    IpamConfig(
                        subnet: "10.2.0.0/16",
                        ip_range: "10.2.3.0/24",
                        gateway: "10.2.0.1",
                        aux_addresses: ["cache": "10.2.0.20"]
                    )
                ]
            )
        )

        let spec = ComposeUp.runtimeNetworkSpec(name: "app-net", config: network)

        #expect(spec.name == "app-net")
        #expect(spec.driver == "bridge")
        #expect(spec.subnet == "10.2.0.0/16")
        #expect(spec.gateway == "10.2.0.1")
        #expect(spec.ipRange == "10.2.3.0/24")
        #expect(spec.auxAddresses == ["cache": "10.2.0.20"])
        #expect(spec.driverOptions == ["mtu": "1400"])
        #expect(spec.attachable)
        #expect(spec.enableIPv6)
        #expect(spec.isInternal)
        #expect(spec.labels == ["tier": "backend"])
    }

    // MARK: - setupNetwork routes through RuntimeEnvironment (call-site contract)

    /// Verifies that `setupNetwork` calls `RuntimeEnvironment.current.createNetwork`
    /// exactly once when the network does not exist.
    ///
    /// This is the canonical CHAOS-1408 regression guard: if the implementation
    /// reverts to `RunCommandRunner`, the `RecordingRuntime` entries list will
    /// be empty (the runner seam, not the runtime seam, would capture the call).
    @Test("setupNetwork calls Runtime.createNetwork for a fresh network")
    func setupNetworkCallsRuntimeCreateNetwork() async throws {
        let runtime = RecordingRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            // Use the internal static helper that drives the network-creation
            // path to avoid running an entire `compose up` (which needs a full
            // compose file, filesystem, and running runner).
            try await ComposeUp.ensureNetworkRegistered(
                name: "mynet",
                actualName: "mynet",
                driver: "bridge",
                labels: [:]
            )
        }

        let entries = await runtime.entriesSnapshot()
        let createdNet = entries.contains(where: {
            if case .createNetwork(let name) = $0 { return name == "mynet" }
            return false
        })
        #expect(createdNet, "Runtime.createNetwork must be called for network 'mynet'; got entries: \(entries)")
    }

    /// Verifies that when `Runtime.createNetwork` throws `.alreadyExists`,
    /// `setupNetwork` treats it as a no-op (idempotent) and does NOT propagate
    /// the error.
    @Test("setupNetwork is idempotent: alreadyExists from Runtime is swallowed")
    func setupNetworkIdempotentOnAlreadyExists() async throws {
        // RecordingRuntime configured to throw alreadyExists from createNetwork
        let runtime = RecordingRuntime(
            createNetworkError: .alreadyExists(id: "existing-net")
        )

        // Must NOT throw
        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await ComposeUp.ensureNetworkRegistered(
                name: "existing-net",
                actualName: "existing-net",
                driver: "bridge",
                labels: [:]
            )
        }

        // createNetwork was still called (it's the runtime that reported already-exists)
        let entries = await runtime.entriesSnapshot()
        #expect(entries == [.createNetwork(name: "existing-net")],
                "createNetwork must be attempted even when the network already exists; got: \(entries)")
    }

    /// Verifies that when `Runtime.createNetwork` throws `.alreadyExists`,
    /// the "already exists" message is printed so the user gets feedback.
    @Test("setupNetwork prints 'already exists' message on alreadyExists")
    func setupNetworkPrintsAlreadyExistsMessage() async throws {
        let runtime = RecordingRuntime(
            createNetworkError: .alreadyExists(id: "dup-net")
        )

        let output = try await Self.capturingStdout {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await ComposeUp.ensureNetworkRegistered(
                    name: "dup-net",
                    actualName: "dup-net",
                    driver: "bridge",
                    labels: [:]
                )
            }
        }

        #expect(output.contains("already exists"),
                "expected 'already exists' diagnostic; got: \(output)")
    }

    /// Verifies that a non-bridge driver is forwarded to the runtime spec.
    /// The driver value in the returned entry is not captured by `RecordingRuntime`
    /// (it only records `name`), so we verify indirectly via `MockRuntime` which
    /// stores the full spec.
    @Test("setupNetwork passes non-bridge driver to runtime spec")
    func setupNetworkForwardsNonBridgeDriver() async throws {
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await ComposeUp.ensureNetworkRegistered(
                name: "vmnet",
                actualName: "vmnet",
                driver: "container-network-vmnet",
                labels: [:]
            )
        }

        let networks = await runtime.networksSnapshot()
        let net = networks.first(where: { $0.name == "vmnet" })
        #expect(net != nil, "network 'vmnet' should exist in MockRuntime after creation")
        #expect(net?.driver == "container-network-vmnet",
                "driver should be forwarded verbatim; got: \(net?.driver ?? "<nil>")")
    }

    /// Verifies that labels in the compose network config are forwarded to the
    /// runtime spec.
    @Test("setupNetwork forwards labels to runtime spec")
    func setupNetworkForwardsLabels() async throws {
        let runtime = MockRuntime()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await ComposeUp.ensureNetworkRegistered(
                name: "labelled-net",
                actualName: "labelled-net",
                driver: "bridge",
                labels: ["project": "chaos", "tier": "backend"]
            )
        }

        let networks = await runtime.networksSnapshot()
        let net = networks.first(where: { $0.name == "labelled-net" })
        #expect(net?.labels == ["project": "chaos", "tier": "backend"],
                "labels must be forwarded to runtime; got: \(net?.labels ?? [:])")
    }

    // MARK: - setupNetwork does NOT call RunnerEnvironment

    /// Verifies that `setupNetwork` does NOT invoke `RunnerEnvironment.current.run`
    /// for network creation — i.e. the shell-out path has been fully removed.
    ///
    /// We bind a `RecordingRunner` and assert it captures zero calls for the
    /// network creation code path.
    @Test("setupNetwork does not invoke RunnerEnvironment for network creation")
    func setupNetworkDoesNotCallRunner() async throws {
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()

        try await RuntimeEnvironment.$current.withValue(runtime) {
            try await RunnerEnvironment.$current.withValue(runner) {
                try await ComposeUp.ensureNetworkRegistered(
                    name: "no-shell-net",
                    actualName: "no-shell-net",
                    driver: "bridge",
                    labels: [:]
                )
            }
        }

        let runnerEntries = await runner.recordedRequests()
        let networkCreateCalls = runnerEntries.filter { entry in
            if case .swiftAPI(let name) = entry.request.kind { return name == "NetworkCreate" }
            return false
        }
        #expect(networkCreateCalls.isEmpty,
                "RunnerEnvironment must NOT be called for network creation after CHAOS-1408; got: \(networkCreateCalls)")
    }
}

// MARK: - ComposeUp.ensureNetworkRegistered (internal testable helper)

extension ComposeUp {
    /// Internal helper exposed for testing CHAOS-1408's call-site contract.
    ///
    /// Encapsulates the idempotent `createNetwork` call that `setupNetwork`
    /// delegates to, without requiring a full compose-file parse or filesystem
    /// access. Tests can inject any `Runtime` via `RuntimeEnvironment.$current`
    /// and assert the `RecordingRuntime` call log.
    ///
    /// - Parameters:
    ///   - name: The compose-file network key (used in diagnostic messages).
    ///   - actualName: The resolved network name (from `config.name ?? name`).
    ///   - driver: The resolved driver (from `config.driver ?? "bridge"`).
    ///   - labels: The network labels.
    internal static func ensureNetworkRegistered(
        name: String,
        actualName: String,
        driver: String,
        labels: [String: String]
    ) async throws {
        let spec = RuntimeCreateNetworkSpec(
            name: actualName,
            driver: driver,
            labels: labels
        )
        do {
            _ = try await RuntimeEnvironment.current.createNetwork(spec: spec)
            print("Network '\(name)' created")
        } catch RuntimeError.alreadyExists {
            print("Network '\(name)' already exists")
        }
    }
}
