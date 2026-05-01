//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors.
// Apache License, Version 2.0
//===----------------------------------------------------------------------===//

import Darwin
import Foundation
import Testing
@testable import ContainerComposeCore

@Suite(.serialized)
struct IdempotenceTCPTests {

    // MARK: - TCP probe tests

    @Test("TCPProbe returns false when nothing is bound")
    func tcpProbeNotBound() {
        // Use a port very unlikely to be in use
        #expect(TCPProbe.canConnect(to: "127.0.0.1", port: 19_999, timeoutSeconds: 1) == false)
    }

    @Test("TCPProbe returns true when a listening socket is bound")
    func tcpProbeSucceeds() throws {
        let port: Int = 19_988
        let fd = try bindListeningTCPSocket(port: port)
        defer { close(fd) }

        #expect(TCPProbe.canConnect(to: "127.0.0.1", port: port, timeoutSeconds: 1) == true)
    }

    // MARK: - isAlreadyServing(listenAddress:) for TCP

    @Test("isAlreadyServing(.tcp) returns false when nothing is bound")
    func isAlreadyServingTCPNotBound() {
        let listen = ListenAddress.tcp(host: "127.0.0.1", port: 19_987)
        #expect(ServeDaemon.isAlreadyServing(listenAddress: listen) == false)
    }

    @Test("isAlreadyServing(.tcp) returns true when port is bound")
    func isAlreadyServingTCPBound() throws {
        let port: Int = 19_986
        let fd = try bindListeningTCPSocket(port: port)
        defer { close(fd) }

        let listen = ListenAddress.tcp(host: "127.0.0.1", port: port)
        #expect(ServeDaemon.isAlreadyServing(listenAddress: listen) == true)
    }

    // TLS address — we only TCP-probe, no TLS handshake.
    @Test("isAlreadyServing(.tls) returns true when port is TCP-bound")
    func isAlreadyServingTLSBound() throws {
        let port: Int = 19_985
        let fd = try bindListeningTCPSocket(port: port)
        defer { close(fd) }

        let listen = ListenAddress.tls(host: "127.0.0.1", port: port)
        #expect(ServeDaemon.isAlreadyServing(listenAddress: listen) == true)
    }

    // MARK: - isAlreadyServing(listenAddress:) for Unix — round-trip to existing impl

    @Test("isAlreadyServing(.unix) matches isAlreadyServing(at:) for no-file case")
    func isAlreadyServingUnixNoFile() {
        let path = "/tmp/idempotence-test-\(UUID().uuidString).sock"
        let listen = ListenAddress.unix(path: path)
        #expect(ServeDaemon.isAlreadyServing(listenAddress: listen) == false)
        #expect(ServeDaemon.isAlreadyServing(at: path) == false)
    }

    // MARK: - Helpers

    private func bindListeningTCPSocket(port: Int) throws -> Int32 {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = UInt16(port).bigEndian
        addr.sin_addr   = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TestError.socketFailed(errno: errno)
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw TestError.bindFailed(errno: errno)
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw TestError.listenFailed(errno: errno)
        }
        return fd
    }

    private enum TestError: Error {
        case socketFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
    }
}
