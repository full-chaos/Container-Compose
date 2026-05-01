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
import os

/// Locked storage for `warnUnsupportedRuntimeFieldOnce`'s already-emitted
/// key set. The previous `nonisolated(unsafe) static var emittedKeys` raced
/// under Swift Testing's parallel runner: concurrent `Set.insert` calls
/// corrupted the `_Variant` storage, manifesting as
/// `-[NSIndirectTaggedPointerString member:]` crashes on x86_64/arm64
/// CI (Foundation set bridging meets a tagged-pointer string from the torn
/// hash buffer). `OSAllocatedUnfairLock<Set<String>>` keeps the de-dup
/// semantics, stays Sendable, and adds zero contention on the hot path
/// (insert is O(1); only the first occurrence per key acquires the lock
/// before printing).
private let unsupportedWarningsLock = OSAllocatedUnfairLock<Set<String>>(initialState: [])

func warnUnsupportedRuntimeFieldOnce(_ key: String, _ message: @autoclosure () -> String) {
    let inserted = unsupportedWarningsLock.withLock { keys -> Bool in
        keys.insert(key).inserted
    }
    guard inserted else { return }
    print(message())
}
