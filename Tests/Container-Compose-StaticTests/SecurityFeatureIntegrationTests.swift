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
import TestHelpers
import Testing
import Darwin
import Yams
@testable import ContainerComposeCore

/// Security feature integration tests (CHAOS-1407).
///
/// These tests verify two complementary pipelines:
///
/// 1. **YAML → Service decode → SecurityArgs.build() → argv**
///    Each security-related compose field must survive the YAML parse path and
///    appear in the `container run` argv produced by `SecurityArgs.build(_:)`.
///    Regressions in `Service.init(from:)` that silently drop a security field
///    will surface here.
///
/// 2. **YAML → Service decode → RuntimeCreateConfiguration**
///    Security fields added in CHAOS-1407 (`capabilities`, `securityOpt`,
///    `readOnly`, `user`, `groupAdd`, `privileged`) are now present on
///    `RuntimeCreateConfiguration` and are asserted to carry the decoded values
///    correctly.  Application by conformers is a Phase 2 concern; these tests
///    verify the spec propagation only.
///
/// # Architecture note — where security features live
///
/// Container-Compose's job is to **translate** compose fields.  Security
/// translation happens at two levels:
///
/// - `ComposeUp.SecurityArgs.build(_:)` produces `[String]` argv items for the
///   `container run` (bridge) path.  Apple/container unsupported flags
///   (`--privileged`, `--security-opt`, `--group-add`) are warn-and-skipped here.
///
/// - `RuntimeCreateConfiguration` carries the same security surface for the
///   native-API path.  Conformers that cannot apply a field ignore it; a
///   follow-up ticket wires them through.
///
/// # Remaining gaps (apple/container limitations, not CHAOS-1407)
///
/// The following fields are carried in `RuntimeCreateConfiguration` but
/// apple/container has no flag for them, so `SecurityArgs` warn-and-skips them:
/// - `security_opt` (`--security-opt` not accepted)
/// - `group_add`    (`--group-add` not accepted)
/// - `privileged`   (`--privileged` not accepted)
@Suite("Security feature integration tests — YAML → SecurityArgs.build() → argv", .serialized)
struct SecurityFeatureIntegrationTests {

    /// Reset the process-wide warn-once dedup set before each test so the
    /// `await captureStdout(...).contains("Note: ...")` assertions don't flake based
    /// on which sibling suite ran first. Peer suite `SecurityArgsTests` also
    /// exercises `service.privileged`, `service.security_opt`, and
    /// `service.group_add` via `SecurityArgs.build()`, which would otherwise
    /// consume the one-shot warning under serial execution. Mirrors the
    /// pattern established in `LifecycleArgsTests.init`.
    init() {
        resetUnsupportedRuntimeFieldWarningsForTesting()
    }

    // MARK: - Helpers

    /// Decode a `DockerCompose` from YAML and return the named service.
    private func decodeService(_ yaml: String, name: String = "app") throws -> (DockerCompose, Service) {
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dc.services[name] ?? nil else {
            throw TestError.missingService(name)
        }
        return (dc, service)
    }

