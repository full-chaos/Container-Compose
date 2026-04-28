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

import Foundation

private enum UnsupportedRuntimeWarningState {
    nonisolated(unsafe) static var emittedKeys = Set<String>()
}

func warnUnsupportedRuntimeFieldOnce(_ key: String, _ message: @autoclosure () -> String) {
    guard UnsupportedRuntimeWarningState.emittedKeys.insert(key).inserted else { return }
    print(message())
}
