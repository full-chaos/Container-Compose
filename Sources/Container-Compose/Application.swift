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
import ArgumentParser

public struct Main: AsyncParsableCommand {
    private static let commandName: String = "container-compose"
    public static let version: String = "0.11.0"
    public static var versionString: String {
        // CHAOS-1446 follow-on: append `+<sha>` (and a `-<kind>` suffix when not a
        // tagged release build) so non-release binaries identify the exact commit
        // they were built from. See `BuildInfo.swift` for the overwrite contract
        // (Makefile target `version-stamp`).
        var suffix = ""
        if BuildInfo.buildKind != "release" {
            suffix += "-\(BuildInfo.buildKind)"
        }
        if !BuildInfo.gitCommit.isEmpty {
            suffix += "+\(BuildInfo.gitCommit)"
        }
        return "\(commandName) version \(version)\(suffix)"
    }
    public static let configuration: CommandConfiguration = .init(
        commandName: Self.commandName,
        abstract: "A tool to use and manage Docker Compose files with Apple Container",
        version: Self.versionString,
        subcommands: [
            ComposeUp.self,
            ComposeDown.self,
            ComposeStart.self,
            ComposeStop.self,
            ComposeRestart.self,
            ComposeBuild.self,
            ComposePs.self,
            ComposeLs.self,
            ComposeLogs.self,
            ComposePull.self,
            ComposeConfig.self,
            ComposeRun.self,
            ComposeExec.self,
            ComposeKill.self,
            ComposeRm.self,
            ComposeCreate.self,
            ComposeWatch.self,
            ComposeTop.self,
            ComposePort.self,
            ComposeEvents.self,
            ComposePush.self,
            ComposeServe.self,
            ComposeSystem.self,
            Version.self
        ])

    public init() {}
}
