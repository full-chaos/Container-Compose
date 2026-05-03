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
//  Helper Functions.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation
import Yams
import Rainbow
import ContainerCommands

enum ComposeMemoryParseError: Error, Equatable {
    case empty
    case invalid(String)
    case negative(String)
    case overflow(String)
}

/// Parses a Docker Compose memory quantity into bytes for numeric comparison.
///
/// Compose accepts bare byte counts plus byte (`b`/`B`), binary shortcut
/// (`k`, `kb`, `K`, `m`, `mb`, `M`, etc.), IEC (`Ki`, `Mi`, `Gi`, `Ti`), and
/// SI uppercase (`KB`, `MB`, `GB`, `TB`) suffixes. Container-Compose passes the
/// original string through to Apple container; this helper is only for local
/// validation such as comparing reservations against limits.
func parseComposeMemoryBytes(_ rawValue: String) throws -> UInt64 {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw ComposeMemoryParseError.empty }

    let suffixes: [(suffix: String, multiplier: Double)] = [
        ("KB", 1_000),
        ("MB", 1_000_000),
        ("GB", 1_000_000_000),
        ("TB", 1_000_000_000_000),
        ("Ki", 1_024),
        ("Mi", 1_048_576),
        ("Gi", 1_073_741_824),
        ("Ti", 1_099_511_627_776),
        ("kb", 1_024),
        ("mb", 1_048_576),
        ("gb", 1_073_741_824),
        ("tb", 1_099_511_627_776),
        ("k", 1_024),
        ("K", 1_024),
        ("m", 1_048_576),
        ("M", 1_048_576),
        ("g", 1_073_741_824),
        ("G", 1_073_741_824),
        ("t", 1_099_511_627_776),
        ("T", 1_099_511_627_776),
        ("b", 1),
        ("B", 1)
    ]

    let match = suffixes.first { value.hasSuffix($0.suffix) }
    let numberPart: String
    let multiplier: Double
    if let match {
        numberPart = String(value.dropLast(match.suffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        multiplier = match.multiplier
    } else {
        numberPart = value
        multiplier = 1
    }

    guard let number = Double(numberPart), number.isFinite else {
        throw ComposeMemoryParseError.invalid(rawValue)
    }
    guard number >= 0 else { throw ComposeMemoryParseError.negative(rawValue) }

    let bytes = number * multiplier
    guard bytes <= Double(UInt64.max) else { throw ComposeMemoryParseError.overflow(rawValue) }
    return UInt64(bytes.rounded(.towardZero))
}

public func resolvedPath(for path: String, relativeTo baseURL: URL) -> String {
    let expandedPath = NSString(string: path).expandingTildeInPath
    return URL(fileURLWithPath: expandedPath, relativeTo: baseURL).standardizedFileURL.path
}


/// Loads environment variables from a .env file.
/// - Parameter path: The full path to the .env file.
/// - Returns: A dictionary of key-value pairs representing environment variables.
public func loadEnvFile(path: String) -> [String: String] {
    var envVars: [String: String] = [:]
    let fileURL = URL(fileURLWithPath: path)
    do {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Ignore empty lines and comments
            if !trimmedLine.isEmpty && !trimmedLine.starts(with: "#") {
                // Parse key=value pairs
                if let eqIndex = trimmedLine.firstIndex(of: "=") {
                    let key = String(trimmedLine[..<eqIndex])
                    let value = String(trimmedLine[trimmedLine.index(after: eqIndex)...])
                    envVars[key] = value
                }
            }
        }
    } catch {
        // print("Warning: Could not read .env file at \(path): \(error.localizedDescription)")
        // Suppress error message if .env file is optional or missing
    }
    return envVars
}

/// Merge service env preserving Container-Compose's current precedence:
///   1. Start from `baseline` (caller-provided; today loaded from project `.env`).
///   2. For each entry in `serviceEnvFile` (declared order), load the file and merge with
///      first-writer-wins semantics — baseline values and earlier env_file entries are
///      NEVER overridden. `entry.required == false` with a missing file is silent-skipped.
///   3. Merge `serviceEnvironment` on top: a key is overridden ONLY when the new value does
///      NOT contain `${`. Values with `${` keep the existing key (caller runs substitution
///      AFTER calling this helper).
/// The helper does NOT perform substitution, runtime overrides, or service-name → IP
/// rewriting. Those stay in the caller.
public func mergeServiceEnvironment(
    baseline: [String: String],
    serviceEnvFile: [EnvFileEntry]?,
    serviceEnvironment: [String: String]?,
    projectDirectory: String
) -> [String: String] {
    var combinedEnv: [String: String] = baseline

    if let envFiles = serviceEnvFile {
        for entry in envFiles {
            let resolved = URL(fileURLWithPath: entry.path, relativeTo: URL(fileURLWithPath: projectDirectory)).path
            if !entry.required && !FileManager.default.fileExists(atPath: resolved) {
                continue
            }
            let additionalEnvVars = loadEnvFile(path: resolved)
            combinedEnv.merge(additionalEnvVars) { current, _ in current }
        }
    }

    if let serviceEnv = serviceEnvironment {
        combinedEnv.merge(serviceEnv) { old, new in
            guard !new.contains("${") else { return old }
            return new
        }
    }

    return combinedEnv
}

