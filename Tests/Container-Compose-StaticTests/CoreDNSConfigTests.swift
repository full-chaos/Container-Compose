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

    @Test("Project name validation rejects invalid label")
    func invalidProjectName() {
        expectError(.invalidProjectName("my.project")) {
            _ = try CoreDNSConfig.makeCorefile(projectName: "my.project")
        }
    }

    @Test("Project name validation rejects leading hyphen")
    func invalidProjectNameLeadingHyphen() {
        expectError(.invalidProjectName("-project")) {
            _ = try CoreDNSConfig.makeZone(projectName: "-project", services: [], serial: 1)
        }
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
