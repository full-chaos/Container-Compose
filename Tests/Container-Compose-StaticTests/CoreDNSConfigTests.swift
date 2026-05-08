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

import Foundation
import SystemPackage
import Testing

@testable import ContainerComposeCore

@Suite("CoreDNSConfig Tests")
struct CoreDNSConfigTests {
    @Test("Golden Corefile with default upstream DNS")
    func goldenCorefile() throws {
        let actual = try CoreDNSConfig.makeCorefile(projectName: "myproject")
        let expected = """
        . {
            forward . 8.8.8.8 1.1.1.1
            cache 30
            log
            errors
        }

        myproject.test {
            file /etc/coredns/zones/myproject.zone {
                reload 5s
            }
            log
            errors
        }
        """
        #expect(actual == expected + "\n")
    }

    @Test("Golden zone with no aliases")
    func goldenZoneNoAliases() throws {
        let actual = try CoreDNSConfig.makeZone(
            projectName: "myproject",
            services: [CoreDNSConfig.ServiceRecord(name: "postgres", ip: "10.0.0.10", aliases: [])],
            serial: 42
        )
        let expected = """
        $ORIGIN myproject.test.
        $TTL 60
        @   IN SOA ns.myproject.test. admin.myproject.test. 42 60 60 60 60

        postgres   IN A   10.0.0.10
        """
        #expect(actual == expected + "\n")
    }

    @Test("Golden zone with aliases")
    func goldenZoneWithAliases() throws {
        let actual = try CoreDNSConfig.makeZone(
            projectName: "myproject",
            services: [CoreDNSConfig.ServiceRecord(name: "postgres", ip: "10.0.0.10", aliases: ["db"])],
            serial: 42
        )
        let expected = """
        $ORIGIN myproject.test.
        $TTL 60
        @   IN SOA ns.myproject.test. admin.myproject.test. 42 60 60 60 60

        postgres   IN A   10.0.0.10
        db         IN A   10.0.0.10  ; alias of postgres
        """
        #expect(actual == expected + "\n")
    }

    @Test("Multi-A records for shared service name")
    func multiARecords() throws {
        let actual = try CoreDNSConfig.makeZone(
            projectName: "myproject",
            services: [
                CoreDNSConfig.ServiceRecord(name: "postgres", ip: "10.0.0.10", aliases: []),
                CoreDNSConfig.ServiceRecord(name: "postgres", ip: "10.0.0.11", aliases: [])
            ],
            serial: 7
        )
        #expect(actual.contains("postgres   IN A   10.0.0.10\npostgres   IN A   10.0.0.11"))
    }

    @Test("Empty service list still emits SOA")
    func emptyServiceList() throws {
        let actual = try CoreDNSConfig.makeZone(projectName: "myproject", services: [], serial: 99)
        #expect(actual.contains("@   IN SOA ns.myproject.test. admin.myproject.test. 99 60 60 60 60"))
        #expect(actual.contains("$ORIGIN myproject.test."))
    }

    @Test("Project name with all-invalid scalars is rejected")
    func invalidProjectName() {
        // Empty after sanitization → invalidProjectName.
        expectError(.invalidProjectName("...")) {
            _ = try CoreDNSConfig.makeCorefile(projectName: "...")
        }
    }

    @Test("Project name of only underscores is rejected")
    func invalidProjectNameOnlyUnderscores() {
        expectError(.invalidProjectName("___")) {
            _ = try CoreDNSConfig.makeZone(projectName: "___", services: [], serial: 1)
        }
    }

    @Test("Empty project name is rejected")
    func invalidProjectNameEmpty() {
        expectError(.invalidProjectName("")) {
            _ = try CoreDNSConfig.dnsZoneLabel(for: "")
        }
    }

    // MARK: - CHAOS-1475 — DNS-safe zone-label derivation

    @Test("validateProjectName accepts underscore project names (CHAOS-1475)")
    func validateProjectNameAcceptsUnderscores() throws {
        // Regression guard: deriveProjectName(cwd:) maps `.` → `_`, producing
        // names like `my_app` that previously hard-failed at sidecar startup.
        try CoreDNSConfig.validateProjectName("my_app")
        try CoreDNSConfig.validateProjectName("my_long_app_name")
        try CoreDNSConfig.validateProjectName("_leading_underscore")
        try CoreDNSConfig.validateProjectName("trailing_underscore_")
    }

    @Test("dnsZoneLabel sanitizes underscores to hyphens")
    func dnsZoneLabelSanitizesUnderscores() throws {
        let label = try CoreDNSConfig.dnsZoneLabel(for: "my_app")
        #expect(label == "my-app")
    }

