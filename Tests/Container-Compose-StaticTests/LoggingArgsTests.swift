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

import Testing
import Foundation
@testable import Yams
@testable import ContainerComposeCore

/// Tests for service.logging parse support without unsupported runtime flags.
@Suite("Logging Args Tests")
struct LoggingArgsTests {

    // MARK: - Helpers

    private func minimalDockerCompose() throws -> DockerCompose {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        return try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    private func ctx(_ service: Service) throws -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "proj",
            containerName: "proj-svc",
            detach: false,
            environmentVariables: [:],
            dockerCompose: try minimalDockerCompose(),
            composeFilename: nil
        )
    }

    private func args(_ service: Service) throws -> [String] {
        ComposeUp.LifecycleArgs.build(try ctx(service))
    }

    // MARK: - nil logging

    @Test("nil logging emits no --log-driver or --log-opt flags")
    func nilLoggingEmitsNoFlags() throws {
        let svc = Service(image: "alpine", logging: nil)
        let result = try args(svc)
        #expect(!result.contains("--log-driver"))
        #expect(!result.contains("--log-opt"))
    }

    // MARK: - driver only

    @Test("logging with driver only emits no unsupported log flags")
    func driverOnlyEmitsNoUnsupportedLogFlags() throws {
        let logging = Logging(driver: "json-file", options: nil)
        let svc = Service(image: "alpine", logging: logging)
        let result = try args(svc)
        #expect(!result.contains("--log-driver"))
        #expect(!result.contains("--log-opt"))
    }

    // MARK: - driver + options

    @Test("logging with driver and options emits no unsupported log flags")
    func driverAndOptionsEmitsNoUnsupportedLogFlags() throws {
        let logging = Logging(
            driver: "syslog",
            options: ["syslog-address": "tcp://192.168.0.1:514", "max-size": "10m"]
        )
        let svc = Service(image: "alpine", logging: logging)
        let result = try args(svc)
        #expect(!result.contains("--log-driver"))
        #expect(!result.contains("--log-opt"))
    }

    // MARK: - options only (no driver)

    @Test("logging with options only emits no unsupported log flags")
    func optionsOnlyEmitsNoUnsupportedLogFlags() throws {
        let logging = Logging(driver: nil, options: ["tag": "myservice"])
        let svc = Service(image: "alpine", logging: logging)
        let result = try args(svc)
        #expect(!result.contains("--log-driver"))
        #expect(!result.contains("--log-opt"))
    }

    // MARK: - multiple options sorted

    @Test("multiple log options emit no unsupported log flags")
    func multipleOptionsEmitNoUnsupportedLogFlags() throws {
        let logging = Logging(
            driver: "json-file",
            options: ["max-file": "3", "compress": "true", "max-size": "10m"]
        )
        let svc = Service(image: "alpine", logging: logging)
        let result = try args(svc)
        #expect(!result.contains("--log-driver"))
        #expect(!result.contains("--log-opt"))
    }

    // MARK: - Regression: existing LifecycleArgs flags still work alongside logging

    @Test("init_ and logging parse together without unsupported log flags")
    func initAndLoggingRegression() throws {
        let logging = Logging(driver: "none", options: nil)
        let svc = Service(image: "alpine", init_: true, logging: logging)
        let result = try args(svc)
        #expect(result.contains("--init"))
        #expect(!result.contains("--log-driver"))
        #expect(!result.contains("--log-opt"))
    }

    @Test("stop_signal and logging parse together without unsupported log flags")
    func stopSignalAndLoggingRegression() throws {
        let logging = Logging(driver: "local", options: nil)
        let svc = Service(image: "alpine", stop_signal: "SIGTERM", logging: logging)
        let result = try args(svc)
        // CHAOS-1397 Tier 0 R2: --stop-signal is warn-skipped (apple/container
        // does not accept it). --log-driver/--log-opt remain unsupported on
        // `container run` and stay absent. The test's spirit — "these fields
        // parse together without producing forbidden flags" — is unchanged.
        #expect(!result.contains("--stop-signal"))
        #expect(!result.contains("SIGTERM"))
        #expect(!result.contains("--log-driver"))
        #expect(!result.contains("--log-opt"))
    }

    @Test("runtime and logging parse together without unsupported log flags")
    func runtimeAndLoggingRegression() throws {
        let logging = Logging(driver: "splunk", options: ["splunk-token": "abc"])
        let svc = Service(image: "alpine", runtime: "nvidia", logging: logging)
        let result = try args(svc)
        #expect(result.contains("--runtime"))
        #expect(!result.contains("--log-driver"))
        #expect(!result.contains("--log-opt"))
        let runtimeIdx = result.firstIndex(of: "--runtime")
        if let i = runtimeIdx {
            #expect(result[result.index(after: i)] == "nvidia")
        }
    }
}
