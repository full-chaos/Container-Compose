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

// MARK: - Build (CHAOS-1425, Leak #14)

/// Per-service input to `Runtime.build(specs:)`. The daemon's container
/// registry does not track Dockerfile paths or build-context directories — a
/// `BuildCommand` invocation needs both. CHAOS-1426 (compose-file upload via
/// daemon API) unblocked the bridge conformer; callers populate `projectName`
/// so the bridge can resolve build contexts from `ProjectRegistry`. When
/// `projectName` is nil the bridge falls back to `contextPath`/`dockerfile`
/// if those are already set, or emits `notSupported` per spec.
public struct RuntimeBuildSpec: Sendable, Hashable {
    public let service: String
    public let imageTag: String?
    public let contextPath: String?
    public let dockerfile: String?
    public let noCache: Bool
    public let pullBaseImages: Bool
    /// The registered project name to look up build contexts from
    /// `ProjectRegistry`. Populated by `ProjectOrchestrator.buildStream`;
    /// nil when the caller already has `contextPath`/`dockerfile` resolved.
    public let projectName: String?

    public init(
        service: String,
        imageTag: String? = nil,
        contextPath: String? = nil,
        dockerfile: String? = nil,
        noCache: Bool = false,
        pullBaseImages: Bool = false,
        projectName: String? = nil
    ) {
        self.service = service
        self.imageTag = imageTag
        self.contextPath = contextPath
        self.dockerfile = dockerfile
        self.noCache = noCache
        self.pullBaseImages = pullBaseImages
        self.projectName = projectName
    }
}

/// One frame emitted by `Runtime.build(...)`. Same coarse-grained shape as
/// `RuntimePullEvent` — see that doc comment for the `.swiftAPI` constraint.
public struct RuntimeBuildEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case started
        case completed
        case failed
        /// Emitted when the runtime cannot build (e.g., no build context
        /// available because compose-file upload — CHAOS-1426 — has not
        /// landed). The route layer maps this to the existing "Build not
        /// supported via daemon API — use CLI" frame for backward compat.
        case notSupported
    }
    public let timestamp: Date
    public let service: String
    public let kind: Kind
    public let message: String?

    public init(
        timestamp: Date,
        service: String,
        kind: Kind,
        message: String? = nil
    ) {
        self.timestamp = timestamp
        self.service = service
        self.kind = kind
        self.message = message
    }
}
