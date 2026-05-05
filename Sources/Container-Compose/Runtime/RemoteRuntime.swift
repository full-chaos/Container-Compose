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

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOPosix
import NIOSSL

public struct RemoteRuntimeConfiguration: Sendable, Equatable {
    public let address: ListenAddress
    public let cacertPath: String?
    public let certPath: String?
    public let keyPath: String?
    public let token: String?

    public init(
        address: ListenAddress,
        cacertPath: String? = nil,
        certPath: String? = nil,
        keyPath: String? = nil,
        token: String? = nil
    ) {
        self.address = address
        self.cacertPath = cacertPath
        self.certPath = certPath
        self.keyPath = keyPath
        self.token = token
    }
}

public enum RemoteRuntimeFlagParser {
    public static func extract(from args: [String]) throws -> (configuration: RemoteRuntimeConfiguration?, remainder: [String]) {
        guard !args.isEmpty else { return (nil, args) }

        var remainder: [String] = []
        var address: ListenAddress?
        var cacertPath: String?
        var certPath: String?
        var keyPath: String?
        var tokenValue: String?
        var sawRemote = false
        var i = 0

        func captureValue(_ token: String) -> (name: String, value: String?) {
            if let eq = token.firstIndex(of: "=") {
                let name = String(token[..<eq])
                let value = String(token[token.index(after: eq)...])
                return (name, value)
            }
            return (token, nil)
        }

        while i < args.count {
            let token = args[i]
            if !token.hasPrefix("-") {
                remainder.append(contentsOf: args[i...])
                break
            }

            let (name, inlineValue) = captureValue(token)
            switch name {
            case "--remote":
                let value: String
                if let inlineValue {
                    value = inlineValue
                } else if i + 1 < args.count {
                    i += 1
                    value = args[i]
                } else {
                    remainder.append(token)
                    i += 1
                    continue
                }
                sawRemote = true
                address = try ListenAddress.parse(value)
            case "--cacert":
                let value: String
                if let inlineValue {
                    value = inlineValue
                } else if i + 1 < args.count {
                    i += 1
                    value = args[i]
                } else {
                    remainder.append(token)
                    i += 1
                    continue
                }
                cacertPath = value
            case "--cert":
                let value: String
                if let inlineValue {
                    value = inlineValue
                } else if i + 1 < args.count {
                    i += 1
                    value = args[i]
                } else {
                    remainder.append(token)
                    i += 1
                    continue
                }
                certPath = value
            case "--key":
                let value: String
                if let inlineValue {
                    value = inlineValue
                } else if i + 1 < args.count {
                    i += 1
                    value = args[i]
                } else {
                    remainder.append(token)
                    i += 1
                    continue
                }
                keyPath = value
            case "--token":
                let value: String
                if let inlineValue {
                    value = inlineValue
                } else if i + 1 < args.count {
                    i += 1
                    value = args[i]
                } else {
                    remainder.append(token)
                    i += 1
                    continue
                }
                tokenValue = value
            default:
                remainder.append(token)
            }
            i += 1
        }

        guard sawRemote, let address else {
            return (nil, args)
        }

        let configuration = RemoteRuntimeConfiguration(
            address: address,
            cacertPath: cacertPath,
            certPath: certPath,
            keyPath: keyPath,
            token: tokenValue
        )
        return (configuration, remainder)
    }
}

public struct RemoteRuntime: Runtime, Sendable {
    private let configuration: RemoteRuntimeConfiguration

    public init(configuration: RemoteRuntimeConfiguration) {
        self.configuration = configuration
    }

    public func version() async throws -> RuntimeVersion {
        let response: APIVersionResponse = try await requestJSON(.get, path: "/version")
        return RuntimeVersion(
            apiVersion: response.apiVersion,
            daemonVersion: response.version,
            serverName: response.serverName,
            backendDescription: response.runtimeBackend,
            arch: response.arch
        )
    }

    public func list(filters: RuntimeListFilters) async throws -> [RuntimeContainer] {
        let response: [APIContainerSummary] = try await requestJSON(.get, path: "/containers", query: filtersQuery(filters))
        return response.map(Self.toRuntimeContainer(summary:))
    }

    public func listNetworks() async throws -> [RuntimeNetwork] {
        let response: [APINetworkSummary] = try await requestJSON(.get, path: "/networks")
        return response.map(Self.toRuntimeNetwork(summary:))
    }

    public func get(id: String) async throws -> RuntimeContainer {
        let response: APIContainerInspect = try await requestJSON(.get, path: "/containers/\(id)")
        return Self.toRuntimeContainer(inspect: response)
    }

