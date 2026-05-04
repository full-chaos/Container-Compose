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
//  Errors.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/18/25.
//

import ContainerCommands
import Foundation

//extension Application {
public enum YamlError: Error, LocalizedError {
    case composeFileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .composeFileNotFound(let path):
            return "compose.yml not found at \(path)"
        }
    }
}

public enum ComposeError: Error, LocalizedError {
    case imageNotFound(String)
    case invalidProjectName
    case externalVolumeNotFound(String)
    case invalidShellTokenization(input: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .imageNotFound(let name):
            return "Service \(name) must define either 'image' or 'build'."
        case .invalidProjectName:
            return "Could not find project name."
        case .externalVolumeNotFound(let name):
            return "External volume '\(name)' was not found. Create it with 'container volume create \(name)' before running compose."
        case .invalidShellTokenization(let input, let reason):
            return "Could not tokenize string-form command/entrypoint '\(input)': \(reason)"
        }
    }
}

public enum TerminalError: Error, LocalizedError {
    case commandFailed(String)

    public var errorDescription: String? {
        "Command failed: \(self)"
    }
}

// MARK: - ComposeValidationError

/// Errors thrown by `DockerCompose.validate()` when a compose file contains
/// invalid or semantically inconsistent configuration.
public enum ComposeValidationError: Error, Equatable {
    /// The compose file defines no services at all.
    case noServicesDefined

    /// A service does not provide either `image` or `build`.
    case serviceNeedsImageOrBuild(serviceName: String)

    /// A port specification string cannot be parsed or contains out-of-range
    /// port numbers.
    case invalidPortFormat(portSpec: String, serviceName: String)

    /// A `depends_on` chain forms a cycle, making startup order undefined.
    case circularDependency(serviceChain: [String])

    /// A resource-constraint field (e.g. `deploy.resources.limits.cpus`)
    /// falls outside the allowed range.
    case resourceConstraintOutOfRange(field: String, value: String, min: Int, max: Int?)

    /// A service declares both `image` and `build`, which is ambiguous.
    /// The Compose spec says `image` acts as the tag for the built image, but
    /// having both is often a user mistake and is surfaced as an error so they
    /// can make their intent explicit.
    case imageBuildConflict(serviceName: String)
}

extension ComposeValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noServicesDefined:
            return "Compose file defines no services."
        case .serviceNeedsImageOrBuild(let name):
            return "Service '\(name)' must define either 'image' or 'build'."
        case .invalidPortFormat(let portSpec, let serviceName):
            return "Service '\(serviceName)': invalid port specification '\(portSpec)'."
        case .circularDependency(let chain):
            let chainDescription = chain.joined(separator: " → ")
            return "Circular dependency detected: \(chainDescription)"
        case .resourceConstraintOutOfRange(let field, let value, let min, let max):
            if let max {
                return "Resource constraint '\(field)' value '\(value)' is out of range [\(min), \(max)]."
            } else {
                return "Resource constraint '\(field)' value '\(value)' must be ≥ \(min)."
            }
        case .imageBuildConflict(let name):
            return "Service '\(name)' declares both 'image' and 'build'. Remove one or use 'image' only as the tag for the built image (set it alongside 'build.context')."
        }
    }
}

/// An enum representing streaming output from either `stdout` or `stderr`.
public enum CommandOutput {
    case stdout(String)
    case stderr(String)
    case exitCode(Int32)
}
//}