    @Test("dnsZoneLabel maps dots and other non-alnum scalars to hyphens")
    func dnsZoneLabelSanitizesDotsAndOthers() throws {
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "my.project") == "my-project")
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "my/project") == "my-project")
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "my project") == "my-project")
    }

    @Test("dnsZoneLabel lowercases the result")
    func dnsZoneLabelLowercases() throws {
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "MyApp") == "myapp")
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "My_APP") == "my-app")
    }

    @Test("dnsZoneLabel collapses runs of separators")
    func dnsZoneLabelCollapsesSeparators() throws {
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "a__b") == "a-b")
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "a---b") == "a-b")
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "a_._.b") == "a-b")
    }

    @Test("dnsZoneLabel strips leading and trailing separators")
    func dnsZoneLabelStripsEdges() throws {
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "-project") == "project")
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "project-") == "project")
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "_project_") == "project")
        #expect(try CoreDNSConfig.dnsZoneLabel(for: "--my_app--") == "my-app")
    }

    @Test("dnsZoneLabel clamps to 63 chars and re-strips trailing hyphens")
    func dnsZoneLabelClampsTo63Chars() throws {
        let long = String(repeating: "a", count: 70)
        let label = try CoreDNSConfig.dnsZoneLabel(for: long)
        #expect(label.count == 63)
        #expect(label == String(repeating: "a", count: 63))

        // Construct an input where the 63rd character would be `-` so we can
        // verify trailing-hyphen re-strip. "a" * 62 + "_x" → sanitized to
        // "a" * 62 + "-x" (64 chars) → prefix(63) = "a" * 62 + "-" → strip →
        // "a" * 62 (62 chars).
        let edge = String(repeating: "a", count: 62) + "_x"
        let edgeLabel = try CoreDNSConfig.dnsZoneLabel(for: edge)
        #expect(edgeLabel == String(repeating: "a", count: 62))
        #expect(!edgeLabel.hasSuffix("-"))
    }

    @Test("makeCorefile uses sanitized zone label but raw project name in file path")
    func makeCorefileUnderscoreProject() throws {
        // Corefile must reference `my-app.test` zone (DNS-safe), but the
        // bind-mounted file path on disk keeps the raw `my_app.zone` so it
        // matches what EmbeddedDNSSidecar writes to ~/.container-compose/<raw>/.
        let corefile = try CoreDNSConfig.makeCorefile(projectName: "my_app")
        #expect(corefile.contains("my-app.test {"))
        #expect(corefile.contains("file /etc/coredns/zones/my_app.zone {"))
        #expect(!corefile.contains("my_app.test"))
    }

    @Test("makeZone emits sanitized SOA and origin for underscore project")
    func makeZoneUnderscoreProject() throws {
        let zone = try CoreDNSConfig.makeZone(
            projectName: "my_app",
            services: [CoreDNSConfig.ServiceRecord(name: "db", ip: "10.0.0.5", aliases: [])],
            serial: 100
        )
        #expect(zone.contains("$ORIGIN my-app.test."))
        #expect(zone.contains("@   IN SOA ns.my-app.test. admin.my-app.test. 100 60 60 60 60"))
        #expect(!zone.contains("my_app.test"))
    }

    @Test("zoneDomain returns sanitized form")
    func zoneDomainSanitized() throws {
        #expect(try CoreDNSConfig.zoneDomain(for: "my_app") == "my-app.test")
        #expect(try CoreDNSConfig.zoneDomain(for: "My.App") == "my-app.test")
        #expect(try CoreDNSConfig.zoneDomain(for: "plain") == "plain.test")
    }

    @Test("SidecarHandle.searchDomain uses sanitized zone label (CHAOS-1475)")
    func sidecarHandleSearchDomainSanitized() {
        // Direct construction — we don't go through start() because that
        // requires runtime fakes; we just need to verify the computed property.
        let handle = SidecarHandle(
            projectName: "my_app",
            containerName: "my_app-compose-dns",
            configRoot: FilePath("/tmp/my_app/dns"),
            perNetworkIPs: [:]
        )
        // searchDomain mirrors the CoreDNS-served zone, which is sanitized.
        #expect(handle.searchDomain == "my-app.test")
        // Container name remains the raw runtime form — it's a runtime
        // identifier, not a DNS name. This is the whole point of the split.
        #expect(handle.containerName == "my_app-compose-dns")
        #expect(handle.projectName == "my_app")
    }

    @Test("SidecarHandle.searchDomain matches plain project verbatim")
    func sidecarHandleSearchDomainPlain() {
        let handle = SidecarHandle(
            projectName: "plain",
            containerName: "plain-compose-dns",
            configRoot: FilePath("/tmp/plain/dns"),
            perNetworkIPs: [:]
        )
        #expect(handle.searchDomain == "plain.test")
    }

    @Test("Service name validation rejects invalid label")
    func invalidServiceName() {
        expectError(.invalidServiceName("db.service")) {
            _ = try CoreDNSConfig.makeZone(
                projectName: "myproject",
                services: [CoreDNSConfig.ServiceRecord(name: "db.service", ip: "10.0.0.10", aliases: [])],
                serial: 1
            )
        }
    }

    @Test("Alias validation rejects invalid label")
    func invalidAlias() {
        expectError(.invalidAlias("db.service")) {
            _ = try CoreDNSConfig.makeZone(
                projectName: "myproject",
                services: [CoreDNSConfig.ServiceRecord(name: "postgres", ip: "10.0.0.10", aliases: ["db.service"])],
                serial: 1
            )
        }
    }

    @Test("IPv4 validation rejects invalid address")
    func invalidIPAddress() {
        expectError(.invalidIPAddress("10.0.0.999")) {
            _ = try CoreDNSConfig.makeZone(
                projectName: "myproject",
                services: [CoreDNSConfig.ServiceRecord(name: "postgres", ip: "10.0.0.999", aliases: [])],
                serial: 1
            )
        }
    }

    @Test("Serial appears in SOA")
    func serialAppearsInSOA() throws {
        let serial: Int64 = 20260507
        let actual = try CoreDNSConfig.makeZone(projectName: "myproject", services: [], serial: serial)
        #expect(actual.contains("\(serial) 60 60 60 60"))
    }

    private func expectError(_ expected: CoreDNSConfigError, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected error \(expected), but succeeded")
        } catch let error as CoreDNSConfigError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), got unexpected error: \(error)")
        }
    }
}
