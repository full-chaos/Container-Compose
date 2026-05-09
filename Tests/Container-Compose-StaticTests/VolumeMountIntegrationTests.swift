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

import Testing
import Foundation
import Yams
import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
@testable import ContainerComposeCore
import TestHelpers

// MARK: - Phase 2 Task 2.6: Volume mount end-to-end integration tests
//
// These tests exercise volume-related behavior through the full `compose up` /
// `compose down` pipeline with a `RecordingRuntime` (and in some cases a
// `MockRuntime`) to capture volume CRUD calls without requiring a real backend.
//
// Coverage:
//  • Multiple volumes in a single service (named + bind mix) — createVolume
//    calls are made for each declared named volume in the top-level `volumes:`
//    section.
//  • Named volume lifecycle: create → verify registered → down -v removes.
//  • Volume inheritance via extends — child service inherits parent's volumes
//    after resolution; those volumes are still registered on up.
//  • Volume specified with complex nested paths in compose YAML — the path
//    survives round-trip through YAML decode and reaches up intact.
//  • compose down without -v does NOT remove volumes.
//  • external: true volumes are NOT created by `compose up` (they must
//    pre-exist; we verify no createVolume call is made for them).
//
// Design note on configVolume's private surface:
//   `ComposeUp.configVolume` is `private mutating func`; it cannot be called
//   directly from tests. Integration tests go through `compose up` parsed
//   commands (with `--cwd` pointing to a temp directory containing a YAML
//   file) and then inspect what the RecordingRuntime captured.  This is the
//   same pattern used by `ComposeDownVolumeRemovalTests`.

@Suite("Volume Mount Integration", .serialized)
struct VolumeMountIntegrationTests {

    // MARK: - Local test helpers

    /// Wraps `RecordingContainerClientProvider` and overrides `get(id:)` to
    /// return a `.running` snapshot so `waitUntilServiceIsRunning` resolves
    /// immediately instead of burning the 30-second timeout.
    private actor RunningContainerProvider: ContainerClientProvider {
        private let inner: RecordingContainerClientProvider
        init(_ inner: RecordingContainerClientProvider) { self.inner = inner }

        func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> ContainerSnapshot {
            try await inner.create(id: id, configuration: configuration)
        }
        func list(filters: ContainerListFilters) async throws -> [ContainerSnapshot] {
            try await inner.list(filters: filters)
        }
        func get(id: String) async throws -> ContainerSnapshot {
            // Return a minimal running snapshot so waitUntilServiceIsRunning
            // exits on the first poll rather than timing out after 30 s.
            //
            // CHAOS-1494: when `id` matches the embedded DNS sidecar naming
            // convention, attach the snapshot to the project's implicit
            // default network and use the sidecar image so
            // `EmbeddedDNSSidecar.adoptIfMatching` accepts it. Without this,
            // CHAOS-1494's implicit-network synthesis (which fires for any
            // compose file with no top-level `networks:`) would block in
            // `waitForRunningSidecar` waiting for an unrelated network
            // attachment that this fake never provides.
            let suffix = "-compose-dns"
            if id.hasSuffix(suffix), id.count > suffix.count {
                let projectName = String(id.dropLast(suffix.count))
                let implicitNetwork = "\(projectName)-default"
                let sidecarProcess = ProcessConfiguration(
                    executable: "/coredns",
                    arguments: ["-conf", "/etc/coredns/Corefile"],
                    environment: [String](),
                    workingDirectory: "/"
                )
                let sidecarConfig = ContainerConfiguration(
                    id: id,
                    image: ImageDescription(
                        reference: EmbeddedDNSSidecar.image,
                        descriptor: Descriptor(
                            mediaType: "application/vnd.oci.image.manifest.v1+json",
                            digest: "sha256:\(String(repeating: "0", count: 64))",
                            size: 0
                        )
                    ),
                    process: sidecarProcess
                )
                let sidecarAttachment = ContainerResource.Attachment(
                    network: implicitNetwork,
                    hostname: id,
                    ipv4Address: try CIDRv4("10.0.0.5/24"),
                    ipv4Gateway: try IPv4Address("10.0.0.1"),
                    ipv6Address: nil,
                    macAddress: nil
                )
                return ContainerSnapshot(
                    configuration: sidecarConfig,
                    status: .running,
                    networks: [sidecarAttachment]
                )
            }
            let process = ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [String](), workingDirectory: "/")
            let config = ContainerConfiguration(
                id: id,
                image: ImageDescription(reference: "stub", descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:\(String(repeating: "0", count: 64))", size: 0)),
                process: process
            )
            return ContainerSnapshot(configuration: config, status: .running, networks: [])
        }
        func stop(id: String, opts: ContainerStopOptions) async throws {
            try await inner.stop(id: id, opts: opts)
        }
        func delete(id: String, force: Bool) async throws {
            try await inner.delete(id: id, force: force)
        }
        func logs(id: String) async throws -> [FileHandle] {
            try await inner.logs(id: id)
        }
        func logs(id: String, options: ContainerLogOptions) async throws -> [FileHandle] {
            try await inner.logs(id: id, options: options)
        }
        func networkGet(id: String) async throws -> NetworkState {
            try await inner.networkGet(id: id)
        }
        func imageList() async throws -> [ClientImage] {
            try await inner.imageList()
        }
        func events() async throws -> [ContainerEvent] {
            try await inner.events()
        }
        func stats(id: String) async throws -> ContainerStats {
            try await inner.stats(id: id)
        }
        func kill(id: String, signal: Int32) async throws {
            try await inner.kill(id: id, signal: signal)
        }
        func start(id: String) async throws {
            try await inner.start(id: id)
        }
        func entriesSnapshot() async -> [RecordingContainerClientProvider.Entry] {
            await inner.entriesSnapshot()
        }
    }

