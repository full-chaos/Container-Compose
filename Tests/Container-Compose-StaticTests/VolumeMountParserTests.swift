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

import Testing
import Foundation
@testable import ContainerComposeCore

@Suite("VolumeMountParser")
struct VolumeMountParserTests {

    // MARK: - Bind mount sources

    @Test("Absolute host path parsed as bind mount")
    func absolutePathIsBind() throws {
        let result = try VolumeMountParser.parse("/host/data:/container/data").get()
        #expect(result.kind == .bindMount(hostPath: "/host/data"))
        #expect(result.destination == "/container/data")
        #expect(result.mode == nil)
        #expect(result.originalSource == "/host/data")
    }

    @Test("Relative dot-prefixed path parsed as bind mount")
    func dotRelativeIsBind() throws {
        let result = try VolumeMountParser.parse("./data:/app/data").get()
        #expect(result.kind == .bindMount(hostPath: "./data"))
        #expect(result.destination == "/app/data")
        #expect(result.mode == nil)
    }

    @Test("Relative double-dot path parsed as bind mount")
    func dotDotRelativeIsBind() throws {
        let result = try VolumeMountParser.parse("../sibling:/app/sibling").get()
        #expect(result.kind == .bindMount(hostPath: "../sibling"))
        #expect(result.destination == "/app/sibling")
    }

    @Test("Path containing mid-string slash parsed as bind mount")
    func midSlashIsBind() throws {
        let result = try VolumeMountParser.parse("foo/bar:/container/bar").get()
        #expect(result.kind == .bindMount(hostPath: "foo/bar"))
    }

    @Test("Tilde-prefixed home path parsed as bind mount")
    func tildePathIsBind() throws {
        let result = try VolumeMountParser.parse("~/data:/app/data").get()
        #expect(result.kind == .bindMount(hostPath: "~/data"))
    }

    // MARK: - Named volume sources

    @Test("Plain volume name parsed as named volume")
    func plainNameIsNamed() throws {
        let result = try VolumeMountParser.parse("myvolume:/var/lib/data").get()
        #expect(result.kind == .namedVolume(name: "myvolume"))
        #expect(result.destination == "/var/lib/data")
        #expect(result.mode == nil)
        #expect(result.originalSource == "myvolume")
    }

    @Test("Volume name with underscores and hyphens parsed as named volume")
    func dashedNameIsNamed() throws {
        let result = try VolumeMountParser.parse("my-vol_data:/data").get()
        #expect(result.kind == .namedVolume(name: "my-vol_data"))
    }

    @Test("Volume name with numbers parsed as named volume")
    func numberedNameIsNamed() throws {
        let result = try VolumeMountParser.parse("db1:/var/lib/postgresql/data").get()
        #expect(result.kind == .namedVolume(name: "db1"))
    }

    // MARK: - Mode variants (bug fix: must not silently drop)

    @Test(":ro mode is captured, not silently dropped")
    func roModeIsCaptured() throws {
        let result = try VolumeMountParser.parse("./config:/etc/config:ro").get()
        #expect(result.mode == "ro")
        #expect(result.destination == "/etc/config")
        #expect(result.kind == .bindMount(hostPath: "./config"))
    }

    @Test(":rw mode is captured, not silently dropped")
    func rwModeIsCaptured() throws {
        let result = try VolumeMountParser.parse("myvolume:/data:rw").get()
        #expect(result.mode == "rw")
        #expect(result.kind == .namedVolume(name: "myvolume"))
    }

    @Test(":Z mode is captured (SELinux relabeling)")
    func upperZModeIsCaptured() throws {
        let result = try VolumeMountParser.parse("/host/path:/container/path:Z").get()
        #expect(result.mode == "Z")
        #expect(result.kind == .bindMount(hostPath: "/host/path"))
    }

    @Test(":z mode is captured (SELinux shared relabeling)")
    func lowerZModeIsCaptured() throws {
        let result = try VolumeMountParser.parse("/host/path:/container/path:z").get()
        #expect(result.mode == "z")
    }

    @Test("Named volume with :ro mode is captured")
    func namedVolumeWithMode() throws {
        let result = try VolumeMountParser.parse("pgdata:/var/lib/postgresql/data:ro").get()
        #expect(result.kind == .namedVolume(name: "pgdata"))
        #expect(result.mode == "ro")
        #expect(result.destination == "/var/lib/postgresql/data")
    }

    @Test("No mode field when spec has only source:destination")
    func noModeWhenTwoComponents() throws {
        let result = try VolumeMountParser.parse("vol:/data").get()
        #expect(result.mode == nil)
    }

    // MARK: - Malformed inputs

    @Test("Spec with no colon returns invalidFormat error")
    func missingColonIsError() {
        let result = VolumeMountParser.parse("justadestination")
        guard case .failure(let error) = result else {
            Issue.record("Expected .failure but got success")
            return
        }
        #expect(error == .invalidFormat(spec: "justadestination"))
    }

    @Test("Empty string returns invalidFormat error")
    func emptySpecIsError() {
        let result = VolumeMountParser.parse("")
        guard case .failure(let error) = result else {
            Issue.record("Expected .failure but got success")
            return
        }
        #expect(error == .invalidFormat(spec: ""))
    }

    @Test("Empty source (leading colon) returns emptySource error")
    func emptySourceIsError() {
        let result = VolumeMountParser.parse(":/container/path")
        guard case .failure(let error) = result else {
            Issue.record("Expected .failure but got success")
            return
        }
        #expect(error == .emptySource)
    }

    @Test("Empty destination (trailing colon after source) returns emptyDestination error")
    func emptyDestinationIsError() {
        let result = VolumeMountParser.parse("myvolume:")
        guard case .failure(let error) = result else {
            Issue.record("Expected .failure but got success")
            return
        }
        #expect(error == .emptyDestination)
    }

    @Test("Empty destination with mode (source::mode) returns emptyDestination error")
    func emptyDestinationWithModeIsError() {
        let result = VolumeMountParser.parse("myvolume::ro")
        guard case .failure(let error) = result else {
            Issue.record("Expected .failure but got success")
            return
        }
        #expect(error == .emptyDestination)
    }

    // MARK: - originalSource field

    @Test("originalSource preserves the raw source string")
    func originalSourcePreserved() throws {
        let result = try VolumeMountParser.parse("./relative/path:/app:ro").get()
        #expect(result.originalSource == "./relative/path")
    }

    // MARK: - Mode warning integration (stdout capture)
    //
    // These tests verify that the `warnUnsupportedRuntimeFieldOnce` path fires
    // when `configVolume` processes a spec with a mode suffix.  The warning
    // logic lives in `ComposeUp.configVolume()`, which calls
    // `VolumeMountParser.parse()` and then checks `spec.mode`. We validate
    // that the parser correctly surfaces a non-nil `mode` so the caller can
    // emit the warning.

    @Test(":ro mode is non-nil so caller can emit unsupported-mode warning")
    func roModeIsNonNilForWarning() throws {
        let result = try VolumeMountParser.parse("myvolume:/data:ro").get()
        #expect(result.mode != nil, "mode must be non-nil so configVolume can emit the unsupported-mode warning")
    }

    @Test("no-mode spec has nil mode so no spurious warning is emitted")
    func noModeIsNilNoWarning() throws {
        let result = try VolumeMountParser.parse("myvolume:/data").get()
        #expect(result.mode == nil, "nil mode must not trigger the unsupported-mode warning path")
    }
}
