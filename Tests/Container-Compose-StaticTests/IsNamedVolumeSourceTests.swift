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

@Suite("isNamedVolumeSource helper")
struct IsNamedVolumeSourceTests {

    // MARK: - Bind-mount sources (should return false)

    @Test("Absolute path starting with / is a bind mount")
    func absolutePathIsBind() {
        #expect(isNamedVolumeSource("/host/data") == false)
    }

    @Test("Relative path starting with . is a bind mount")
    func dotRelativePathIsBind() {
        #expect(isNamedVolumeSource("./data") == false)
    }

    @Test("Relative path starting with .. is a bind mount")
    func dotDotRelativePathIsBind() {
        #expect(isNamedVolumeSource("../sibling/data") == false)
    }

    @Test("Source containing a mid-string slash is a bind mount")
    func midStringSlashIsBind() {
        #expect(isNamedVolumeSource("foo/bar") == false)
    }

    @Test("Tilde-expanded home path is a bind mount (contains no slash but starts like a path — actually contains /)")
    func homePathIsBind() {
        // ~/data contains no "/" before the ~, but after tilde expansion it does;
        // the raw string "~/data" contains "/" so the heuristic treats it as bind.
        #expect(isNamedVolumeSource("~/data") == false)
    }

    // MARK: - Named-volume sources (should return true)

    @Test("Plain volume name with no special characters is a named volume")
    func plainNameIsNamed() {
        #expect(isNamedVolumeSource("myvolume") == true)
    }

    @Test("Volume name with underscores and hyphens is a named volume")
    func dashedNameIsNamed() {
        #expect(isNamedVolumeSource("my-vol_data") == true)
    }

    @Test("Volume name with numbers is a named volume")
    func numberedNameIsNamed() {
        #expect(isNamedVolumeSource("db1") == true)
    }

    // MARK: - Edge cases

    @Test("Empty string is treated as a named volume (no path indicators present)")
    func emptyStringIsNamed() {
        // The heuristic only detects bind mounts positively; an empty source
        // passes through to the named-volume path where the runtime will reject it.
        #expect(isNamedVolumeSource("") == true)
    }
}
