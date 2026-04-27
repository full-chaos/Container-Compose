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

/// Tests for Phase 2E: LifecycleArgs.build and the parseGoDuration helper.
@Suite("LifecycleArgs Tests")
struct LifecycleArgsTests {

    // MARK: - Helpers

    private func makeDockerCompose() -> DockerCompose {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        return try! YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    /// Build a minimal ArgsContext for LifecycleArgs.build calls.
    private func makeContext(service: Service, detach: Bool = false) -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "proj",
            containerName: "proj-svc",
            detach: detach,
            environmentVariables: [:],
            dockerCompose: makeDockerCompose(),
            composeFilename: nil
        )
    }

    // MARK: - init_ flag

    @Test("init_ true emits --init flag")
    func initTrueEmitsFlag() {
        let svc = Service(image: "alpine", init_: true)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("--init"))
    }

    @Test("init_ nil does not emit --init flag")
    func initNilAbsent() {
        let svc = Service(image: "alpine", init_: nil)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--init"))
    }

    @Test("init_ false does not emit --init flag")
    func initFalseAbsent() {
        let svc = Service(image: "alpine", init_: false)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--init"))
    }

    // MARK: - stop_signal

    @Test("stop_signal emits --stop-signal with value")
    func stopSignalEmits() {
        let svc = Service(image: "alpine", stop_signal: "SIGUSR1")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("--stop-signal"))
        let idx = args.firstIndex(of: "--stop-signal")
        #expect(idx != nil)
        if let i = idx {
            #expect(args[args.index(after: i)] == "SIGUSR1")
        }
    }

    @Test("stop_signal nil means --stop-signal absent")
    func stopSignalNilAbsent() {
        let svc = Service(image: "alpine", stop_signal: nil)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--stop-signal"))
    }

    // MARK: - stop_grace_period / parseGoDuration

    @Test("parseGoDuration: 30s → 30")
    func parseDuration30s() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("30s") == 30)
    }

    @Test("parseGoDuration: 1m → 60")
    func parseDuration1m() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("1m") == 60)
    }

    @Test("parseGoDuration: 1m30s → 90")
    func parseDuration1m30s() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("1m30s") == 90)
    }

    @Test("parseGoDuration: raw integer 5 → 5")
    func parseDurationRawInt() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("5") == 5)
    }

    @Test("parseGoDuration: unparseable 'abc' → nil")
    func parseDurationInvalidNil() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("abc") == nil)
    }

    @Test("parseGoDuration: 2h → 7200")
    func parseDuration2h() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("2h") == 7200)
    }

    @Test("parseGoDuration: 1h2m3s → 3723")
    func parseDurationFull() {
        #expect(ComposeUp.LifecycleArgs.parseGoDuration("1h2m3s") == 3723)
    }

    @Test("stop_grace_period 30s emits --stop-timeout 30")
    func stopGracePeriodEmits() {
        let svc = Service(image: "alpine", stop_grace_period: "30s")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("--stop-timeout"))
        let idx = args.firstIndex(of: "--stop-timeout")
        #expect(idx != nil)
        if let i = idx {
            #expect(args[args.index(after: i)] == "30")
        }
    }

    @Test("stop_grace_period 1m30s emits --stop-timeout 90")
    func stopGracePeriod1m30s() {
        let svc = Service(image: "alpine", stop_grace_period: "1m30s")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        let idx = args.firstIndex(of: "--stop-timeout")
        #expect(idx != nil)
        if let i = idx {
            #expect(args[args.index(after: i)] == "90")
        }
    }

    @Test("stop_grace_period unparseable means --stop-timeout absent")
    func stopGracePeriodBadValueAbsent() {
        let svc = Service(image: "alpine", stop_grace_period: "abc")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--stop-timeout"))
    }

    @Test("stop_grace_period raw integer 5 emits --stop-timeout 5")
    func stopGracePeriodRawInt() {
        let svc = Service(image: "alpine", stop_grace_period: "5")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        let idx = args.firstIndex(of: "--stop-timeout")
        #expect(idx != nil)
        if let i = idx {
            #expect(args[args.index(after: i)] == "5")
        }
    }

    // MARK: - runtime

    @Test("runtime emits --runtime with value")
    func runtimeEmits() {
        let svc = Service(image: "alpine", runtime: "nvidia")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("--runtime"))
        let idx = args.firstIndex(of: "--runtime")
        #expect(idx != nil)
        if let i = idx {
            #expect(args[args.index(after: i)] == "nvidia")
        }
    }

    @Test("runtime nil means --runtime absent")
    func runtimeNilAbsent() {
        let svc = Service(image: "alpine", runtime: nil)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--runtime"))
    }

    // MARK: - restart: no --restart flag emitted

    @Test("restart present does not emit --restart flag")
    func restartNoFlag() {
        let svc = Service(image: "alpine", restart: "always")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(!args.contains("--restart"))
    }

    // MARK: - Regression: existing flags still emitted

    @Test("platform still emits --platform")
    func platformRegression() {
        let svc = Service(image: "alpine", platform: "linux/amd64")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("--platform"))
        let idx = args.firstIndex(of: "--platform")
        if let i = idx {
            #expect(args[args.index(after: i)] == "linux/amd64")
        }
    }

    @Test("detach still emits -d")
    func detachRegression() {
        let svc = Service(image: "alpine")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc, detach: true))
        #expect(args.contains("-d"))
    }

    @Test("name still emits --name with containerName")
    func nameRegression() {
        let svc = Service(image: "alpine")
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("--name"))
        let idx = args.firstIndex(of: "--name")
        if let i = idx {
            #expect(args[args.index(after: i)] == "proj-svc")
        }
    }

    @Test("stdin_open still emits -i")
    func stdinRegression() {
        let svc = Service(image: "alpine", stdin_open: true)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("-i"))
    }

    @Test("tty still emits -t")
    func ttyRegression() {
        let svc = Service(image: "alpine", tty: true)
        let args = ComposeUp.LifecycleArgs.build(makeContext(service: svc))
        #expect(args.contains("-t"))
    }
}
