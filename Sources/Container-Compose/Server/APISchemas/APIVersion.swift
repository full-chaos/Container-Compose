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

// MARK: - GET /version

public struct APIVersionResponse: Codable, Sendable, Hashable {
    public let apiVersion: String
    public let version: String
    public let serverName: String
    public let runtimeBackend: String
    public let arch: String

    public init(
        apiVersion: String,
        version: String,
        serverName: String,
        runtimeBackend: String,
        arch: String
    ) {
        self.apiVersion = apiVersion
        self.version = version
        self.serverName = serverName
        self.runtimeBackend = runtimeBackend
        self.arch = arch
    }
}

// MARK: - GET /info

public struct APIInfoResponse: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let containerCount: Int
    public let containersRunning: Int
    public let containersPaused: Int
    public let containersStopped: Int
    public let serverVersion: String
    public let runtimeBackend: String
    public let uptimeNanoseconds: Int64

    public init(
        id: String,
        name: String,
        containerCount: Int,
        containersRunning: Int,
        containersPaused: Int,
        containersStopped: Int,
        serverVersion: String,
        runtimeBackend: String,
        uptimeNanoseconds: Int64
    ) {
        self.id = id
        self.name = name
        self.containerCount = containerCount
        self.containersRunning = containersRunning
        self.containersPaused = containersPaused
        self.containersStopped = containersStopped
        self.serverVersion = serverVersion
        self.runtimeBackend = runtimeBackend
        self.uptimeNanoseconds = uptimeNanoseconds
    }
}