    public func create(id: String, configuration: RuntimeCreateConfiguration) async throws -> RuntimeContainer {
        let body = APICreateContainerRequest(
            image: configuration.imageReference,
            name: id,
            cpus: configuration.cpus,
            memoryBytes: configuration.memoryInBytes,
            hostname: configuration.hostname,
            env: configuration.environment.isEmpty ? nil : configuration.environment,
            cmd: configuration.command.isEmpty ? nil : configuration.command,
            workingDir: configuration.workingDirectory,
            publishedPorts: configuration.publishedPorts.isEmpty ? nil : configuration.publishedPorts.map {
                APICreatePortMapping(
                    hostPort: $0.hostPort,
                    containerPort: $0.containerPort,
                    proto: $0.proto.rawValue,
                    hostAddress: $0.hostAddress
                )
            }
        )
        let created: APICreateContainerResponse = try await requestJSON(.post, path: "/containers/create", query: ["name": id], body: body)
        if created.id == id {
            return try await get(id: id)
        }
        return RuntimeContainer(id: created.id, imageReference: configuration.imageReference, status: .created, publishedPorts: configuration.publishedPorts)
    }

    public func start(id: String) async throws {
        _ = try await requestNoContent(.post, path: "/containers/\(id)/start")
    }

    public func stop(id: String, options: RuntimeStopOptions) async throws {
        let body = APIStopRequest(signal: options.signal, timeoutSeconds: options.timeoutSeconds)
        _ = try await requestNoContent(.post, path: "/containers/\(id)/stop", body: body)
    }

    public func kill(id: String, signal: Int32) async throws {
        let body = APIKillRequest(signal: signal)
        _ = try await requestNoContent(.post, path: "/containers/\(id)/kill", body: body)
    }

    public func wait(id: String, timeoutSeconds: Int) async throws -> RuntimeExitStatus {
        let response: APIWaitResponse = try await requestJSON(.post, path: "/containers/\(id)/wait", query: ["timeout": String(timeoutSeconds)])
        return RuntimeExitStatus(exitCode: response.exitCode, exitedAt: response.exitedAt)
    }

    public func remove(id: String, force: Bool) async throws {
        _ = try await requestNoContent(.delete, path: "/containers/\(id)", query: ["force": force ? "true" : "false"])
    }

