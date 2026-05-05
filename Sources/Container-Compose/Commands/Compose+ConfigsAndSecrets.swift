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

import CryptoKit
import Foundation

extension ComposeUp {
    /// Builds bind-mount argv for service-level configs and secrets.
    ///
    /// For each `ServiceConfig` / `ServiceSecret` referenced by a service, this
    /// enum looks up the corresponding top-level `Config` / `Secret` definition
    /// to resolve its `file:`, `content:`, or `environment:` source, then emits
    /// a `-v <hostPath>:<target>` pair for `container run`.
    ///
    /// Warnings are printed (not thrown) for unsupported or unresolvable cases:
    /// - Config / secret not present in the top-level map
    /// - Config / secret declared as `external:` (no local source file available)
    /// - Config / secret with no supported local source
    /// - Config / secret whose `environment:` variable is missing on the host
    /// - `uid`, `gid`, or `mode` fields — parsed but not enforceable via `-v`
    enum ConfigsSecretsArgs {
        /// Returns bind-mount argv for all service-level configs and secrets.
        static func build(_ ctx: ArgsContext) -> [String] {
            var args: [String] = []

            // MARK: Configs

            if let serviceConfigs = ctx.service.configs {
                for sc in serviceConfigs {
                    // Flatten [String: Config?]? → Config? for the given key
                    guard let topLevel = ctx.dockerCompose.configs?[sc.source] ?? nil else {
                        print("Warning: Service '\(ctx.serviceName)' references config '\(sc.source)' which is not defined at top-level; skipping.")
                        continue
                    }

                    if topLevel.external?.isExternal == true {
                        print("Warning: External config '\(sc.source)' has no source file; skipping mount.")
                        continue
                    }

                    let target = sc.target ?? "/\(sc.source)"
                    guard let resolvedSource = resolveConfigSource(topLevel, sourceName: sc.source, ctx: ctx) else {
                        continue
                    }
                    args.append(contentsOf: ["-v", "\(resolvedSource):\(target)"])

                    if sc.uid != nil || sc.gid != nil || sc.mode != nil {
                        print("Note: uid/gid/mode for config '\(sc.source)' are parsed but not enforced via container run -v; the file's permissions on the host apply.")
                    }
                }
            }

            // MARK: Secrets

            if let serviceSecrets = ctx.service.secrets {
                for ss in serviceSecrets {
                    // Flatten [String: Secret?]? → Secret? for the given key
                    guard let topLevel = ctx.dockerCompose.secrets?[ss.source] ?? nil else {
                        print("Warning: Service '\(ctx.serviceName)' references secret '\(ss.source)' which is not defined at top-level; skipping.")
                        continue
                    }

                    if topLevel.external?.isExternal == true {
                        print("Warning: External secret '\(ss.source)' has no source file; skipping mount.")
                        continue
                    }

                    let target = ss.target ?? "/run/secrets/\(ss.source)"
                    guard let resolvedSource = resolveSecretSource(topLevel, sourceName: ss.source, ctx: ctx) else {
                        continue
                    }
                    args.append(contentsOf: ["-v", "\(resolvedSource):\(target)"])

                    if ss.uid != nil || ss.gid != nil || ss.mode != nil {
                        print("Note: uid/gid/mode for secret '\(ss.source)' are parsed but not enforced via container run -v; the file's permissions on the host apply.")
                    }
                }
            }

            return args
        }

        private enum TemplateDriverMode {
            case raw
            case golang
        }

        private static func resolveConfigSource(_ topLevel: Config, sourceName: String, ctx: ArgsContext) -> String? {
            if let sourceFile = topLevel.file {
                let expandedPath = (sourceFile as NSString).expandingTildeInPath
                return materializeTemplateIfNeeded(
                    templateDriver: topLevel.templateDriver,
                    rawSourcePath: expandedPath,
                    kind: "config",
                    sourceName: sourceName,
                    ctx: ctx
                )
            }

            if let content = topLevel.content {
                let (resolvedContent, tempKind) = renderTemplateIfNeeded(
                    content,
                    templateDriver: topLevel.templateDriver,
                    kind: "config",
                    sourceName: sourceName,
                    ctx: ctx
                )
                return writeTempFileOrWarn(content: Data(resolvedContent.utf8), kind: tempKind, sourceName: sourceName, projectName: ctx.projectName)
            }

            if let environment = topLevel.environment {
                guard let value = ProcessInfo.processInfo.environment[environment] else {
                    print("Warning: Config '\(sourceName)' references missing host environment variable '\(environment)'; skipping mount.")
                    return nil
                }

                let (resolvedValue, tempKind) = renderTemplateIfNeeded(
                    value,
                    templateDriver: topLevel.templateDriver,
                    kind: "config",
                    sourceName: sourceName,
                    ctx: ctx
                )
                return writeTempFileOrWarn(content: Data(resolvedValue.utf8), kind: tempKind, sourceName: sourceName, projectName: ctx.projectName)
            }

            print("Warning: Config '\(sourceName)' has no 'file:' source; skipping.")
            return nil
        }

