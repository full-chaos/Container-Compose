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
@testable import ContainerComposeCore

@Suite("ComposeRun and ComposeExec Parsing Tests")
struct ComposeRunExecTests {

    // MARK: - ComposeRun

    @Test("ComposeRun parses with just a service name")
    func composeRunParsesServiceName() throws {
        let cmd = try ComposeRun.parse(["web"])
        #expect(cmd.serviceName == "web")
        #expect(cmd.command.isEmpty)
        #expect(cmd.detach == false)
        #expect(cmd.rm == false)
        #expect(cmd.servicePorts == false)
        #expect(cmd.environment.isEmpty)
        #expect(cmd.volumes.isEmpty)
        #expect(cmd.user == nil)
        #expect(cmd.name == nil)
        #expect(cmd.composeFilename == nil)
        #expect(cmd.profile.isEmpty)
    }

    @Test("ComposeRun parses service name with command passthrough")
    func composeRunParsesServiceNameAndCommand() throws {
        let cmd = try ComposeRun.parse(["web", "--", "ls", "-la"])
        #expect(cmd.serviceName == "web")
        // captureForPassthrough includes the "--" separator
        #expect(cmd.command == ["--", "ls", "-la"])
    }

    @Test("ComposeRun parses --detach flag")
    func composeRunParsesDetach() throws {
        let cmd = try ComposeRun.parse(["--detach", "web"])
        #expect(cmd.detach == true)
    }

    @Test("ComposeRun parses --rm flag")
    func composeRunParsesRm() throws {
        let cmd = try ComposeRun.parse(["--rm", "web"])
        #expect(cmd.rm == true)
    }

    @Test("ComposeRun parses --service-ports flag")
    func composeRunParsesServicePorts() throws {
        let cmd = try ComposeRun.parse(["--service-ports", "web"])
        #expect(cmd.servicePorts == true)
    }

    @Test("ComposeRun parses --run-env single")
    func composeRunParsesEnvSingle() throws {
        let cmd = try ComposeRun.parse(["--run-env", "DEBUG=true", "web"])
        #expect(cmd.environment == ["DEBUG=true"])
    }

    @Test("ComposeRun parses --run-env multiple")
    func composeRunParsesEnvMultiple() throws {
        let cmd = try ComposeRun.parse(["--run-env", "FOO=bar", "--run-env", "BAZ=qux", "web"])
        #expect(cmd.environment == ["FOO=bar", "BAZ=qux"])
    }

    @Test("ComposeRun parses --run-user flag")
    func composeRunParsesUser() throws {
        let cmd = try ComposeRun.parse(["--run-user", "nobody", "web"])
        #expect(cmd.user == "nobody")
    }

    @Test("ComposeRun parses --name override")
    func composeRunParsesNameOverride() throws {
        let cmd = try ComposeRun.parse(["--name", "my-one-off", "web"])
        #expect(cmd.name == "my-one-off")
    }

    @Test("ComposeRun parses --run-volume single")
    func composeRunParsesVolumeSingle() throws {
        let cmd = try ComposeRun.parse(["--run-volume", "/tmp/data:/data", "web"])
        #expect(cmd.volumes == ["/tmp/data:/data"])
    }

    @Test("ComposeRun parses --run-volume multiple")
    func composeRunParsesVolumeMultiple() throws {
        let cmd = try ComposeRun.parse(["--run-volume", "/tmp/a:/a", "--run-volume", "/tmp/b:/b", "web"])
        #expect(cmd.volumes == ["/tmp/a:/a", "/tmp/b:/b"])
    }

    @Test("ComposeRun parses -f / --file flag")
    func composeRunParsesFile() throws {
        let cmd = try ComposeRun.parse(["-f", "custom-compose.yml", "web"])
        #expect(cmd.composeFilename == "custom-compose.yml")
    }

    @Test("ComposeRun parses --profile flag")
    func composeRunParsesProfile() throws {
        let cmd = try ComposeRun.parse(["--profile", "dev", "web"])
        #expect(cmd.profile == ["dev"])
    }

    @Test("ComposeRun service-ports defaults to false")
    func composeRunServicePortsDefaultFalse() throws {
        let cmd = try ComposeRun.parse(["web"])
        #expect(cmd.servicePorts == false)
    }

    // MARK: - ComposeExec

    @Test("ComposeExec parses service name and command")
    func composeExecParsesServiceAndCommand() throws {
        let cmd = try ComposeExec.parse(["web", "--", "ls", "-la"])
        #expect(cmd.serviceName == "web")
        // captureForPassthrough includes the "--" separator
        #expect(cmd.command == ["--", "ls", "-la"])
    }

    @Test("ComposeExec interactive and tty default to true (no flags set)")
    func composeExecDefaultsInteractiveAndTty() throws {
        let cmd = try ComposeExec.parse(["web", "--", "sh"])
        // interactive and tty default to true (noInteractive/noTty default false)
        #expect(cmd.interactive == true)
        #expect(cmd.tty == true)
    }

    @Test("ComposeExec --no-exec-interactive disables interactive")
    func composeExecNoInteractive() throws {
        let cmd = try ComposeExec.parse(["--no-exec-interactive", "web", "--", "sh"])
        #expect(cmd.interactive == false)
    }

    @Test("ComposeExec --no-exec-tty disables tty")
    func composeExecNoTty() throws {
        let cmd = try ComposeExec.parse(["--no-exec-tty", "web", "--", "sh"])
        #expect(cmd.tty == false)
    }

    @Test("ComposeExec parses --exec-detach flag")
    func composeExecParsesDetach() throws {
        let cmd = try ComposeExec.parse(["--exec-detach", "web", "--", "sh"])
        #expect(cmd.detach == true)
    }

    @Test("ComposeExec parses --exec-user flag")
    func composeExecParsesUser() throws {
        let cmd = try ComposeExec.parse(["--exec-user", "root", "web", "--", "sh"])
        #expect(cmd.user == "root")
    }

    @Test("ComposeExec parses --exec-workdir flag")
    func composeExecParsesWorkdir() throws {
        let cmd = try ComposeExec.parse(["--exec-workdir", "/app", "web", "--", "sh"])
        #expect(cmd.workdir == "/app")
    }

    @Test("ComposeExec parses --exec-env flag")
    func composeExecParsesEnv() throws {
        let cmd = try ComposeExec.parse(["--exec-env", "NODE_ENV=production", "web", "--", "node", "app.js"])
        #expect(cmd.environment == ["NODE_ENV=production"])
    }

    @Test("ComposeExec parses multiple --exec-env flags")
    func composeExecParsesEnvMultiple() throws {
        let cmd = try ComposeExec.parse(["--exec-env", "FOO=1", "--exec-env", "BAR=2", "web", "--", "sh"])
        #expect(cmd.environment == ["FOO=1", "BAR=2"])
    }

    @Test("ComposeExec parses -f / --file flag")
    func composeExecParsesFile() throws {
        let cmd = try ComposeExec.parse(["-f", "prod.yml", "web", "--", "sh"])
        #expect(cmd.composeFilename == "prod.yml")
    }

    @Test("ComposeExec detach defaults to false")
    func composeExecDetachDefaultFalse() throws {
        let cmd = try ComposeExec.parse(["web", "--", "sh"])
        #expect(cmd.detach == false)
    }
}
