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

import Rainbow
import Testing

@testable import ContainerComposeCore

@Suite("LoopState")
struct LoopStateTests {
    @Test("assignColor reuses colors after palette is exhausted")
    func assignColorReusesColorsAfterPaletteExhausted() async {
        let state = LoopState()
        let palette: Set<NamedColor> = [.red, .green]

        _ = await state.assignColor(for: "one", available: palette)
        _ = await state.assignColor(for: "two", available: palette)
        let third = await state.assignColor(for: "three", available: palette)

        #expect(palette.contains(third))
    }
}