    public func logs(id: String, options: RuntimeLogOptions) async throws -> AsyncStream<RuntimeLogFrame> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let query = logsQuery(options)
                    let body = try await requestNDJSON(path: "/containers/\(id)/logs", query: query)
                    for frame in body.compactMap(Self.decodeLogFrame(_:)) {
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func events() async throws -> AsyncStream<RuntimeContainerEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let body = try await requestNDJSON(path: "/events")
                    for event in body.compactMap(Self.decodeEvent(_:)) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func statistics(for id: String) async throws -> RuntimeStatistics {
        let frame: APIStatsFrame = try await requestJSON(.get, path: "/containers/\(id)/stats", query: ["stream": "false"])
        return RuntimeStatistics(
            id: frame.id,
            cpuUsageUsec: frame.cpuUsageMicroseconds,
            memoryUsageBytes: frame.memoryUsageBytes,
            memoryLimitBytes: frame.memoryLimitBytes,
            oomKillCount: frame.oomKillCount,
            networks: frame.networks.map { RuntimeStatistics.Network(interface: $0.interface, receivedBytes: $0.receivedBytes, transmittedBytes: $0.transmittedBytes) },
            sampledAt: frame.sampledAt
        )
    }

    public func createNetwork(spec: RuntimeCreateNetworkSpec) async throws -> RuntimeNetwork {
        let body = APICreateNetworkRequest(name: spec.name, driver: spec.driver, subnet: spec.subnet, gateway: spec.gateway, labels: spec.labels)
        let response: APICreateNetworkResponse = try await requestJSON(.post, path: "/networks", body: body)
        return RuntimeNetwork(id: response.id, name: response.name, driver: spec.driver, subnet: spec.subnet, gateway: spec.gateway, labels: spec.labels)
    }

    public func removeNetwork(id: String) async throws {
        _ = try await requestNoContent(.delete, path: "/networks/\(id)")
    }

    public func listVolumes() async throws -> [RuntimeVolume] {
        let response: APIVolumeListResponse = try await requestJSON(.get, path: "/volumes")
        return response.volumes.map { RuntimeVolume(name: $0.name, driver: $0.driver, labels: $0.labels, createdAt: $0.createdAt) }
    }

    public func createVolume(spec: RuntimeCreateVolumeSpec) async throws -> RuntimeVolume {
        let body = APICreateVolumeRequest(name: spec.name, driver: spec.driver, labels: spec.labels)
        let response: APIVolumeSummary = try await requestJSON(.post, path: "/volumes", body: body)
        return RuntimeVolume(name: response.name, driver: response.driver, labels: response.labels, createdAt: response.createdAt)
    }

    public func removeVolume(name: String) async throws {
        _ = try await requestNoContent(.delete, path: "/volumes/\(name)")
    }

    public func listSecrets() async throws -> [RuntimeSecret] {
        let response: [APISecretSummary] = try await requestJSON(.get, path: "/secrets")
        return response.map { RuntimeSecret(name: $0.name, labels: $0.labels, createdAt: $0.createdAt) }
    }

    public func createSecret(spec: RuntimeCreateSecretSpec) async throws -> RuntimeSecret {
        let body = APICreateSecretRequest(name: spec.name, value: spec.value, labels: spec.labels)
        let response: APICreateSecretResponse = try await requestJSON(.post, path: "/secrets", body: body)
        return RuntimeSecret(name: response.name, labels: spec.labels)
    }

    public func removeSecret(name: String) async throws {
        _ = try await requestNoContent(.delete, path: "/secrets/\(name)")
    }

    public func buildProject(
        name: String,
        services: [String],
        noCache: Bool,
        pull: Bool
    ) async throws -> AsyncStream<APIProjectBuildFrame> {
        let body = APIProjectBuildRequest(
            services: services.isEmpty ? nil : services,
            noCache: noCache,
            pull: pull
        )
        let frames = try await requestNDJSON(.post, path: "/projects/\(name)/build", body: body)
        return AsyncStream { continuation in
            for frame in frames.compactMap(Self.decodeBuildFrame(_:)) {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    public func pullProject(
        name: String,
        services: [String],
        ignoreFailures: Bool
    ) async throws -> AsyncStream<APIProjectPullFrame> {
        let body = APIProjectPullRequest(
            services: services.isEmpty ? nil : services,
            ignoreFailures: ignoreFailures
        )
        let frames = try await requestNDJSON(.post, path: "/projects/\(name)/pull", body: body)
        return AsyncStream { continuation in
            for frame in frames.compactMap(Self.decodePullFrame(_:)) {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    public func exec(id: String, command: [String], options: RuntimeExecOptions) async throws -> RuntimeExecResult {
        let body = APIExecRequest(
            command: command,
            detach: options.detach,
            interactive: options.interactive,
            tty: options.tty,
            environment: options.environment,
            user: options.user,
            workingDirectory: options.workingDirectory
        )
        let response: APIExecResponse = try await requestJSON(.post, path: "/containers/\(id)/exec", body: body)
        return RuntimeExecResult(stdout: response.stdout, stderr: response.stderr, exitCode: response.exitCode)
    }

    public func processes(id: String) async throws -> RuntimeProcessList {
        let response: APIProcessListResponse = try await requestJSON(.get, path: "/containers/\(id)/top")
        return RuntimeProcessList(containerId: response.containerId, output: response.output)
    }

    public func pushImage(reference: String) async throws -> RuntimeImagePushResult {
        let body = APIImagePushRequest(image: reference)
        let response: APIImagePushResponse = try await requestJSON(.post, path: "/images/push", body: body)
        return RuntimeImagePushResult(
            imageReference: response.image,
            stdout: response.stdout,
            stderr: response.stderr,
            exitCode: response.exitCode
        )
    }

    // MARK: - Request helpers

    private enum Method {
        case get, post, delete
    }

    private func requestJSON<T: Decodable>(
        _ method: Method,
        path: String,
        query: [String: String]? = nil,
        body: Encodable? = nil
    ) async throws -> T {
        let (client, eventLoopGroup) = try makeClient()
        defer {
            Task {
                try? await client.shutdown()
                DispatchQueue.global().async { try? eventLoopGroup.syncShutdownGracefully() }
            }
        }

        let request = try makeRequest(method: method, path: path, query: query, body: body)
        let response = try await client.execute(request, timeout: .seconds(30))
        let bodyBuffer = try await response.body.collect(upTo: 10 * 1024 * 1024)
        let data = Data(bodyBuffer.readableBytesView)
        try validate(response.status.code, body: data)
        return try Self.jsonDecoder.decode(T.self, from: data)
    }

    private func requestNoContent(
        _ method: Method,
        path: String,
        query: [String: String]? = nil,
        body: Encodable? = nil
    ) async throws -> Void {
        let (client, eventLoopGroup) = try makeClient()
        defer {
            Task {
                try? await client.shutdown()
                DispatchQueue.global().async { try? eventLoopGroup.syncShutdownGracefully() }
            }
        }

        let request = try makeRequest(method: method, path: path, query: query, body: body)
        let response = try await client.execute(request, timeout: .seconds(30))
        try validate(response.status.code, body: nil)
    }

    private func requestNDJSON(
        _ method: Method = .get,
        path: String,
        query: [String: String]? = nil,
        body: Encodable? = nil
    ) async throws -> [Data] {
        let (client, eventLoopGroup) = try makeClient()
        defer {
            Task {
                try? await client.shutdown()
                DispatchQueue.global().async { try? eventLoopGroup.syncShutdownGracefully() }
            }
        }

        let request = try makeRequest(method: method, path: path, query: query, body: body)
        let response = try await client.execute(request, timeout: .seconds(30))
        try validate(response.status.code, body: nil)

        var lines: [Data] = []
        var remainder = Data()
        for try await chunk in response.body {
            remainder.append(contentsOf: chunk.readableBytesView)
            while let newline = remainder.firstIndex(of: UInt8(0x0a)) {
                let line = remainder[..<newline]
                if !line.isEmpty {
                    lines.append(Data(line))
                }
                remainder = Data(remainder[remainder.index(after: newline)...])
            }
        }
        if !remainder.isEmpty {
            lines.append(remainder)
        }
        return lines
    }

    private func makeRequest(
        method: Method,
        path: String,
        query: [String: String]?,
        body: Encodable?
    ) throws -> HTTPClientRequest {
        let url = try makeURL(path: path, query: query)
        var request = HTTPClientRequest(url: url)
        switch method {
        case .get: request.method = .GET
        case .post: request.method = .POST
        case .delete: request.method = .DELETE
        }
        request.headers.add(name: "Accept", value: "application/json")
        if let token = configuration.token {
            request.headers.add(name: "Authorization", value: "Bearer \(token)")
        }
        if let body {
            let data = try Self.jsonEncoder.encode(AnyEncodable(body))
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(data: data))
        }
        return request
    }

    private func makeURL(path: String, query: [String: String]?) throws -> String {
        let rawPath: String
        if let query, !query.isEmpty {
            let pairs = query
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
                .joined(separator: "&")
            rawPath = "\(path)?\(pairs)"
        } else {
            rawPath = path
        }

        switch configuration.address {
        case .unix(let socket):
            guard let url = URL(httpURLWithSocketPath: socket, uri: rawPath) else {
                throw RuntimeError.backendFailure(message: "invalid unix socket URL for \(socket)")
            }
            return url.absoluteString
        case .tcp(let host, let port):
            return "http://\(host):\(port)\(rawPath)"
        case .tls(let host, let port):
            return "https://\(host):\(port)\(rawPath)"
        }
    }

    private func makeClient() throws -> (HTTPClient, MultiThreadedEventLoopGroup) {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let config = HTTPClient.Configuration(tlsConfiguration: try tlsConfiguration())
        let client = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup), configuration: config)
        return (client, eventLoopGroup)
    }

    private func tlsConfiguration() throws -> TLSConfiguration? {
        guard configuration.address.requiresTLS else {
            return nil
        }

        var tlsConfig = TLSConfiguration.makeClientConfiguration()

        if let certPath = configuration.certPath, let keyPath = configuration.keyPath {
            let certs = try NIOSSLCertificate.fromPEMFile(certPath)
            let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
            tlsConfig.certificateChain = certs.map { .certificate($0) }
            tlsConfig.privateKey = .privateKey(key)
        }

        let trustPath: String?
        if let explicit = configuration.cacertPath {
            trustPath = explicit
        } else if configuration.address.isLocalhost, FileManager.default.fileExists(atPath: ServeDaemon.defaultTLSCertPath) {
            trustPath = ServeDaemon.defaultTLSCertPath
        } else {
            trustPath = nil
        }

        if let trustPath, let caCerts = try? NIOSSLCertificate.fromPEMFile(trustPath) {
            tlsConfig.additionalTrustRoots = [.certificates(caCerts)]
        }

        return tlsConfig
    }

    private func validate(_ statusCode: UInt, body: Data?) throws {
        switch statusCode {
        case 200, 201, 204:
            return
        case 404:
            throw RuntimeError.notFound(id: "remote")
        case 409:
            throw RuntimeError.alreadyExists(id: "remote")
        case 501:
            throw RuntimeError.notSupported(operation: "remote", conformer: "RemoteRuntime")
        default:
            if let body, let envelope = try? Self.jsonDecoder.decode(APIErrorEnvelope.self, from: body) {
                throw RuntimeError.backendFailure(message: envelope.message)
            }
            throw RuntimeError.backendFailure(message: "remote runtime returned HTTP \(statusCode)")
        }
    }

    private static func toRuntimeContainer(summary: APIContainerSummary) -> RuntimeContainer {
        RuntimeContainer(
            id: summary.id,
            imageReference: summary.image,
            status: RuntimeContainerStatus(rawValue: summary.state) ?? .unknown,
            publishedPorts: summary.ports.map {
                RuntimePublishedPort(
                    hostAddress: $0.ip ?? "0.0.0.0",
                    hostPort: UInt16($0.publicPort ?? 0),
                    containerPort: UInt16($0.privatePort),
                    proto: RuntimePortProtocol(rawValue: $0.proto) ?? .tcp
                )
            },
            createdAt: summary.createdAt,
            startedAt: summary.startedAt,
            lastExitCode: nil
        )
    }

    private static func toRuntimeContainer(inspect: APIContainerInspect) -> RuntimeContainer {
        RuntimeContainer(
            id: inspect.id,
            imageReference: inspect.image,
            status: RuntimeContainerStatus(rawValue: inspect.state.status) ?? .unknown,
            publishedPorts: inspect.networkSettings.ports.map {
                RuntimePublishedPort(
                    hostAddress: $0.ip ?? "0.0.0.0",
                    hostPort: UInt16($0.publicPort ?? 0),
                    containerPort: UInt16($0.privatePort),
                    proto: RuntimePortProtocol(rawValue: $0.proto) ?? .tcp
                )
            },
            createdAt: inspect.created,
            startedAt: inspect.state.startedAt,
            lastExitCode: inspect.state.exitCode
        )
    }

    private static func toRuntimeNetwork(summary: APINetworkSummary) -> RuntimeNetwork {
        RuntimeNetwork(
            id: summary.id,
            name: summary.name,
            driver: summary.driver,
            subnet: nil,
            gateway: nil,
            labels: summary.labels,
            attachedContainerIds: Array(summary.containers.keys)
        )
    }

    private func filtersQuery(_ filters: RuntimeListFilters) -> [String: String] {
        var query: [String: String] = [:]
        if let status = filters.status, !status.isEmpty {
            query["status"] = status.map(\.rawValue).joined(separator: ",")
        }
        if let prefix = filters.namePrefix, !prefix.isEmpty {
            query["name"] = prefix
        }
        return query
    }

    private func logsQuery(_ options: RuntimeLogOptions) -> [String: String] {
        var query: [String: String] = [
            "follow": options.follow ? "true" : "false",
            "timestamps": options.timestamps ? "true" : "false",
        ]
        if let tail = options.tail {
            query["tail"] = String(tail)
        }
        if let since = options.since {
            query["since"] = ISO8601DateFormatter().string(from: since)
        }
        return query
    }

    private static func decodeLogFrame(_ data: Data) -> RuntimeLogFrame? {
        guard let frame = try? Self.jsonDecoder.decode(APILogFrame.self, from: data) else {
            return nil
        }
        return RuntimeLogFrame(
            timestamp: frame.timestamp,
            source: frame.stream == "stderr" ? .stderr : .stdout,
            data: Data(frame.line.utf8)
        )
    }

    private static func decodeEvent(_ data: Data) -> RuntimeContainerEvent? {
        guard let frame = try? Self.jsonDecoder.decode(APIEventFrame.self, from: data) else {
            return nil
        }
        switch frame.type {
        case "created":
            return .created(id: frame.id, at: frame.timestamp)
        case "started":
            return .started(id: frame.id, at: frame.timestamp)
        case "stopped":
            return .stopped(id: frame.id, exitCode: frame.exitCode ?? 0, at: frame.timestamp)
        case "killed":
            return .killed(id: frame.id, signal: frame.signal ?? 9, at: frame.timestamp)
        case "oomKilled":
            return .oomKilled(id: frame.id, at: frame.timestamp)
        case "removed":
            return .removed(id: frame.id, at: frame.timestamp)
        default:
            return nil
        }
    }

    private static func decodeBuildFrame(_ data: Data) -> APIProjectBuildFrame? {
        try? Self.jsonDecoder.decode(APIProjectBuildFrame.self, from: data)
    }

    private static func decodePullFrame(_ data: Data) -> APIProjectPullFrame? {
        try? Self.jsonDecoder.decode(APIProjectPullFrame.self, from: data)
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        self.encodeImpl = wrapped.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}
