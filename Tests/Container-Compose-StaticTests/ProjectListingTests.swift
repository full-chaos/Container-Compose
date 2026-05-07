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

@Suite("ProjectListing helper (CHAOS-1440)")
struct ProjectListingTests {

    // MARK: - parseServiceName

    @Test("parseServiceName: bare prefix maps to service name")
    func parseServiceName_barePrefix_returnsService() throws {
        #expect(ProjectListing.parseServiceName(containerId: "myproj-redis", projectName: "myproj") == "redis")
    }

    @Test("parseServiceName: trailing single-digit replica suffix is stripped")
    func parseServiceName_singleDigitReplicaStripped() throws {
        #expect(ProjectListing.parseServiceName(containerId: "myproj-redis-2", projectName: "myproj") == "redis")
    }

    @Test("parseServiceName: trailing multi-digit replica suffix is stripped")
    func parseServiceName_multiDigitReplicaStripped() throws {
        #expect(ProjectListing.parseServiceName(containerId: "myproj-redis-23", projectName: "myproj") == "redis")
    }

    @Test("parseServiceName: non-numeric trailing token is part of the service name")
    func parseServiceName_nonNumericTailKept() throws {
        // `cluster` is not an integer, so it is NOT a replica suffix.
        #expect(ProjectListing.parseServiceName(containerId: "myproj-redis-cluster", projectName: "myproj") == "redis-cluster")
    }

    @Test("parseServiceName: container id without project prefix yields nil")
    func parseServiceName_wrongProjectReturnsNil() throws {
        #expect(ProjectListing.parseServiceName(containerId: "otherproj-redis", projectName: "myproj") == nil)
    }

    @Test("parseServiceName: id equal to prefix yields nil")
    func parseServiceName_emptyAfterPrefixReturnsNil() throws {
        #expect(ProjectListing.parseServiceName(containerId: "myproj-", projectName: "myproj") == nil)
    }

    // MARK: - list(...)

    @Test("list: filters to project prefix, drops other-project containers")
    func list_filtersToProjectPrefix() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            container(id: "myproj-redis-1", status: .running),
            container(id: "myproj-redis-2", status: .running),
            container(id: "myproj-web-1", status: .running),
            container(id: "otherproj-redis-1", status: .running),
        ])

        let entries = try await ProjectListing.list(
            runtime: runtime,
            projectName: "myproj"
        )

        // Only myproj-* containers, sorted by (serviceName, id).
        #expect(entries.map(\.container.id) == ["myproj-redis-1", "myproj-redis-2", "myproj-web-1"])
        #expect(entries.map(\.serviceName) == ["redis", "redis", "web"])
    }

    @Test("list: drops stopped containers when includeStopped is false")
    func list_dropsStoppedByDefault() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            container(id: "myproj-redis-1", status: .running),
            container(id: "myproj-redis-2", status: .stopped),
            container(id: "myproj-web-1", status: .exited),
        ])

        let entries = try await ProjectListing.list(
            runtime: runtime,
            projectName: "myproj"
        )
        #expect(entries.map(\.container.id) == ["myproj-redis-1"])
    }

    @Test("list: includeStopped=true keeps non-running containers")
    func list_includeStoppedKeepsAll() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            container(id: "myproj-redis-1", status: .running),
            container(id: "myproj-redis-2", status: .stopped),
            container(id: "myproj-web-1", status: .exited),
        ])

        let entries = try await ProjectListing.list(
            runtime: runtime,
            projectName: "myproj",
            includeStopped: true
        )
        #expect(entries.map(\.container.id) == ["myproj-redis-1", "myproj-redis-2", "myproj-web-1"])
    }

    @Test("list: serviceFilter narrows result set to named services")
    func list_serviceFilterNarrows() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            container(id: "myproj-redis-1", status: .running),
            container(id: "myproj-redis-2", status: .running),
            container(id: "myproj-web-1", status: .running),
        ])

        let entries = try await ProjectListing.list(
            runtime: runtime,
            projectName: "myproj",
            serviceFilter: ["redis"]
        )
        #expect(entries.map(\.container.id) == ["myproj-redis-1", "myproj-redis-2"])
        #expect(entries.allSatisfy { $0.serviceName == "redis" })
    }

    @Test("list: nil serviceFilter is treated as no filter")
    func list_nilFilterReturnsAll() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            container(id: "myproj-redis-1", status: .running),
            container(id: "myproj-web-1", status: .running),
        ])

        let entries = try await ProjectListing.list(
            runtime: runtime,
            projectName: "myproj",
            serviceFilter: nil
        )
        #expect(entries.count == 2)
    }

    @Test("list: empty serviceFilter is treated as no filter")
    func list_emptyFilterReturnsAll() async throws {
        let runtime = RecordingRuntime(stubbedContainers: [
            container(id: "myproj-redis-1", status: .running),
            container(id: "myproj-web-1", status: .running),
        ])

        let entries = try await ProjectListing.list(
            runtime: runtime,
            projectName: "myproj",
            serviceFilter: []
        )
        #expect(entries.count == 2)
    }

    @Test("list: stable sort by (serviceName, container.id)")
    func list_stableSort() async throws {
        // Stub returns in non-sorted order — verify the sort.
        let runtime = RecordingRuntime(stubbedContainers: [
            container(id: "myproj-web-1", status: .running),
            container(id: "myproj-redis-2", status: .running),
            container(id: "myproj-redis-1", status: .running),
        ])

        let entries = try await ProjectListing.list(
            runtime: runtime,
            projectName: "myproj"
        )
        #expect(entries.map(\.container.id) == ["myproj-redis-1", "myproj-redis-2", "myproj-web-1"])
    }

    @Test("list: containers without project prefix are ignored")
    func list_skipsNonPrefixedContainers() async throws {
        // RecordingRuntime applies the namePrefix filter via
        // RuntimeListFilters.matches, so we shouldn't see "rogue" — but we
        // also document that ProjectListing skips ids it can't decode.
        let runtime = RecordingRuntime(stubbedContainers: [
            container(id: "myproj-redis-1", status: .running),
            container(id: "rogue", status: .running),
        ])

        let entries = try await ProjectListing.list(
            runtime: runtime,
            projectName: "myproj"
        )
        #expect(entries.map(\.container.id) == ["myproj-redis-1"])
    }

    // MARK: - helpers

    private func container(
        id: String,
        status: RuntimeContainerStatus,
        publishedPorts: [RuntimePublishedPort] = []
    ) -> RuntimeContainer {
        RuntimeContainer(
            id: id,
            imageReference: "image:latest",
            status: status,
            publishedPorts: publishedPorts
        )
    }
}
