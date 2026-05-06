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

import Foundation

// MARK: - Pull (CHAOS-1425, Leak #14)

/// Per-image input to `Runtime.pull(specs:ignoreFailures:)`. Carries the
/// service label that owns the image (so the route layer can attribute frames
/// back to a specific service), the image reference itself, and an optional
/// platform string. The platform mirrors the existing `pullImage()` helper's
/// `--platform` argument; nil falls back to `defaultRuntimePlatform()` inside
/// the conformer.
public struct RuntimePullSpec: Sendable, Hashable {
    public let service: String
    public let imageReference: String
    public let platform: String?

    public init(service: String, imageReference: String, platform: String? = nil) {
        self.service = service
        self.imageReference = imageReference
        self.platform = platform
    }
}

/// One frame emitted by `Runtime.pull(...)`. Coarse-grained — one `started`
/// and one `completed` (or `failed`) per spec — because the upstream
/// `ImagePull` is invoked via the in-process `.swiftAPI` seam and prints its
/// per-blob progress directly to host stdout (`ProgressBar`), bypassing
/// `RunCommandRunner`'s onStdout callback. Per-line progress is a CHAOS-1425
/// follow-up: it requires either bypassing `RunCommandRunner` to call
/// `ClientImage.pull(progressUpdate:)` directly, or capturing host stdout
/// while the in-process command runs. Neither is in scope for this PR.
public struct RuntimePullEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case started
        case completed
        case failed
    }
    public let timestamp: Date
    public let service: String
    public let imageReference: String
    public let kind: Kind
    /// Optional message — populated on `failed` (the error description) and
    /// nil-able on success frames for forward-compat extension.
    public let message: String?

    public init(
        timestamp: Date,
        service: String,
        imageReference: String,
        kind: Kind,
        message: String? = nil
    ) {
        self.timestamp = timestamp
        self.service = service
        self.imageReference = imageReference
        self.kind = kind
        self.message = message
    }
}
