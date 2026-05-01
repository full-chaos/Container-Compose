//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors.
// Apache License, Version 2.0
//===----------------------------------------------------------------------===//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - TCPProbe

/// TCP-level liveness probe for TCP/TLS listen addresses.
/// Used by `ServeDaemon.isAlreadyServing(listenAddress:)` for the TCP/TLS case.
/// We only check TCP connectivity (no TLS handshake) — sufficient for idempotence.
///
/// CHAOS-1359 (Phase 9)
enum TCPProbe {
    static func canConnect(to host: String, port: Int, timeoutSeconds: Int) -> Bool {
        var hints = addrinfo()
        hints.ai_family   = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let info = result else { return false }
        defer { freeaddrinfo(result) }

        let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connectResult = withUnsafePointer(to: info.pointee.ai_addr.pointee) { rawPtr -> Int32 in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, info.pointee.ai_addrlen)
            }
        }
        return connectResult == 0
    }
}
