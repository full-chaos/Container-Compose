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
//  ComposeCommand.swift
//  Container-Compose
//

import Foundation
import SystemPackage

/// Shared boilerplate for Compose subcommands that load a compose file.
///
/// The existing subcommands are `AsyncParsableCommand` structs with stored
/// `@OptionGroup var projectFlags: ProjectFlags`, a `-f/--file` option named
/// `composeFilename`, and a command-specific working-directory source. This
/// protocol intentionally requires only those plain values instead of trying to
/// model property-wrapper storage; conforming commands keep their current
/// `@OptionGroup` declarations and expose `cwd` with whatever precedence they
/// already use (`Flags.Process.cwd`, `--cwd`, etc.).
///
/// Phase 2 migration template:
/// 1. Add `ComposeCommand` conformance to the command struct.
/// 2. Remove the local `supportedComposeFilenames`, `composePath`,
///    and project-directory helpers when their shapes match these defaults.
/// 3. Replace `DockerCompose.loadAndMerge(...).resolvingExtends()` with
///    `loadAndResolve()` unless the command deliberately needs the unresolved
///    tree.
/// 4. Replace the standard profile/service/topo-sort block with
///    `filterServices(_:profilesArg:servicesArg:)` when the command's service
///    filtering should include dependencies selected by requested services.
///
/// Caveats for outliers:
/// - `ComposeConfig` can conform for `composePath` / `loadAndResolve()` without
///   calling `resolveProjectName(for:)`; project-name logging is opt-in.
/// - Commands such as `build`, `run`, `ps`, and `top` use slightly different
///   service filtering semantics (for example no topo-sort, build-only
///   filtering, or exact service matching). They can still use the path/loading
///   helpers and keep custom filtering where needed.
protocol ComposeCommand {
    /// Value of the command's `-f` / `--file` option, if provided.
    var composeFilename: String? { get }

    /// Host working directory used to resolve relative compose-file paths.
    var cwd: String { get }

    /// Shared Docker Compose project-context flags (`-p`, `--project-directory`).
    var projectFlags: ProjectFlags { get }
}

extension ComposeCommand {
    /// Compose filenames searched when `-f/--file` is omitted.
    static var supportedComposeFilenames: [String] {
        [
            "compose.yml",
            "compose.yaml",
            "docker-compose.yml",
            "docker-compose.yaml",
        ]
    }


    /// Effective compose-file path.
    ///
    /// Honors the explicit `-f/--file` path first (resolved relative to `cwd`),
    /// otherwise returns the first supported compose filename that exists in
    /// `cwd`. If none exist, returns the conventional `compose.yml` path so the
    /// downstream loader emits the same file-not-found error shape as today.
    var composePath: String {
        if let composeFilename {
            return resolvedPath(for: composeFilename, relativeTo: cwd)
        }

        // CHAOS-1443: build candidate paths via FilePath instead of URL to
        // eliminate the `URL(fileURLWithPath:).appending(path:).path` chain
        // (which would otherwise carry the same isDirectory-introspection
        // footgun as the resolvedPath bug).
        let cwdFP = FilePath(cwd)
        for filename in Self.supportedComposeFilenames {
            let candidate = cwdFP.appending(filename).string
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return cwdFP.appending(Self.supportedComposeFilenames[0]).string
    }

    /// Project root for outside-container relative-path resolution.
    ///
    /// Mirrors existing command precedence: `--project-directory`, then the
    /// compose file's containing directory.
    var effectiveProjectDirectory: String {
        resolveProjectDirectory(
            cliOverride: projectFlags.projectDirectory,
            composeFilePath: composePath,
            cwd: cwd
        )
    }

    /// Resolves the effective Docker Compose project name and emits one
    /// consistent informational log line.
    ///
    /// The resolution itself delegates to the existing helper, preserving
    /// precedence: `--project-name` > compose `name:` > project-directory
    /// basename. Commands that do not need a project name (notably
    /// `compose config`) should simply not call this method.
    func resolveProjectName(for dockerCompose: DockerCompose) -> String {
        let projectName = ContainerComposeCore.resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )
        print("Info: Using project name '\(projectName)'")
        return projectName
    }

    /// Loads the selected compose file, recursively merges `include:` files,
    /// and resolves `extends:` inheritance.
    func loadAndResolve() throws -> DockerCompose {
        try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()
    }

    /// Applies the standard service selection pipeline used by lifecycle
    /// commands: concrete services → active profiles → topo-sort → optional
    /// CLI service filter.
    ///
    /// The service-name filter preserves the current lifecycle semantics: a
    /// service is selected when its name is explicitly requested or when it is a
    /// dependency of a requested dependent (`service.dependedBy` contains the
    /// requested name after topo-sort populates reverse edges). Commands that
    /// require exact matching or no topo-sort should keep custom filtering.
    func filterServices(
        _ dockerCompose: DockerCompose,
        profilesArg: [String],
        servicesArg: [String]
    ) throws -> [(serviceName: String, service: Service)] {
        var resolvedServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { serviceName, service in
            guard let service else { return nil }
            return (serviceName, service)
        }

        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profilesArg)
        resolvedServices = Service.filterByProfiles(resolvedServices, activeProfiles: activeProfiles)
        resolvedServices = try Service.topoSortConfiguredServices(resolvedServices)

        if !servicesArg.isEmpty {
            resolvedServices = resolvedServices.filter { serviceName, service in
                servicesArg.contains(serviceName) || servicesArg.contains { service.dependedBy.contains($0) }
            }
        }

        return resolvedServices
    }
}
