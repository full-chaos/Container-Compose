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

/// Tests for Phase 3C: service.logging → --log-driver / --log-opt flags.
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

    @Test("logging with driver only emits --log-driver flag")
    func driverOnlyEmitsLogDriver() throws {
        let logging = Logging(driver: "json-file", options: nil)
        let svc = Service(image: "alpine", logging: logging)
        let result = try args(svc)
        #expect(result.contains("--log-driver"))
        let idx = result.firstIndex(of: "--log-driver")
        #expect(idx != nil)
        if let i = idx {
            #expect(result[result.index(after: i)] == "json-file")
        }
        #expect(!result.contains("--log-opt"))
    }

    // MARK: - driver + options

    @Test("logging with driver and options emits --log-driver and sorted --log-opt flags")
    func driverAndOptionsEmitsBothFlags() throws {
        let logging = Logging(
            driver: "syslog",
            options: ["syslog-address": "tcp://192.168.0.1:514", "max-size": "10m"]
        )
        let svc = Service(image: "alpine", logging: logging)
        let result = try args(svc)

        // --log-driver present with correct value
        #expect(result.contains("--log-driver"))
        let driverIdx = result.firstIndex(of: "--log-driver")
        #expect(driverIdx != nil)
        if let i = driverIdx {
            #expect(result[result.index(after: i)] == "syslog")
        }

        // --log-opt present for both options; options sorted by key
        // sorted keys: "max-size" < "syslog-address"
        let optIndices = result.indices.filter { result[$0] == "--log-opt" }
        #expect(optIndices.count == 2)
        if optIndices.count == 2 {
            let firstOptValue = result[result.index(after: optIndices[0])]
            let secondOptValue = result[result.index(after: optIndices[1])]
            #expect(firstOptValue == "max-size=10m")
            #expect(secondOptValue == "syslog-address=tcp://192.168.0.1:514")
        }
    }

    // MARK: - options only (no driver)

    @Test("logging with options only (no driver) emits only --log-opt flags")
    func optionsOnlyEmitsLogOptOnly() throws {
        let logging = Logging(driver: nil, options: ["tag": "myservice"])
        let svc = Service(image: "alpine", logging: logging)
        let result = try args(svc)
        #expect(!result.contains("--log-driver"))
        #expect(result.contains("--log-opt"))
        let idx = result.firstIndex(of: "--log-opt")
        #expect(idx != nil)
        if let i = idx {
            #expect(result[result.index(after: i)] == "tag=myservice")
        }
    }

    // MARK: - multiple options sorted

    @Test("multiple log options are emitted in sorted key order")
    func multipleOptionsSorted() throws {
        let logging = Logging(
            driver: "json-file",
            options: ["max-file": "3", "compress": "true", "max-size": "10m"]
        )
        let svc = Service(image: "alpine", logging: logging)
        let result = try args(svc)

        // sorted keys: "compress" < "max-file" < "max-size"
        let optIndices = result.indices.filter { result[$0] == "--log-opt" }
        #expect(optIndices.count == 3)
        if optIndices.count == 3 {
            #expect(result[result.index(after: optIndices[0])] == "compress=true")
            #expect(result[result.index(after: optIndices[1])] == "max-file=3")
            #expect(result[result.index(after: optIndices[2])] == "max-size=10m")
        }
    }

    // MARK: - Regression: existing LifecycleArgs flags still work alongside logging

    @Test("init_ and logging emitted together without interference")
    func initAndLoggingRegression() throws {
        let logging = Logging(driver: "none", options: nil)
        let svc = Service(image: "alpine", init_: true, logging: logging)
        let result = try args(svc)
        #expect(result.contains("--init"))
        #expect(result.contains("--log-driver"))
        let idx = result.firstIndex(of: "--log-driver")
        if let i = idx {
            #expect(result[result.index(after: i)] == "none")
        }
    }

    @Test("stop_signal and logging emitted together without interference")
    func stopSignalAndLoggingRegression() throws {
        let logging = Logging(driver: "local", options: nil)
        let svc = Service(image: "alpine", stop_signal: "SIGTERM", logging: logging)
        let result = try args(svc)
        #expect(result.contains("--stop-signal"))
        #expect(result.contains("--log-driver"))
        let stopIdx = result.firstIndex(of: "--stop-signal")
        if let i = stopIdx {
            #expect(result[result.index(after: i)] == "SIGTERM")
        }
        let driverIdx = result.firstIndex(of: "--log-driver")
        if let i = driverIdx {
            #expect(result[result.index(after: i)] == "local")
        }
    }

    @Test("runtime and logging emitted together without interference")
    func runtimeAndLoggingRegression() throws {
        let logging = Logging(driver: "splunk", options: ["splunk-token": "abc"])
        let svc = Service(image: "alpine", runtime: "nvidia", logging: logging)
        let result = try args(svc)
        #expect(result.contains("--runtime"))
        #expect(result.contains("--log-driver"))
        #expect(result.contains("--log-opt"))
        let runtimeIdx = result.firstIndex(of: "--runtime")
        if let i = runtimeIdx {
            #expect(result[result.index(after: i)] == "nvidia")
        }
    }
}
