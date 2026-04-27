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

//
//  Develop.swift
//  Container-Compose
//
//  Compose-spec `develop:` block — parse-only for Phase 5C.
//

import Foundation

// MARK: - WatchAction

/// The action to perform when a watched path changes.
public enum WatchAction: String, Codable, Hashable, CaseIterable {
    case sync
    case rebuild
    case syncRestart = "sync+restart"
    case syncExec = "sync+exec"
    case restart
}

// MARK: - WatchExec

/// The exec configuration for the `sync+exec` action.
public struct WatchExec: Codable, Hashable {
    /// Command to execute (array form)
    public let command: [String]?
    /// User to run the command as
    public let user: String?
    /// Working directory for the command
    public let workingDir: String?

    enum CodingKeys: String, CodingKey {
        case command, user
        case workingDir = "working_dir"
    }

    public init(command: [String]? = nil, user: String? = nil, workingDir: String? = nil) {
        self.command = command
        self.user = user
        self.workingDir = workingDir
    }
}

// MARK: - WatchRule

/// A single watch rule within the `develop.watch[]` list.
public struct WatchRule: Codable, Hashable {
    /// Host path to watch (relative or absolute)
    public let path: String
    /// Action to take when the path changes
    public let action: WatchAction
    /// Destination path inside the container (required for `sync` actions)
    public let target: String?
    /// Paths / patterns to ignore
    public let ignore: [String]?
    /// Exec configuration for `sync+exec` action
    public let exec: WatchExec?

    public init(
        path: String,
        action: WatchAction,
        target: String? = nil,
        ignore: [String]? = nil,
        exec: WatchExec? = nil
    ) {
        self.path = path
        self.action = action
        self.target = target
        self.ignore = ignore
        self.exec = exec
    }
}

// MARK: - Develop

/// Compose-spec `develop:` block attached to a service.
public struct Develop: Codable, Hashable {
    /// Watch rules to apply during `compose watch`
    public let watch: [WatchRule]?

    public init(watch: [WatchRule]? = nil) {
        self.watch = watch
    }
}
