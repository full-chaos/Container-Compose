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
import Darwin
import Yams
@testable import ContainerComposeCore

/// Security feature integration tests for Task 1.4.
///
/// These tests verify the full **YAML → Service decode → SecurityArgs.build() → argv**
/// pipeline for each security-related compose field.  They are "integration"
/// tests in the sense that they exercise the entire compose-file-parse path,
/// not just hand-crafted `Service` objects, so regressions in `Service.init(from:)`
/// that silently drop a security field will surface here.
///
/// # Architecture note — where security features live
///
/// Container-Compose's job is to **translate** compose fields to `container run`
/// argv.  The real backend (apple/container) is what actually enforces
/// capabilities, read-only filesystem, etc.  All security translation happens in
/// `ComposeUp.SecurityArgs.build(_:)` and produces `[String]` argv items.
///
/// `RuntimeCreateConfiguration` — the struct passed to `Runtime.create()` in the
/// native path — intentionally **does not** carry security fields; it carries
/// only the fields wired through the native API server (image, CPUs, memory,
/// hostname, env, command, ports).  The per-concern argv builders, including
/// `SecurityArgs`, still own the security surface and produce argv fed to
/// `container run` via `RunCommandRunner`.
///
/// # Gap documentation
///
/// Fields that Compose accepts but `RuntimeCreateConfiguration` does NOT carry:
/// - `cap_add` / `cap_drop` — argv-only via `SecurityArgs`; no counterpart in
///   `RuntimeCreateConfiguration`.
/// - `security_opt` — Compose accepts it; apple/container rejects `--security-opt`;
///   `SecurityArgs` warn-and-skips it; gap is intentional.
/// - `read_only` — argv-only (`--read-only`); not in `RuntimeCreateConfiguration`.
/// - `user` — argv-only (`--user`); not in `RuntimeCreateConfiguration`.
/// - `group_add` — Compose accepts it; apple/container rejects `--group-add`;
///   warn-and-skip; not in `RuntimeCreateConfiguration`.
/// - `privileged` — Compose accepts it; apple/container rejects `--privileged`;
///   warn-and-skip; not in `RuntimeCreateConfiguration`.
///
/// See `docs/reviews/phase1-remainder-test-gaps.md` for the authoritative gap list.
@Suite("Security feature integration tests — YAML → SecurityArgs.build() → argv", .serialized)
struct SecurityFeatureIntegrationTests {

    // MARK: - Helpers

    /// Decode a `DockerCompose` from YAML and return the named service.
    private func decodeService(_ yaml: String, name: String = "app") throws -> (DockerCompose, Service) {
        let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dc.services[name] else {
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
    private func captureStdout(_ body: () throws -> Void) throws -> String {
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        guard original >= 0 else { throw TestError.dupFailed }
        let pipe = Pipe()
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            close(original)
            throw TestError.dupFailed
        }
        do {
            try body()
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
    func privilegedYAMLDecodesButNotEmitted() throws {
        let yaml = """
        services:
          app:
            image: alpine
            privileged: true
        """
        let (dc, service) = try decodeService(yaml)
        #expect(service.privileged == true)

        var args: [String] = []
        let output = try captureStdout {
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
    func securityOptYAMLDecodesButNotEmitted() throws {
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
        let output = try captureStdout {
            args = ComposeUp.SecurityArgs.build(makeContext(service: service, dc: dc))
        }

        #expect(!args.contains("--security-opt"))
        #expect(!args.contains("seccomp:unconfined"))
        #expect(!args.contains("no-new-privileges:true"))
        #expect(output.contains("Note: 'security_opt' is parsed but not supported by Apple container; ignored."))
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
    func groupAddYAMLDecodesButNotEmitted() throws {
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
        let output = try captureStdout {
            args = ComposeUp.SecurityArgs.build(makeContext(service: service, dc: dc))
        }

        #expect(!args.contains("--group-add"))
        #expect(!args.contains("audio"))
        #expect(!args.contains("video"))
        #expect(output.contains("Note: 'group_add' is parsed but not supported by Apple container; ignored."))
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
    func allWarnAndSkipFieldsEmitNoArgv() throws {
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
        _ = try captureStdout {
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

    // MARK: - RuntimeCreateConfiguration gap documentation

    /// This is a compile-time assertion that `RuntimeCreateConfiguration` carries
    /// none of the security fields.  The test intentionally inspects only the
    /// public surface; it does not check private properties.
    ///
    /// If someone adds `capabilities`, `readOnly`, `user`, or `privileged`
    /// to `RuntimeCreateConfiguration`, they should update this test to assert
    /// the field is populated from the compose service, and remove the
    /// corresponding TODO comment in `docs/reviews/phase1-remainder-test-gaps.md`.
    ///
    /// GAP SUMMARY (see also `docs/reviews/phase1-remainder-test-gaps.md`):
    /// - `cap_add` / `cap_drop` → no field in `RuntimeCreateConfiguration`
    /// - `security_opt`         → no field in `RuntimeCreateConfiguration` (and
    ///                            apple/container doesn't support it anyway)
    /// - `read_only`            → no field in `RuntimeCreateConfiguration`
    /// - `user`                 → no field in `RuntimeCreateConfiguration`
    /// - `group_add`            → no field in `RuntimeCreateConfiguration` (and
    ///                            apple/container doesn't support it anyway)
    /// - `privileged`           → no field in `RuntimeCreateConfiguration` (and
    ///                            apple/container doesn't support it anyway)
    // TODO(CHAOS-1407): When security fields are wired into RuntimeCreateConfiguration,
    //   add property-access assertions here for each new field and remove the
    //   corresponding gap entry from phase1-remainder-test-gaps.md.
    @Test("RuntimeCreateConfiguration does not yet expose security fields (gap baseline)")
    func runtimeCreateConfigurationHasNoSecurityFields() {
        let config = RuntimeCreateConfiguration(imageReference: "alpine")

        // Verify the fields we DO have (sanity check the struct is wired at all)
        #expect(config.imageReference == "alpine")
        #expect(config.cpus == 1)
        #expect(config.memoryInBytes > 0)

        // Security fields are NOT present on RuntimeCreateConfiguration.
        // If this test no longer compiles after someone adds them, update it to
        // assert the values rather than deleting the test.
        //
        // The following properties do NOT exist on RuntimeCreateConfiguration today:
        //   config.capabilities (cap_add / cap_drop)
        //   config.readOnly      (read_only)
        //   config.user          (user)
        //   config.privileged    (privileged)
        //   config.securityOpt   (security_opt)
        //   config.groupAdd      (group_add)
    }
}