        private static func resolveSecretSource(_ topLevel: Secret, sourceName: String, ctx: ArgsContext) -> String? {
            if let sourceFile = topLevel.file {
                let expandedPath = (sourceFile as NSString).expandingTildeInPath
                return materializeTemplateIfNeeded(
                    templateDriver: topLevel.templateDriver,
                    rawSourcePath: expandedPath,
                    kind: "secret",
                    sourceName: sourceName,
                    ctx: ctx
                )
            }

            if let environment = topLevel.environment {
                guard let value = ProcessInfo.processInfo.environment[environment] else {
                    print("Warning: Secret '\(sourceName)' references missing host environment variable '\(environment)'; skipping mount.")
                    return nil
                }

                let (resolvedValue, tempKind) = renderTemplateIfNeeded(
                    value,
                    templateDriver: topLevel.templateDriver,
                    kind: "secret",
                    sourceName: sourceName,
                    ctx: ctx
                )
                return writeTempFileOrWarn(content: Data(resolvedValue.utf8), kind: tempKind, sourceName: sourceName, projectName: ctx.projectName)
            }

            print("Warning: Secret '\(sourceName)' has no 'file:' source; skipping.")
            return nil
        }

        private static func materializeTemplateIfNeeded(
            templateDriver: String?,
            rawSourcePath: String,
            kind: String,
            sourceName: String,
            ctx: ArgsContext
        ) -> String? {
            guard templateDriverMode(templateDriver, kind: kind) == .golang else {
                return rawSourcePath
            }

            do {
                let content = try String(contentsOfFile: rawSourcePath, encoding: .utf8)
                let rendered = renderGoTemplate(content, env: templateEnvironment(ctx), context: templateContext(ctx))
                return writeTempFileOrWarn(
                    content: Data(rendered.utf8),
                    kind: "\(kind)-rendered",
                    sourceName: sourceName,
                    projectName: ctx.projectName
                )
            } catch {
                print("Warning: Could not read \(kind) '\(sourceName)' template source at '\(rawSourcePath)': \(error.localizedDescription); skipping mount.")
                return nil
            }
        }

        private static func renderTemplateIfNeeded(
            _ content: String,
            templateDriver: String?,
            kind: String,
            sourceName: String,
            ctx: ArgsContext
        ) -> (content: String, tempKind: String) {
            guard templateDriverMode(templateDriver, kind: kind) == .golang else {
                return (content, kind)
            }

            return (renderGoTemplate(content, env: templateEnvironment(ctx), context: templateContext(ctx)), "\(kind)-rendered")
        }

        private static func templateEnvironment(_ ctx: ArgsContext) -> [String: String] {
            ProcessInfo.processInfo.environment.merging(ctx.environmentVariables) { current, _ in current }
        }

        private static func templateContext(_ ctx: ArgsContext) -> [String: String] {
            [
                "Project.Name": ctx.projectName,
                "Service.Name": ctx.serviceName,
                "Task.Name": ctx.containerName,
                "Node.Hostname": ProcessInfo.processInfo.environment["HOSTNAME"] ?? ""
            ]
        }

        private static func templateDriverMode(_ templateDriver: String?, kind: String) -> TemplateDriverMode {
            guard let templateDriver else {
                return .raw
            }

            let normalized = templateDriver.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                return .raw
            }

            switch normalized.lowercased() {
            case "file":
                return .raw
            case "golang":
                return .golang
            default:
                warnUnsupportedRuntimeFieldOnce(
                    "service.\(kind).templateDriver.\(normalized)",
                    "Note: template_driver '\(normalized)' is not supported (only 'file' and 'golang' are recognized); the raw file will be mounted as-is."
                )
                return .raw
            }
        }

        private static func writeTempFileOrWarn(content: Data, kind: String, sourceName: String, projectName: String) -> String? {
            do {
                return try writeTempFile(content: content, kind: kind, sourceName: sourceName, projectName: projectName)
            } catch {
                print("Warning: Could not materialize \(kind) '\(sourceName)' as a host file: \(error.localizedDescription); skipping mount.")
                return nil
            }
        }

        private static func writeTempFile(content: Data, kind: String, sourceName: String, projectName: String) throws -> String {
            let digest = SHA256.hash(data: content)
            let hashPrefix = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
            let safeProjectName = sanitizedHostPathComponent(projectName)
            let safeSourceName = sanitizedHostPathComponent(sourceName)
            let directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".containers/Compose/\(safeProjectName)/configs-secrets", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

            let fileName = "\(kind)-\(safeSourceName)-\(hashPrefix)"
            let fileURL = directoryURL.appending(path: fileName)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try content.write(to: fileURL, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

            return fileURL.path
        }

        private static func sanitizedHostPathComponent(_ value: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let sanitizedScalars = value.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? Character(scalar) : "_"
            }
            let sanitized = String(sanitizedScalars)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sanitized.isEmpty ? "unnamed" : sanitized
        }
    }
}
