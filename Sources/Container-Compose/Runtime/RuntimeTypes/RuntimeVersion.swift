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

// MARK: - RuntimeVersion

/// Backend-neutral version payload returned by `Runtime.version()`. CHAOS-1347
/// Phase 2 route handlers use this as the runtime-side source of truth for the
/// Container REST API version endpoint while keeping HTTP response DTOs separate
/// from runtime metadata.
///
/// `apiVersion` and `serverName` are container-compose API constants;
/// `daemonVersion`, `backendDescription`, and `arch` are supplied by each
/// conformer so clients can distinguish the bridge backend from the native
/// apple/containerization backend without importing backend packages.
public struct RuntimeVersion: Sendable, Hashable, Codable {
    public let apiVersion: String
    public let daemonVersion: String
    public let serverName: String
    public let backendDescription: String
    public let arch: String

    public init(
        apiVersion: String,
        daemonVersion: String,
        serverName: String,
        backendDescription: String,
        arch: String
    ) {
        self.apiVersion = apiVersion
        self.daemonVersion = daemonVersion
        self.serverName = serverName
        self.backendDescription = backendDescription
        self.arch = arch
    }
}