/// Resolves environment variables within a string (e.g., ${VAR:-default}, ${VAR:?error}).
/// This function supports default values and error-on-missing variable syntax.
/// - Parameters:
///   - value: The string possibly containing environment variable references.
///   - envVars: A dictionary of environment variables to use for resolution.
/// - Returns: The string with all recognized environment variables resolved.
public func resolveVariable(_ value: String, with envVars: [String: String]) -> String {
    var resolvedValue = value
    // Regex to find ${VAR}, ${VAR:-default}, ${VAR:?error}
    let regex = try! NSRegularExpression(pattern: #"\$\{([A-Za-z0-9_]+)(:?-(.*?))?(:\?(.*?))?\}"#, options: [])
    
    // Combine process environment with loaded .env file variables, prioritizing process environment
    let combinedEnv = ProcessInfo.processInfo.environment.merging(envVars) { (current, _) in current }
    
    // Loop to resolve all occurrences of variables in the string
    while let match = regex.firstMatch(in: resolvedValue, options: [], range: NSRange(resolvedValue.startIndex..<resolvedValue.endIndex, in: resolvedValue)) {
        guard let varNameRange = Range(match.range(at: 1), in: resolvedValue) else { break }
        let varName = String(resolvedValue[varNameRange])
        
        if let envValue = combinedEnv[varName] {
            // Variable found in environment, replace with its value
            resolvedValue.replaceSubrange(Range(match.range(at: 0), in: resolvedValue)!, with: envValue)
        } else if let defaultValueRange = Range(match.range(at: 3), in: resolvedValue) {
            // Variable not found, but default value is provided, replace with default
            let defaultValue = String(resolvedValue[defaultValueRange])
            resolvedValue.replaceSubrange(Range(match.range(at: 0), in: resolvedValue)!, with: defaultValue)
        } else if match.range(at: 5).location != NSNotFound, let errorMessageRange = Range(match.range(at: 5), in: resolvedValue) {
            // Variable not found, and error-on-missing syntax used, print error and exit
            let errorMessage = String(resolvedValue[errorMessageRange])
            fputs("Error: Missing required environment variable '\(varName)': \(errorMessage)\n", stderr)
            Application.exit(withError: "Error: Missing required environment variable '\(varName)': \(errorMessage)\n")
        } else {
            // Variable not found and no default/error specified, leave as is and break loop to avoid infinite loop
            break
        }
    }
    return resolvedValue
}

/// Renders a minimal subset of Go text/template syntax against the supplied environment.
///
/// Supported syntax:
/// - `{{ .VAR }}` — substituted with `env["VAR"]`, or empty string if missing
/// - `{{ .Service.Name }}` — substituted from the supplied synthetic context
/// - `{{ env "VAR" }}` / `{{ env "VAR" | default "x" }}` — equivalent function form
/// - `{{ .VAR | default "fallback" }}` — pipeline default
///
/// Unsupported syntax (control flow, complex pipelines, custom functions) is left
/// untouched; the template is returned with those expressions as-is. Callers should
/// document this limitation. See [CHAOS-1384](https://linear.app/fullchaos/issue/CHAOS-1384).
public func renderGoTemplate(_ template: String, env: [String: String], context: [String: String] = [:]) -> String {
    let blockRegex = try! NSRegularExpression(
        pattern: #"\{\{\s*(.*?)\s*\}\}"#,
        options: []
    )
    let matches = blockRegex.matches(
        in: template,
        range: NSRange(template.startIndex..<template.endIndex, in: template)
    )
    var rendered = template

    for match in matches.reversed() {
        guard
            let originalBlockRange = Range(match.range(at: 0), in: template),
            let renderedBlockRange = Range(match.range(at: 0), in: rendered),
            let innerRange = Range(match.range(at: 1), in: template)
        else { continue }

        let innerExpression = String(template[innerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let replacement = renderGoTemplateExpression(innerExpression, env: env, context: context) else {
            rendered.replaceSubrange(renderedBlockRange, with: String(template[originalBlockRange]))
            continue
        }

        rendered.replaceSubrange(renderedBlockRange, with: replacement)
    }

    return rendered
}

private func renderGoTemplateExpression(_ expression: String, env: [String: String], context: [String: String]) -> String? {
    let pipelineParts = expression.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    let lookupExpression = pipelineParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let lookup = parseGoTemplateLookup(lookupExpression, env: env, context: context) else {
        return nil
    }

    guard pipelineParts.count == 2 else {
        return lookup.value ?? ""
    }

    let defaultExpression = pipelineParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let fallback = parseGoTemplateDefault(defaultExpression) else {
        return nil
    }

    return lookup.value ?? fallback
}

private func parseGoTemplateLookup(_ expression: String, env: [String: String], context: [String: String]) -> (key: String, value: String?)? {
    if let key = firstRegexCapture(in: expression, pattern: #"^\.([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)$"#) {
        return (key, context[key] ?? env[key])
    }

    if let key = firstRegexCapture(in: expression, pattern: #"^env\s+\"([A-Za-z_][A-Za-z0-9_]*)\"$"#) {
        return (key, env[key])
    }

    return nil
}

private func parseGoTemplateDefault(_ expression: String) -> String? {
    firstRegexCapture(in: expression, pattern: #"^default\s+\"([^\"]*)\"$"#)
}

private func firstRegexCapture(in value: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return nil
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard
        let match = regex.firstMatch(in: value, range: range),
        let captureRange = Range(match.range(at: 1), in: value)
    else {
        return nil
    }
    return String(value[captureRange])
}

/// Resolves the effective container name for a service, honoring an explicit
/// `container_name:` override and falling back to `<project>-<service>` when
/// no override is set. An empty explicit string is treated as if no override
/// were present, mirroring `resolveProjectName`'s handling of `--project-name ""`.
///
/// This helper exists so that every command (up, down, ip lookup, wait) agrees
/// on what to call a container — without it, ComposeUp historically ignored
/// `container_name` while ComposeDown honored it (CHAOS-1396).
public func effectiveContainerName(
    projectName: String,
    serviceName: String,
    explicit: String?
) -> String {
    if let explicit, !explicit.isEmpty {
        return explicit
    }
    return "\(projectName)-\(serviceName)"
}

/// Derives a project name from the current working directory. It replaces any '.' characters with
/// '_' to ensure compatibility with container naming conventions.
///
/// - Parameter cwd: The current working directory path.
/// - Returns: A sanitized project name suitable for container naming.
public func deriveProjectName(cwd: String) -> String {
    // We need to replace '.' with _ because it is not supported in the container name
    let projectName = URL(fileURLWithPath: cwd).lastPathComponent.replacingOccurrences(of: ".", with: "_")
    return projectName
}

/// Resolves the effective project name with `docker compose` precedence:
/// CLI override (`-p` / `--project-name`) > compose file `name:` > basename
/// of the project directory (sanitized via `deriveProjectName`).
///
/// An empty CLI override is treated as if the flag had not been provided, so
/// that a stray `--project-name ""` does not silently produce an unnamed
/// project — it falls through to the compose-file or directory-derived name.
/// - Parameters:
///   - cliOverride: Value of the `-p` / `--project-name` flag, if any.
///   - composeName: The `name:` field from the compose document, if any.
///   - projectDirectory: The effective project root, used for the basename
///     fallback. (See `resolveProjectDirectory(...)`.)
public func resolveProjectName(
    cliOverride: String?,
    composeName: String?,
    projectDirectory: String
) -> String {
    if let cli = cliOverride, !cli.isEmpty { return cli }
    if let name = composeName, !name.isEmpty { return name }
    return deriveProjectName(cwd: projectDirectory)
}

/// Resolves the effective project root used to anchor outside-container
/// relative-path resolution (build context, env-file, volume bind sources,
/// etc.). This is *not* the same as `Flags.Process.cwd`, which is the
/// inside-container working directory.
///
/// Precedence: CLI override (`--project-directory`) > the compose file's
/// containing directory.
///
/// A relative CLI override is resolved against `cwd` (i.e. the current
/// working directory of the host process), matching `docker compose`'s
/// behaviour where `--project-directory ./services` is relative to where
/// the user invoked the command.
/// - Parameters:
///   - cliOverride: Value of the `--project-directory` flag, if any.
///   - composeFilePath: Absolute path to the compose file.
///   - cwd: Current working directory of the host process. Used to resolve
///     relative `cliOverride` values.
public func resolveProjectDirectory(
    cliOverride: String?,
    composeFilePath: String,
    cwd: String
) -> String {
    if let cli = cliOverride, !cli.isEmpty {
        let expanded = NSString(string: cli).expandingTildeInPath
        // `isDirectory: true` on the base URL is required so that
        // `URL(fileURLWithPath:relativeTo:)` joins the relative path
        // against `cwd` instead of treating `cwd` as a file and
        // replacing its last component.
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: cwdURL)
            .standardizedFileURL.path
    }
    return URL(fileURLWithPath: composeFilePath).deletingLastPathComponent().path
}

/// Converts Docker Compose port specification into a container run -p format.
/// Handles various formats: "PORT", "HOST:PORT", "IP:HOST:PORT", and optional protocol.
/// - Parameter portSpec: The port specification string from docker-compose.yml.
/// - Returns: A properly formatted port binding for `container run -p`.
public func composePortToRunArg(_ portSpec: String) -> String {
    // Check for protocol suffix (e.g., "/tcp" or "/udp")
    var protocolSuffix = ""
    var portBody = portSpec
    if let slashRange = portSpec.range(of: "/", options: [.backwards]) {
        let afterSlash = portSpec[slashRange.lowerBound...]
        let protocolPart = String(afterSlash)
        if protocolPart == "/tcp" || protocolPart == "/udp" {
            protocolSuffix = protocolPart
            portBody = String(portSpec[..<slashRange.lowerBound])
        }
    }

    let components = portBody.split(separator: ":", maxSplits: 3).map(String.init)
    switch components.count {
    case 1:
        let containerPort = components[0]
        return "0.0.0.0:\(containerPort):\(containerPort)\(protocolSuffix)"
    case 2:
        let hostPart = components[0]
        let containerPart = components[1]
        let hasIPv4 = hostPart.contains(".")
        let hasIPv6 = hostPart.contains(":") && hostPart.hasPrefix("[") && hostPart.hasSuffix("]")
        if hasIPv4 || hasIPv6 {
            return "\(hostPart):\(containerPart)\(protocolSuffix)"
        } else {
            return "0.0.0.0:\(hostPart):\(containerPart)\(protocolSuffix)"
        }
    case 3:
        let ipPart = components[0]
        let hostPart = components[1]
        let containerPart = components[2]
        return "\(ipPart):\(hostPart):\(containerPart)\(protocolSuffix)"
    default:
        return portSpec
    }
}

/// Returns the OCI platform string (e.g. `linux/arm64`, `linux/amd64`) for
/// the host's architecture. Used as the fallback platform when a Compose
/// service does not declare an explicit `platform:` field.
///
/// Without this fallback, Apple's `container` runtime defaults to
/// `linux/amd64` even on Apple Silicon hosts, causing image pulls and runs
/// to silently fetch the wrong architecture (CHAOS-1344). The OS component
/// is hard-coded to `linux` because Apple `container` only runs Linux
/// guests today.
public func defaultRuntimePlatform() -> String {
    #if arch(arm64)
    return "linux/arm64"
    #elseif arch(x86_64)
    return "linux/amd64"
    #else
    // Defensive fallback for architectures Apple `container` does not target
    // (e.g. armv7). Mirrors Docker's historical Linux default rather than
    // emitting an invalid platform string.
    return "linux/amd64"
    #endif
}

extension ComposeUp {
    /// Qualifies Docker-style image references for Apple container APIs, which
    /// require an explicit registry host.
    internal static func qualifyImageReference(_ ref: String) -> String {
        guard !ref.isEmpty else { return ref }

        let host: String
        let path: String

        if let slashIndex = ref.firstIndex(of: "/") {
            let firstPart = String(ref[..<slashIndex])
            let rest = String(ref[ref.index(after: slashIndex)...])

            if firstPart.contains(".") || firstPart.contains(":") || firstPart == "localhost" {
                host = firstPart
                path = rest
            } else {
                host = "docker.io"
                path = ref
            }
        } else {
            host = "docker.io"
            path = "library/\(ref)"
        }

        if path.contains(":") || path.contains("@") {
            return "\(host)/\(path)"
        }

        return "\(host)/\(path):latest"
    }
}

extension String: @retroactive Error {}

/// A structure representing the result of a command-line process execution.
public struct CommandResult {
    /// The standard output captured from the process.
    public let stdout: String

    /// The standard error output captured from the process.
    public let stderr: String

    /// The exit code returned by the process upon termination.
    public let exitCode: Int32
}

extension NamedColor: @retroactive Codable {

}
