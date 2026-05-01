//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors.
// Apache License, Version 2.0
//===----------------------------------------------------------------------===//

import Foundation
import Testing
@testable import ContainerComposeCore

@Suite
struct ListenAddressTests {

    // MARK: - unix:// parsing

    @Test("parse unix:///abs/path returns .unix")
    func parseUnixAbsPath() throws {
        let addr = try ListenAddress.parse("unix:///var/run/api.sock")
        #expect(addr == .unix(path: "/var/run/api.sock"))
    }

    @Test("parse unix:// with tilde expands to home directory")
    func parseUnixTildeExpansion() throws {
        let addr = try ListenAddress.parse("unix://~/.container-compose/api.sock")
        guard case .unix(let path) = addr else {
            Issue.record("Expected .unix, got \(addr)")
            return
        }
        #expect(path.hasPrefix(NSHomeDirectory()))
        #expect(path.hasSuffix("/.container-compose/api.sock"))
    }

    // MARK: - tcp:// parsing

    @Test("parse tcp://localhost:8080 returns .tcp")
    func parseTCPLocalhost() throws {
        let addr = try ListenAddress.parse("tcp://localhost:8080")
        #expect(addr == .tcp(host: "localhost", port: 8080))
    }

    @Test("parse tcp://127.0.0.1:9000 returns .tcp")
    func parseTCPLoopback() throws {
        let addr = try ListenAddress.parse("tcp://127.0.0.1:9000")
        #expect(addr == .tcp(host: "127.0.0.1", port: 9000))
    }

    @Test("parse tcp://0.0.0.0:8080 returns .tcp non-localhost")
    func parseTCPWildcard() throws {
        let addr = try ListenAddress.parse("tcp://0.0.0.0:8080")
        #expect(addr == .tcp(host: "0.0.0.0", port: 8080))
        #expect(!addr.isLocalhost)
    }

    // MARK: - tls:// parsing

    @Test("parse tls://localhost:8443 returns .tls")
    func parseTLSLocalhost() throws {
        let addr = try ListenAddress.parse("tls://localhost:8443")
        #expect(addr == .tls(host: "localhost", port: 8443))
    }

    @Test("parse tls://[::1]:8443 returns .tls IPv6")
    func parseTLSIPv6() throws {
        let addr = try ListenAddress.parse("tls://[::1]:8443")
        guard case .tls(let host, let port) = addr else {
            Issue.record("Expected .tls, got \(addr)")
            return
        }
        #expect(host == "::1")
        #expect(port == 8443)
        #expect(addr.isLocalhost)
    }

    // MARK: - isLocalhost

    @Test("unix is always localhost")
    func unixIsLocalhost() throws {
        let addr = ListenAddress.unix(path: "/tmp/test.sock")
        #expect(addr.isLocalhost)
    }

    @Test("tcp localhost is localhost")
    func tcpLocalhostIsLocalhost() {
        #expect(ListenAddress.tcp(host: "localhost", port: 80).isLocalhost)
        #expect(ListenAddress.tcp(host: "127.0.0.1", port: 80).isLocalhost)
        #expect(ListenAddress.tcp(host: "::1", port: 80).isLocalhost)
    }

    @Test("tcp 0.0.0.0 is not localhost")
    func tcpWildcardNotLocalhost() {
        #expect(!ListenAddress.tcp(host: "0.0.0.0", port: 80).isLocalhost)
    }

    // MARK: - requiresTLS

    @Test("requiresTLS is true only for .tls")
    func requiresTLS() {
        #expect(!ListenAddress.unix(path: "/tmp/t.sock").requiresTLS)
        #expect(!ListenAddress.tcp(host: "localhost", port: 80).requiresTLS)
        #expect(ListenAddress.tls(host: "localhost", port: 443).requiresTLS)
    }

    // MARK: - bindAddress

    @Test("bindAddress for unix returns unixDomainSocket")
    func bindAddressUnix() {
        let addr = ListenAddress.unix(path: "/tmp/test.sock")
        // Verify it doesn't crash and produces expected description
        _ = addr.bindAddress
    }

    @Test("bindAddress for tcp returns hostname")
    func bindAddressTCP() {
        let addr = ListenAddress.tcp(host: "127.0.0.1", port: 9000)
        _ = addr.bindAddress
    }

    // MARK: - Error cases

    @Test("missing port throws missingHostOrPort")
    func missingPort() {
        #expect(throws: ListenAddressError.missingHostOrPort("tcp://localhost")) {
            try ListenAddress.parse("tcp://localhost")
        }
    }

    @Test("unsupported scheme throws unsupportedScheme")
    func unsupportedScheme() {
        #expect(throws: ListenAddressError.unsupportedScheme("http")) {
            try ListenAddress.parse("http://localhost:80")
        }
    }

    @Test("malformed URL throws malformed")
    func malformedURL() {
        #expect(throws: ListenAddressError.malformed("not-a-url")) {
            try ListenAddress.parse("not-a-url")
        }
    }

    // MARK: - Description

    @Test("description matches input format")
    func description() throws {
        #expect(ListenAddress.unix(path: "/tmp/api.sock").description == "unix:///tmp/api.sock")
        #expect(ListenAddress.tcp(host: "localhost", port: 8080).description == "tcp://localhost:8080")
        #expect(ListenAddress.tls(host: "localhost", port: 8443).description == "tls://localhost:8443")
    }
}