    // MARK: - Helpers

    private static func makeProject(yaml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "compose-vol-integ-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try yaml.write(to: directory.appending(path: "compose.yml"), atomically: true, encoding: .utf8)
        return directory
    }

    // MARK: - Named volume lifecycle: create → use → cleanup

    @Test("Named volume is registered on compose up")
    func namedVolumeRegisteredOnUp() async throws {
        let projectName = "cc-test-vol-up-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - pgdata:/var/lib/postgresql/data
            volumes:
              pgdata:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(RunningContainerProvider(containerProvider)) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        // compose up must call listVolumes (to check for existing) + createVolume.
        let calledListVolumes = entries.contains(where: { if case .listVolumes = $0 { return true }; return false })
        let calledCreateVolume = entries.contains(where: { if case .createVolume(let name) = $0 { return name == "pgdata" }; return false })
        #expect(calledListVolumes, "compose up must call listVolumes before creating; got \(entries)")
        #expect(calledCreateVolume, "compose up must call createVolume(pgdata); got \(entries)")
    }

    @Test("Named volume removed on compose down -v")
    func namedVolumeRemovedOnDownWithFlag() async throws {
        let projectName = "cc-test-vol-down-v-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - appdata:/app/data
            volumes:
              appdata:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [RuntimeVolume(name: "appdata")])
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "-v"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries.contains(.removeVolume(name: "appdata")),
                "compose down -v must call removeVolume(appdata); got \(entries)")
    }

    @Test("Named volume NOT removed on compose down without -v")
    func namedVolumeNotRemovedOnDownWithoutFlag() async throws {
        let projectName = "cc-test-vol-down-noflag-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - appdata:/app/data
            volumes:
              appdata:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [RuntimeVolume(name: "appdata")])
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        let touchedVolumes = entries.contains(where: {
            if case .removeVolume = $0 { return true }
            return false
        })
        #expect(!touchedVolumes, "compose down without -v must not call removeVolume; got \(entries)")
    }

    // MARK: - Multiple volumes in a single service

    @Test("Multiple named volumes in a single service are all registered on up")
    func multipleNamedVolumesRegisteredOnUp() async throws {
        let projectName = "cc-test-multi-vols-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              db:
                image: postgres:14
                volumes:
                  - db_data:/var/lib/postgresql/data
                  - db_logs:/var/log/postgresql
                  - db_run:/var/run/postgresql
            volumes:
              db_data:
              db_logs:
              db_run:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(RunningContainerProvider(containerProvider)) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        for volumeName in ["db_data", "db_logs", "db_run"] {
            let created = entries.contains(where: {
                if case .createVolume(let name) = $0 { return name == volumeName }
                return false
            })
            #expect(created, "expected createVolume(\(volumeName)); got \(entries)")
        }
    }

    @Test("Multiple named volumes removed on compose down -v")
    func multipleNamedVolumesRemovedOnDownWithFlag() async throws {
        let projectName = "cc-test-multi-down-v-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              db:
                image: postgres:14
                volumes:
                  - db_data:/var/lib/postgresql/data
                  - db_logs:/var/log/postgresql
            volumes:
              db_data:
              db_logs:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [
            RuntimeVolume(name: "db_data"),
            RuntimeVolume(name: "db_logs"),
        ])
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "-v"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries.contains(.removeVolume(name: "db_data")), "expected removeVolume(db_data); got \(entries)")
        #expect(entries.contains(.removeVolume(name: "db_logs")), "expected removeVolume(db_logs); got \(entries)")
    }

    // MARK: - Bind mount presence in top-level volumes section

    @Test("Bind mounts in service volumes do not appear as named volume createVolume calls")
    func bindMountsDoNotTriggerCreateVolume() async throws {
        let projectName = "cc-test-bind-vol-\(UUID().uuidString.lowercased())"
        // Create a real bind-mount source directory so configVolume doesn't skip it.
        let bindSourceDir = FileManager.default.temporaryDirectory
            .appending(path: "bind-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bindSourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bindSourceDir) }

        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - \(bindSourceDir.path):/app/config
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(RunningContainerProvider(containerProvider)) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        let createdVolumes = entries.compactMap { entry -> String? in
            if case .createVolume(let name) = entry { return name }
            return nil
        }
        #expect(createdVolumes.isEmpty,
                "bind mounts must not call createVolume; got created volumes: \(createdVolumes)")
    }

    // MARK: - Volume inheritance via extends

    @Test("Child service inheriting volumes from parent via extends results in those volumes being registered on up")
    func volumeInheritanceViaExtendsRegistersVolumes() async throws {
        let projectName = "cc-test-extends-vol-\(UUID().uuidString.lowercased())"
        // child_db extends base_db and inherits its volumes.
        // top-level volumes section declares db_data so compose up will create it.
        let directory = try Self.makeProject(yaml: """
            services:
              base_db:
                image: postgres:14
                volumes:
                  - db_data:/var/lib/postgresql/data
              child_db:
                extends:
                  service: base_db
                environment:
                  POSTGRES_DB: myapp
            volumes:
              db_data:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(RunningContainerProvider(containerProvider)) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        // db_data should be created (it appears in the top-level volumes section
        // and is referenced by the resolved child_db service).
        let createdDbData = entries.contains(where: {
            if case .createVolume(let name) = $0 { return name == "db_data" }
            return false
        })
        #expect(createdDbData, "db_data volume must be created for child service inheriting from base; got \(entries)")
    }

    @Test("Volume inheritance: down -v on project with extended service removes inherited volumes")
    func volumeInheritanceDownRemovesVolumes() async throws {
        let projectName = "cc-test-ext-down-v-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              base_worker:
                image: worker:latest
                volumes:
                  - worker_state:/app/state
              prod_worker:
                extends:
                  service: base_worker
                environment:
                  ENV: production
            volumes:
              worker_state:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [RuntimeVolume(name: "worker_state")])
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "-v"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        #expect(entries.contains(.removeVolume(name: "worker_state")),
                "worker_state must be removed on down -v even when declared through an extended service; got \(entries)")
    }

    // MARK: - External volumes: no createVolume call

    @Test("External volumes are NOT created by compose up")
    func externalVolumeNotCreatedByUp() async throws {
        let projectName = "cc-test-ext-skip-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - shared_data:/data
            volumes:
              shared_data:
                external: true
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Stub the external volume as "already existing" in the registry so compose
        // up doesn't error on externalVolumeNotFound.
        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [RuntimeVolume(name: "shared_data")])
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(RunningContainerProvider(containerProvider)) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        let createdExternal = entries.contains(where: {
            if case .createVolume(let name) = $0 { return name == "shared_data" }
            return false
        })
        #expect(!createdExternal,
                "external volume 'shared_data' must NOT be created by compose up; got \(entries)")
    }

    @Test("External volumes are NOT removed by compose down -v")
    func externalVolumeNotRemovedByDownWithFlag() async throws {
        let projectName = "cc-test-ext-noremove-\(UUID().uuidString.lowercased())"
        let directory = try Self.makeProject(yaml: """
            services:
              api:
                image: alpine
                volumes:
                  - shared_data:/data
                  - local_data:/local
            volumes:
              shared_data:
                external: true
              local_data:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime(stubbedVolumes: [
            RuntimeVolume(name: "shared_data"),
            RuntimeVolume(name: "local_data"),
        ])
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(containerProvider) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeDown.parse(["--cwd", directory.path, "-p", projectName, "-v"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        let removedExternal = entries.contains(where: {
            if case .removeVolume(let name) = $0 { return name == "shared_data" }
            return false
        })
        let removedLocal = entries.contains(where: {
            if case .removeVolume(let name) = $0 { return name == "local_data" }
            return false
        })
        #expect(!removedExternal,
                "external volume 'shared_data' must NOT be removed; got \(entries)")
        #expect(removedLocal,
                "local volume 'local_data' must be removed; got \(entries)")
    }

    // MARK: - Complex nested paths in volume specs

    @Test("Named volume with a deeply nested container path decodes and registers correctly")
    func deepNestedContainerPathNamedVolume() async throws {
        let projectName = "cc-test-deep-path-\(UUID().uuidString.lowercased())"
        // A long container destination path should survive YAML decode and reach
        // createVolume without being truncated or mangled.
        let directory = try Self.makeProject(yaml: """
            services:
              app:
                image: myapp:latest
                volumes:
                  - app_cache:/usr/local/lib/python3.12/site-packages/cache
            volumes:
              app_cache:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(RunningContainerProvider(containerProvider)) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()
        let created = entries.contains(where: {
            if case .createVolume(let name) = $0 { return name == "app_cache" }
            return false
        })
        #expect(created, "app_cache must be created regardless of destination path depth; got \(entries)")
    }

    @Test("Service volumes with mixed bind and named mounts: only named volumes get createVolume")
    func mixedBindAndNamedVolumesOnlyNamedGetCreated() async throws {
        let projectName = "cc-test-mixed-vols-\(UUID().uuidString.lowercased())"
        // Create a real bind-mount source directory.
        let bindDir = FileManager.default.temporaryDirectory
            .appending(path: "bind-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bindDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bindDir) }

        let directory = try Self.makeProject(yaml: """
            services:
              web:
                image: nginx:latest
                volumes:
                  - \(bindDir.path):/usr/share/nginx/html
                  - nginx_cache:/var/cache/nginx
            volumes:
              nginx_cache:
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerProvider = RecordingContainerClientProvider()
        let runtime = RecordingRuntime()
        let runner = RecordingRunner()
        try await ContainerClientEnvironment.$current.withValue(RunningContainerProvider(containerProvider)) {
            try await RuntimeEnvironment.$current.withValue(runtime) {
                try await RunnerEnvironment.$current.withValue(runner) {
                    var command = try ComposeUp.parse(["--cwd", directory.path, "-p", projectName, "-d"])
                    try await command.run()
                }
            }
        }

        let entries = await runtime.entriesSnapshot()

        // Only the named volume should appear in createVolume calls.
        let allCreated = entries.compactMap { entry -> String? in
            if case .createVolume(let name) = entry { return name }
            return nil
        }
        #expect(allCreated == ["nginx_cache"],
                "only nginx_cache should be created; got \(allCreated)")
    }

    // MARK: - Volume idempotency via ensureNamedVolumeRegistered

    @Test("Re-running up with existing named volume does not call createVolume again")
    func reRunUpWithExistingVolumeSkipsCreate() async throws {
        // Stub the volume as already in the registry — simulates a second `compose up`.
        let runtime = RecordingRuntime()

        let didCreate = try await RuntimeEnvironment.$current.withValue(runtime) {
            try await ComposeUp.ensureNamedVolumeRegistered(
                spec: RuntimeCreateVolumeSpec(name: "mydata"),
                existing: RuntimeVolume(name: "mydata")
            )
        }

        #expect(didCreate == false, "volume already exists — should skip create")
        let entries = await runtime.entriesSnapshot()
        let createCount = entries.filter {
            if case .createVolume = $0 { return true }
            return false
        }.count
        #expect(createCount == 0, "createVolume must not be called when volume already exists; got \(entries)")
    }

    @Test("First up creates the named volume when registry is empty")
    func firstUpCreatesNamedVolume() async throws {
        let runtime = RecordingRuntime()

        let didCreate = try await RuntimeEnvironment.$current.withValue(runtime) {
            try await ComposeUp.ensureNamedVolumeRegistered(
                spec: RuntimeCreateVolumeSpec(name: "newdata"),
                existing: nil
            )
        }

        #expect(didCreate == true, "first up with no existing volume should create")
        let entries = await runtime.entriesSnapshot()
        #expect(entries == [.createVolume(name: "newdata")])
    }

    // MARK: - Volumes across multi-service compose file (DockerComposeYamlFiles fixture)

    @Test("Wordpress compose fixture (dockerComposeYaml1) has two named volumes that decode correctly")
    func wordpressFixtureNamedVolumes() throws {
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: DockerComposeYamlFiles.dockerComposeYaml1)
        // Both wordpress_data and db_data are declared in the top-level volumes section.
        let volumeKeys: Set<String> = dc.volumes.map { Set($0.keys) } ?? []
        #expect(volumeKeys.contains("wordpress_data"))
        #expect(volumeKeys.contains("db_data"))

        // Both services reference these volumes.
        let wpVolumes = dc.services["wordpress"]??.volumes ?? []
        let dbVolumes = dc.services["db"]??.volumes ?? []
        #expect(wpVolumes.contains("wordpress_data:/var/www/html"))
        #expect(dbVolumes.contains("db_data:/var/lib/mysql"))
    }

    @Test("Webapp compose fixture (dockerComposeYaml2) has db-data named volume with hyphen")
    func webappFixtureHyphenatedVolume() throws {
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: DockerComposeYamlFiles.dockerComposeYaml2)
        let volumeKeys: Set<String> = dc.volumes.map { Set($0.keys) } ?? []
        #expect(volumeKeys.contains("db-data"))

        // VolumeMountParser should classify "db-data:/var/lib/postgresql/data" as a named volume.
        let result = try VolumeMountParser.parse("db-data:/var/lib/postgresql/data").get()
        #expect(result.kind == .namedVolume(name: "db-data"))
    }
}

