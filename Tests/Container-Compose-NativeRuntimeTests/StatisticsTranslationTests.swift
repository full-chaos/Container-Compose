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

#if os(macOS)

import Foundation
import Testing
import Containerization
@testable import ContainerComposeCore

/// Pure-function tests for `AppleContainerizationRuntime.translate(_:id:)` —
/// the `ContainerStatistics` → `RuntimeStatistics` mapping introduced in
/// CHAOS-1424 PR4 to close CHAOS-1362 / Leak #7. Field correspondence is
/// verified against
/// `.build/checkouts/containerization/Sources/Containerization/ContainerStatistics.swift`.
///
/// These tests live in the native-runtime target because they `import
/// Containerization` to construct `ContainerStatistics` values directly. The
/// translator itself is `internal static` so no live `LinuxContainer` is
/// required — every field can be exercised with a hand-built input.
@Suite("Statistics translation (CHAOS-1362 / CHAOS-1424 PR4)")
struct StatisticsTranslationTests {

    @Test("all-nil sub-fields map to all-nil RuntimeStatistics fields")
    func allNilSubFields() throws {
        let raw = ContainerStatistics(id: "demo-svc-1")
        let translated = AppleContainerizationRuntime.translate(raw, id: "demo-svc-1")

        #expect(translated.id == "demo-svc-1")
        #expect(translated.cpuUsageUsec == nil)
        #expect(translated.memoryUsageBytes == nil)
        #expect(translated.memoryLimitBytes == nil)
        #expect(translated.oomKillCount == nil)
        #expect(translated.networks.isEmpty)
    }

    @Test("cpu.usageUsec maps to cpuUsageUsec")
    func cpuMapping() throws {
        let raw = ContainerStatistics(
            id: "demo",
            cpu: .init(
                usageUsec: 12_345,
                userUsec: 8_000,
                systemUsec: 4_345,
                throttlingPeriods: 0,
                throttledPeriods: 0,
                throttledTimeUsec: 0
            )
        )
        let translated = AppleContainerizationRuntime.translate(raw, id: "demo")

        #expect(translated.cpuUsageUsec == 12_345)
    }

    @Test("memory.usageBytes / .limitBytes map to RuntimeStatistics memory fields")
    func memoryMapping() throws {
        let raw = ContainerStatistics(
            id: "demo",
            memory: .init(
                usageBytes: 256 * 1024 * 1024,
                limitBytes: 512 * 1024 * 1024,
                swapUsageBytes: 0,
                swapLimitBytes: 0,
                cacheBytes: 0,
                kernelStackBytes: 0,
                slabBytes: 0,
                pageFaults: 0,
                majorPageFaults: 0,
                inactiveFile: 0,
                anon: 0
            )
        )
        let translated = AppleContainerizationRuntime.translate(raw, id: "demo")

        #expect(translated.memoryUsageBytes == 256 * 1024 * 1024)
        #expect(translated.memoryLimitBytes == 512 * 1024 * 1024)
    }

    @Test("memoryEvents.oomKill maps to oomKillCount")
    func memoryEventsMapping() throws {
        let raw = ContainerStatistics(
            id: "demo",
            memoryEvents: .init(low: 0, high: 0, max: 1, oom: 2, oomKill: 3)
        )
        let translated = AppleContainerizationRuntime.translate(raw, id: "demo")

        #expect(translated.oomKillCount == 3)
    }

    @Test("networks per-interface counters preserved (no rollup)")
    func networksMapping() throws {
        let raw = ContainerStatistics(
            id: "demo",
            networks: [
                .init(
                    interface: "eth0",
                    receivedPackets: 100,
                    transmittedPackets: 50,
                    receivedBytes: 100_000,
                    transmittedBytes: 50_000,
                    receivedErrors: 0,
                    transmittedErrors: 0
                ),
                .init(
                    interface: "lo",
                    receivedPackets: 10,
                    transmittedPackets: 10,
                    receivedBytes: 1_000,
                    transmittedBytes: 1_000,
                    receivedErrors: 0,
                    transmittedErrors: 0
                ),
            ]
        )
        let translated = AppleContainerizationRuntime.translate(raw, id: "demo")

        #expect(translated.networks.count == 2)
        let eth0 = translated.networks.first(where: { $0.interface == "eth0" })
        #expect(eth0?.receivedBytes == 100_000)
        #expect(eth0?.transmittedBytes == 50_000)
        let lo = translated.networks.first(where: { $0.interface == "lo" })
        #expect(lo?.receivedBytes == 1_000)
    }

    @Test("nil networks array translates to empty RuntimeStatistics.networks")
    func networksNilToEmpty() throws {
        let raw = ContainerStatistics(id: "demo", networks: nil)
        let translated = AppleContainerizationRuntime.translate(raw, id: "demo")

        #expect(translated.networks.isEmpty)
    }

    @Test("all fields populated maps every supported metric")
    func fullyPopulated() throws {
        let raw = ContainerStatistics(
            id: "demo",
            memory: .init(
                usageBytes: 1_000,
                limitBytes: 2_000,
                swapUsageBytes: 0,
                swapLimitBytes: 0,
                cacheBytes: 0,
                kernelStackBytes: 0,
                slabBytes: 0,
                pageFaults: 0,
                majorPageFaults: 0,
                inactiveFile: 0,
                anon: 0
            ),
            cpu: .init(
                usageUsec: 999,
                userUsec: 500,
                systemUsec: 499,
                throttlingPeriods: 0,
                throttledPeriods: 0,
                throttledTimeUsec: 0
            ),
            networks: [
                .init(
                    interface: "eth0",
                    receivedPackets: 0,
                    transmittedPackets: 0,
                    receivedBytes: 7,
                    transmittedBytes: 11,
                    receivedErrors: 0,
                    transmittedErrors: 0
                ),
            ],
            memoryEvents: .init(low: 0, high: 0, max: 0, oom: 0, oomKill: 42)
        )
        let translated = AppleContainerizationRuntime.translate(raw, id: "demo")

        #expect(translated.id == "demo")
        #expect(translated.cpuUsageUsec == 999)
        #expect(translated.memoryUsageBytes == 1_000)
        #expect(translated.memoryLimitBytes == 2_000)
        #expect(translated.oomKillCount == 42)
        #expect(translated.networks.count == 1)
        #expect(translated.networks[0].interface == "eth0")
        #expect(translated.networks[0].receivedBytes == 7)
        #expect(translated.networks[0].transmittedBytes == 11)
    }

    @Test("id is preserved verbatim regardless of raw stats id")
    func idIsArgument() throws {
        // Translator uses the explicit `id:` argument, not `raw.id` — guards
        // against silent-mismatch bugs if upstream ever populated stats with a
        // different id (e.g. canonicalized).
        let raw = ContainerStatistics(id: "different-id")
        let translated = AppleContainerizationRuntime.translate(raw, id: "demo")

        #expect(translated.id == "demo")
    }
}

#endif