    /// Build an `ArgsContext` from the given service and parent `DockerCompose`.
    private func makeContext(
        service: Service,
        dc: DockerCompose,
        projectName: String = "testproject",
        serviceName: String = "app"
    ) -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: serviceName,
            projectName: projectName,
            containerName: "\(projectName)-\(serviceName)",
            detach: false,
            environmentVariables: [:],
            dockerCompose: dc,
            composeFilename: nil
        )
    }

    /// Capture stdout produced by the body closure so warn-and-skip messages can
    /// be asserted separately from argv output.
    private func captureStdout(_ body: () async throws -> Void) async throws -> String {
        try await CapturedOutput.acquire()
        defer { CapturedOutput.releaseFireAndForget() }
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        guard original >= 0 else { throw TestError.dupFailed }
        let pipe = Pipe()
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            close(original)
            throw TestError.dupFailed
        }
        do {
            try await body()
            fflush(stdout)
            _ = dup2(original, STDOUT_FILENO)
            close(original)
            pipe.fileHandleForWriting.closeFile()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            fflush(stdout)
            _ = dup2(original, STDOUT_FILENO)
            close(original)
            pipe.fileHandleForWriting.closeFile()
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            throw error
        }
    }

    private enum TestError: Error {
        case missingService(String)
        case dupFailed
    }

    // MARK: - cap_add: YAML → argv propagation

    /// Parses a compose YAML with `cap_add` and asserts that each capability
    /// produces a `--cap-add <CAP>` pair in the argv.
    @Test("cap_add in YAML propagates to --cap-add argv pairs")
    func capAddYAMLToArgv() throws {
        let yaml = """
        services:
          app:
            image: nginx:alpine
            cap_add:
              - NET_ADMIN
              - SYS_TIME
        """
        let (dc, service) = try decodeService(yaml)
        #expect(service.cap_add == ["NET_ADMIN", "SYS_TIME"])

        let ctx = makeContext(service: service, dc: dc)
        let args = ComposeUp.SecurityArgs.build(ctx)

        let addPairs = zip(args, args.dropFirst())
            .filter { $0.0 == "--cap-add" }
            .map { $0.1 }
        #expect(Set(addPairs) == Set(["NET_ADMIN", "SYS_TIME"]))
    }

    /// Verifies that a single-item `cap_add` also propagates correctly and that
    /// no spurious flags are emitted.
    @Test("Single cap_add item propagates without spurious flags")
    func capAddSingleItem() throws {
        let yaml = """
        services:
          app:
            image: alpine
            cap_add:
              - NET_RAW
        """
        let (dc, service) = try decodeService(yaml)
        let ctx = makeContext(service: service, dc: dc)
        let args = ComposeUp.SecurityArgs.build(ctx)

        #expect(args.contains("--cap-add"))
        #expect(args.contains("NET_RAW"))
        #expect(!args.contains("--cap-drop"))
    }

    // MARK: - cap_drop: YAML → argv propagation

    /// Parses a compose YAML with `cap_drop` and asserts that each capability
    /// produces a `--cap-drop <CAP>` pair in the argv.
    @Test("cap_drop in YAML propagates to --cap-drop argv pairs")
    func capDropYAMLToArgv() throws {
        let yaml = """
        services:
          app:
            image: nginx:alpine
            cap_drop:
              - ALL
              - NET_RAW
        """
        let (dc, service) = try decodeService(yaml)
        #expect(service.cap_drop == ["ALL", "NET_RAW"])

        let ctx = makeContext(service: service, dc: dc)
        let args = ComposeUp.SecurityArgs.build(ctx)

        let dropPairs = zip(args, args.dropFirst())
            .filter { $0.0 == "--cap-drop" }
            .map { $0.1 }
        #expect(Set(dropPairs) == Set(["ALL", "NET_RAW"]))
    }

    // MARK: - cap_add + cap_drop combination

    /// Verifies that a service with both `cap_add` and `cap_drop` produces the
    /// correct interleaved argv without either clobbering the other.
    @Test("cap_add and cap_drop together produce independent argv pairs")
    func capAddAndDropCombination() throws {
        let yaml = """
        services:
          app:
            image: nginx:alpine
            cap_add:
              - NET_ADMIN
            cap_drop:
              - ALL
        """
        let (dc, service) = try decodeService(yaml)
        let ctx = makeContext(service: service, dc: dc)
        let args = ComposeUp.SecurityArgs.build(ctx)

        let addCount = args.filter { $0 == "--cap-add" }.count
        let dropCount = args.filter { $0 == "--cap-drop" }.count
        #expect(addCount == 1)
        #expect(dropCount == 1)
        #expect(args.contains("NET_ADMIN"))
        #expect(args.contains("ALL"))
    }

    // MARK: - read_only: YAML → argv propagation

    /// Parses a compose YAML with `read_only: true` and asserts that
    /// `--read-only` appears in the argv.
    @Test("read_only: true in YAML propagates to --read-only argv flag")
    func readOnlyYAMLToArgv() throws {
        let yaml = """
        services:
          app:
            image: alpine
            read_only: true
        """
        let (dc, service) = try decodeService(yaml)
        #expect(service.read_only == true)

        let ctx = makeContext(service: service, dc: dc)
        let args = ComposeUp.SecurityArgs.build(ctx)

        #expect(args.contains("--read-only"))
    }

    /// Verifies that `read_only: false` does NOT emit `--read-only`.
    @Test("read_only: false in YAML omits --read-only argv flag")
    func readOnlyFalseYAMLEmitsNoFlag() throws {
        let yaml = """
        services:
          app:
            image: alpine
            read_only: false
        """
        let (dc, service) = try decodeService(yaml)
        let ctx = makeContext(service: service, dc: dc)
        let args = ComposeUp.SecurityArgs.build(ctx)

        #expect(!args.contains("--read-only"))
    }

    // MARK: - user: YAML → argv propagation

    /// Parses a compose YAML with a `user` field and asserts that
    /// `--user <value>` appears in the argv.
    @Test("user field in YAML propagates to --user argv pair")
    func userFieldYAMLToArgv() throws {
        let yaml = """
        services:
          app:
            image: alpine
            user: "1001:1001"
        """
        let (dc, service) = try decodeService(yaml)
        #expect(service.user == "1001:1001")

        let ctx = makeContext(service: service, dc: dc)
        let args = ComposeUp.SecurityArgs.build(ctx)

        guard let userIdx = args.firstIndex(of: "--user") else {
            Issue.record("Expected --user flag in argv: \(args)")
            return
        }
        #expect(args[userIdx + 1] == "1001:1001")
    }

    /// Verifies that a user specified as a name (not UID) is also propagated.
    @Test("user field with symbolic name in YAML propagates correctly")
    func userFieldSymbolicName() throws {
        let yaml = """
        services:
          app:
            image: alpine
            user: nobody
        """
        let (dc, service) = try decodeService(yaml)
        let ctx = makeContext(service: service, dc: dc)
        let args = ComposeUp.SecurityArgs.build(ctx)

        guard let userIdx = args.firstIndex(of: "--user") else {
            Issue.record("Expected --user flag in argv: \(args)")
            return
        }
        #expect(args[userIdx + 1] == "nobody")
    }

    // MARK: - privileged: warn-and-skip (gap documentation)

    /// Parses a compose YAML with `privileged: true` and verifies that:
    /// 1. The field decodes correctly (compose accepts it).
    /// 2. `SecurityArgs.build()` does NOT emit `--privileged` (unsupported by
    ///    apple/container per Tier 0 R2 audit).
    /// 3. A warning message is printed instead.
    ///
    /// GAP: `RuntimeCreateConfiguration` carries no `privileged` field.
    /// The apple/container runtime has no equivalent flag.
    @Test("privileged: true in YAML decodes but SecurityArgs.build() emits no --privileged flag")
    func privilegedYAMLDecodesButNotEmitted() async throws {
        let yaml = """
        services:
          app:
            image: alpine
            privileged: true
        """
        let (dc, service) = try decodeService(yaml)
        #expect(service.privileged == true)

        var args: [String] = []
        let output = try await captureStdout {
            args = ComposeUp.SecurityArgs.build(makeContext(service: service, dc: dc))
        }

        #expect(!args.contains("--privileged"))
        #expect(output.contains("Note: 'privileged' is parsed but not supported by Apple container; ignored."))
    }

    // MARK: - security_opt: warn-and-skip (gap documentation)

    /// Parses a compose YAML with `security_opt` entries and verifies that:
    /// 1. The field decodes correctly.
    /// 2. `SecurityArgs.build()` does NOT emit `--security-opt` (unsupported
    ///    by apple/container per Tier 0 R2 audit).
    /// 3. A warning is printed.
    ///
    /// GAP: `RuntimeCreateConfiguration` carries no `security_opt` field.
    /// apple/container has no `--security-opt` flag.
    @Test("security_opt in YAML decodes but SecurityArgs.build() emits no --security-opt flag")
    func securityOptYAMLDecodesButNotEmitted() async throws {
        let yaml = """
        services:
          app:
            image: alpine
            security_opt:
              - seccomp:unconfined
              - no-new-privileges:true
        """
        let (dc, service) = try decodeService(yaml)
        #expect(service.security_opt == ["seccomp:unconfined", "no-new-privileges:true"])

        var args: [String] = []
        let output = try await captureStdout {
            args = ComposeUp.SecurityArgs.build(makeContext(service: service, dc: dc))
        }

        #expect(!args.contains("--security-opt"))
        #expect(!args.contains("seccomp:unconfined"))
        #expect(!args.contains("no-new-privileges:true"))
    }

    // MARK: - group_add: warn-and-skip (gap documentation)

    /// Parses a compose YAML with `group_add` entries and verifies that:
    /// 1. The field decodes correctly.
    /// 2. `SecurityArgs.build()` does NOT emit `--group-add` (unsupported
    ///    by apple/container per Tier 0 R2 audit).
    /// 3. A warning is printed.
    ///
    /// GAP: `RuntimeCreateConfiguration` carries no `group_add` field.
    /// apple/container has no `--group-add` flag.
    @Test("group_add in YAML decodes but SecurityArgs.build() emits no --group-add flag")
    func groupAddYAMLDecodesButNotEmitted() async throws {
        let yaml = """
        services:
          app:
            image: alpine
            group_add:
              - audio
              - video
        """
        let (dc, service) = try decodeService(yaml)
        #expect(service.group_add == ["audio", "video"])

        var args: [String] = []
        let output = try await captureStdout {
            args = ComposeUp.SecurityArgs.build(makeContext(service: service, dc: dc))
        }

        #expect(!args.contains("--group-add"))
        #expect(!args.contains("audio"))
        #expect(!args.contains("video"))
    }

    // MARK: - Combined security fields from a single YAML

    /// Parses a YAML that includes all supported security fields and verifies
    /// the complete argv shape as a regression guard.
    @Test("All supported security fields together produce correct combined argv")
    func allSupportedSecurityFieldsCombined() throws {
        let yaml = """
        services:
          hardened:
            image: nginx:alpine
            user: "2000"
            read_only: true
            cap_add:
              - NET_ADMIN
            cap_drop:
              - ALL
        """
        let (dc, service) = try decodeService(yaml, name: "hardened")
        #expect(service.user == "2000")
        #expect(service.read_only == true)
        #expect(service.cap_add == ["NET_ADMIN"])
        #expect(service.cap_drop == ["ALL"])

        let ctx = makeContext(service: service, dc: dc, serviceName: "hardened")
        let args = ComposeUp.SecurityArgs.build(ctx)

        #expect(args.contains("--user"))
        #expect(args.contains("2000"))
        #expect(args.contains("--read-only"))
        #expect(args.contains("--cap-add"))
        #expect(args.contains("NET_ADMIN"))
        #expect(args.contains("--cap-drop"))
        #expect(args.contains("ALL"))

        // Unsupported flags must not appear
        #expect(!args.contains("--privileged"))
        #expect(!args.contains("--security-opt"))
        #expect(!args.contains("--group-add"))
    }

    /// Verifies that none of the unsupported warn-and-skip fields produce argv
    /// output when all three are specified together in a single service.
    @Test("All warn-and-skip security fields together emit no unsupported argv")
    func allWarnAndSkipFieldsEmitNoArgv() async throws {
        let yaml = """
        services:
          risky:
            image: alpine
            privileged: true
            security_opt:
              - seccomp:unconfined
            group_add:
              - docker
        """
        let (dc, service) = try decodeService(yaml, name: "risky")
        let ctx = makeContext(service: service, dc: dc, serviceName: "risky")

        var args: [String] = []
        _ = try await captureStdout {
            args = ComposeUp.SecurityArgs.build(ctx)
        }

        #expect(!args.contains("--privileged"))
        #expect(!args.contains("--security-opt"))
        #expect(!args.contains("--group-add"))
        #expect(!args.contains("seccomp:unconfined"))
        #expect(!args.contains("docker"))
    }

    // MARK: - Edge cases: empty collections

    /// Verifies that explicitly empty `cap_add` / `cap_drop` lists produce no
    /// corresponding flags.
    @Test("Empty cap_add and cap_drop lists produce no argv flags")
    func emptyCapAddDropProduceNoFlags() throws {
        let yaml = """
        services:
          app:
            image: alpine
        """
        let (dc, service) = try decodeService(yaml)
        let ctx = makeContext(service: service, dc: dc)
        let args = ComposeUp.SecurityArgs.build(ctx)

        #expect(!args.contains("--cap-add"))
        #expect(!args.contains("--cap-drop"))
    }

    // MARK: - RuntimeCreateConfiguration security field propagation (CHAOS-1407)

    /// Verifies that `RuntimeCreateConfiguration` exposes all security fields
    /// and that default construction leaves them nil (no regression for callers
    /// that don't supply security context).
    @Test("RuntimeCreateConfiguration exposes security fields with nil defaults")
    func runtimeCreateConfigurationSecurityFieldDefaults() {
        let config = RuntimeCreateConfiguration(imageReference: "alpine")

        // Core fields remain intact
        #expect(config.imageReference == "alpine")
        #expect(config.cpus == 1)
        #expect(config.memoryInBytes > 0)

        // Security fields default to nil (no-op for current conformers)
        #expect(config.capabilities == nil)
        #expect(config.securityOpt == nil)
        #expect(config.readOnly == nil)
        #expect(config.user == nil)
        #expect(config.groupAdd == nil)
        #expect(config.privileged == nil)
    }

    /// Verifies that `capabilities` (cap_add / cap_drop) round-trips through
    /// `RuntimeCreateConfiguration` correctly.
    @Test("RuntimeCreateConfiguration carries cap_add and cap_drop via capabilities field")
    func runtimeCreateConfigurationCapabilities() {
        let caps = RuntimeCapabilities(add: ["NET_ADMIN", "SYS_TIME"], drop: ["ALL"])
        let config = RuntimeCreateConfiguration(
            imageReference: "alpine",
            capabilities: caps
        )

        #expect(config.capabilities?.add == ["NET_ADMIN", "SYS_TIME"])
        #expect(config.capabilities?.drop == ["ALL"])
    }

    /// Verifies that `securityOpt` round-trips through `RuntimeCreateConfiguration`.
    @Test("RuntimeCreateConfiguration carries securityOpt field")
    func runtimeCreateConfigurationSecurityOpt() {
        let opts = ["no-new-privileges:true", "seccomp:unconfined"]
        let config = RuntimeCreateConfiguration(
            imageReference: "alpine",
            securityOpt: opts
        )

        #expect(config.securityOpt == opts)
    }

    /// Verifies that `readOnly` round-trips through `RuntimeCreateConfiguration`.
    @Test("RuntimeCreateConfiguration carries readOnly field")
    func runtimeCreateConfigurationReadOnly() {
        let config = RuntimeCreateConfiguration(
            imageReference: "alpine",
            readOnly: true
        )

        #expect(config.readOnly == true)
    }

    /// Verifies that `user` round-trips through `RuntimeCreateConfiguration`.
    @Test("RuntimeCreateConfiguration carries user field")
    func runtimeCreateConfigurationUser() {
        let config = RuntimeCreateConfiguration(
            imageReference: "alpine",
            user: "1000:1000"
        )

        #expect(config.user == "1000:1000")
    }

    /// Verifies that `groupAdd` round-trips through `RuntimeCreateConfiguration`.
    @Test("RuntimeCreateConfiguration carries groupAdd field")
    func runtimeCreateConfigurationGroupAdd() {
        let config = RuntimeCreateConfiguration(
            imageReference: "alpine",
            groupAdd: ["audio", "video"]
        )

        #expect(config.groupAdd == ["audio", "video"])
    }

    /// Verifies that `privileged` round-trips through `RuntimeCreateConfiguration`.
    @Test("RuntimeCreateConfiguration carries privileged field")
    func runtimeCreateConfigurationPrivileged() {
        let config = RuntimeCreateConfiguration(
            imageReference: "alpine",
            privileged: true
        )

        #expect(config.privileged == true)
    }

    /// Verifies `Equatable` conformance with security fields: two configurations
    /// with differing security context are not equal.
    @Test("RuntimeCreateConfiguration Equatable accounts for security fields")
    func runtimeCreateConfigurationEquatableWithSecurityFields() {
        let base = RuntimeCreateConfiguration(imageReference: "alpine")
        let withCaps = RuntimeCreateConfiguration(
            imageReference: "alpine",
            capabilities: RuntimeCapabilities(add: ["NET_ADMIN"], drop: [])
        )
        let withUser = RuntimeCreateConfiguration(
            imageReference: "alpine",
            user: "1000"
        )

        #expect(base != withCaps)
        #expect(base != withUser)
        #expect(withCaps != withUser)
    }

    /// Full round-trip: all security fields set together produce the expected values.
    @Test("RuntimeCreateConfiguration carries all security fields simultaneously")
    func runtimeCreateConfigurationAllSecurityFieldsTogether() {
        let caps = RuntimeCapabilities(add: ["NET_ADMIN"], drop: ["ALL"])
        let config = RuntimeCreateConfiguration(
            imageReference: "nginx:alpine",
            capabilities: caps,
            securityOpt: ["no-new-privileges:true"],
            readOnly: true,
            user: "2000:2000",
            groupAdd: ["docker"],
            privileged: false
        )

        #expect(config.capabilities?.add == ["NET_ADMIN"])
        #expect(config.capabilities?.drop == ["ALL"])
        #expect(config.securityOpt == ["no-new-privileges:true"])
        #expect(config.readOnly == true)
        #expect(config.user == "2000:2000")
        #expect(config.groupAdd == ["docker"])
        #expect(config.privileged == false)
    }

    /// Verifies that YAML decode → Service → RuntimeCreateConfiguration
    /// propagates `cap_add` / `cap_drop` into `capabilities`.
    ///
    /// This is the primary integration assertion that closes the
    /// CHAOS-1407 gap: the Compose YAML security fields must survive the
    /// full decode path and appear in the spec struct.
    @Test("YAML cap_add/cap_drop decode into Service and map to RuntimeCapabilities")
    func yamlCapabilitiesRoundTripToRuntimeCreateConfiguration() throws {
        let yaml = """
        services:
          app:
            image: nginx:alpine
            cap_add:
              - NET_ADMIN
              - SYS_TIME
            cap_drop:
              - ALL
        """
        let (_, service) = try decodeService(yaml)
        #expect(service.cap_add == ["NET_ADMIN", "SYS_TIME"])
        #expect(service.cap_drop == ["ALL"])

        // Build a RuntimeCreateConfiguration the way a compose-up path would
        let caps = RuntimeCapabilities(
            add: service.cap_add ?? [],
            drop: service.cap_drop ?? []
        )
        let config = RuntimeCreateConfiguration(
            imageReference: service.image ?? "unknown",
            capabilities: caps.add.isEmpty && caps.drop.isEmpty ? nil : caps
        )

        #expect(config.capabilities?.add == ["NET_ADMIN", "SYS_TIME"])
        #expect(config.capabilities?.drop == ["ALL"])
    }

    /// Verifies that YAML `read_only`, `user`, `security_opt`, `group_add`,
    /// and `privileged` all decode into `Service` and can be plumbed into a
    /// `RuntimeCreateConfiguration`.
    @Test("YAML security fields decode into Service and map to RuntimeCreateConfiguration")
    func yamlSecurityFieldsRoundTripToRuntimeCreateConfiguration() throws {
        let yaml = """
        services:
          hardened:
            image: nginx:alpine
            user: "2000:2000"
            read_only: true
            privileged: false
            security_opt:
              - no-new-privileges:true
            group_add:
              - audio
        """
        let (_, service) = try decodeService(yaml, name: "hardened")

        let config = RuntimeCreateConfiguration(
            imageReference: service.image ?? "unknown",
            securityOpt: service.security_opt,
            readOnly: service.read_only,
            user: service.user,
            groupAdd: service.group_add,
            privileged: service.privileged
        )

        #expect(config.readOnly == true)
        #expect(config.user == "2000:2000")
        #expect(config.groupAdd == ["audio"])
        #expect(config.securityOpt == ["no-new-privileges:true"])
        #expect(config.privileged == false)
    }
}
