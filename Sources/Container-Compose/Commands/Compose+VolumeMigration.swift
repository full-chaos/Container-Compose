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

import ContainerAPIClient
import Foundation
import SystemPackage

// Owns the named-volume preparation seam — runtime-registry idempotency,
// legacy-fallback merge, and the .img block-image migration skip path. The
// The matching stored state now lives on the LoopState actor (see
// Sources/Container-Compose/Commands/LoopState.swift), accessed through
// ComposeUp.loopState.
extension ComposeUp {
    internal static let testNamedVolumeSourceOverrideEnv = "CONTAINER_COMPOSE_TEST_NAMED_VOLUME_SOURCE"

    struct PreparedVolumeSource {
        let mountSource: String
        let actualName: String
        let usesLegacyFallback: Bool
    }

    // MARK: - Path helpers

    private func resolvedVolumeName(_ volumeName: String, config volumeConfig: Volume?) -> String {
        if let externalName = volumeConfig?.external?.name, volumeConfig?.external?.isExternal == true {
            return externalName
        }
        return volumeConfig?.name ?? volumeName
    }

    private func legacyVolumeFallbackPath(projectName: String, actualVolumeName: String) -> String {
        FilePath(URL.homeDirectory.path(percentEncoded: false))
            .pushing(".containers")
            .pushing("Volumes")
            .pushing(FilePath(projectName))
            .pushing(FilePath(actualVolumeName))
            .lexicallyNormalized()
            .string
    }

    private func migrationMarkerPath(projectName: String, actualVolumeName: String) -> String {
        FilePath(URL.homeDirectory.path(percentEncoded: false))
            .pushing(".container-compose")
            .pushing("volume-migrations")
            .pushing(FilePath("\(projectName)--\(actualVolumeName).migrated"))
            .lexicallyNormalized()
            .string
    }

    private func migrationMarkerURL(projectName: String, actualVolumeName: String) -> URL {
        URL(filePath: migrationMarkerPath(projectName: projectName, actualVolumeName: actualVolumeName), directoryHint: .notDirectory)
    }

    // MARK: - Output

    private func writeWarningToStandardError(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    // MARK: - Legacy fallback merge

    private func mergeLegacyVolumeContents(from legacyPath: String, into destinationPath: String) throws {
        let children = try FileManager.default.contentsOfDirectory(atPath: legacyPath)
        for child in children {
            let sourcePath = FilePath(legacyPath).appending(child).string
            let destination = FilePath(destinationPath).appending(child).string
            if FileManager.default.fileExists(atPath: destination) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory), isDirectory.boolValue {
                    try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                    try mergeLegacyVolumeContents(from: sourcePath, into: destination)
                }
                continue
            }
            try FileManager.default.copyItem(atPath: sourcePath, toPath: destination)
        }
    }

    internal func migrateLegacyNamedVolumeDataIfNeeded(
        projectName: String,
        actualVolumeName: String,
    ) async throws {
        let legacyPath = legacyVolumeFallbackPath(projectName: projectName, actualVolumeName: actualVolumeName)
        guard FileManager.default.fileExists(atPath: legacyPath) else { return }

        let markerURL = migrationMarkerURL(projectName: projectName, actualVolumeName: actualVolumeName)
        if FileManager.default.fileExists(atPath: markerURL.path(percentEncoded: false)) {
            return
        }

        let runtimeVolumeSource = if let overrideRuntimeVolumeSource = ProcessInfo.processInfo.environment[Self.testNamedVolumeSourceOverrideEnv], !overrideRuntimeVolumeSource.isEmpty {
            overrideRuntimeVolumeSource
        } else {
            // Direct RuntimeVolumeClient call (not RuntimeEnvironment) — uses
            // ContainerResource.Volume.source for filesystem-path migration which
            // is intentionally outside the runtime-neutral RuntimeVolume abstraction.
            try await RuntimeVolumeClient.inspect(name: actualVolumeName).source
        }

        // Block-image volumes (volume.img) are opaque — we cannot merge a legacy
        // directory tree into them without mounting. Skip the migration and write
        // the marker so we don't retry every `up`. Users who need data preserved
        // must mount the image manually.
        if runtimeVolumeSource.hasSuffix(".img") {
            writeWarningToStandardError(
                "Warning: legacy volume data at '\(legacyPath)' cannot be auto-migrated into block-image runtime volume '\(actualVolumeName)' at '\(runtimeVolumeSource)'. Mount the volume image manually if data preservation is required. Skipping migration; future attempts will be suppressed."
            )
            let markerParentURL = URL(filePath: FilePath(markerURL.path(percentEncoded: false)).removingLastComponent().string, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: markerParentURL, withIntermediateDirectories: true)
            try "migration-skipped-block-image".write(to: markerURL, atomically: true, encoding: .utf8)
            return
        }

        // Pre-CHAOS-1368 runtime / non-block source: existing directory-merge behavior.
        try FileManager.default.createDirectory(atPath: runtimeVolumeSource, withIntermediateDirectories: true)
        try mergeLegacyVolumeContents(from: legacyPath, into: runtimeVolumeSource)

        let markerParent = URL(filePath: FilePath(markerURL.path(percentEncoded: false)).removingLastComponent().string, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: markerParent, withIntermediateDirectories: true)
        let markerMessage = "migrated"
        try markerMessage.write(to: markerURL, atomically: true, encoding: .utf8)

        writeWarningToStandardError(
            "Migration: copied legacy named-volume fallback data from '\(legacyPath)' into runtime volume '\(actualVolumeName)' at '\(runtimeVolumeSource)'. Original data was left in place."
        )
    }

    // MARK: - Runtime registration

    internal mutating func prepareNamedVolumeSource(named volumeName: String, from dockerCompose: DockerCompose) async throws -> PreparedVolumeSource {
        guard let projectName else { throw ComposeError.invalidProjectName }

        let volumeConfig = dockerCompose.volumes?[volumeName] ?? nil
        let actualVolumeName = resolvedVolumeName(volumeName, config: volumeConfig)
        let driver = volumeConfig?.driver ?? "local"

        if driver != "local" {
            let volumePath = legacyVolumeFallbackPath(projectName: projectName, actualVolumeName: actualVolumeName)
            let volumeKey = "legacy:\(actualVolumeName)"
            if await loopState.tryInsertPreparedKey(volumeKey) {
                writeWarningToStandardError(
                    "Warning: named volume '\(actualVolumeName)' requests driver '\(driver)', which apple/container does not support for compose volume CRUD yet; using legacy hardlink fallback at '\(volumePath)'."
                )
                try FileManager.default.createDirectory(atPath: volumePath, withIntermediateDirectories: true)
            }
            return PreparedVolumeSource(mountSource: volumePath, actualName: actualVolumeName, usesLegacyFallback: true)
        }

        let volumeKey = "runtime:\(actualVolumeName)"
        if await loopState.tryInsertPreparedKey(volumeKey) {
            if volumeConfig?.external?.isExternal == true {
                do {
                    _ = try await RuntimeEnvironment.current.inspectVolume(name: actualVolumeName)
                } catch RuntimeError.notFound {
                    throw ComposeError.externalVolumeNotFound(actualVolumeName)
                }
            } else {
                await ensureExistingVolumeRegistryCacheLoaded()
                let spec = RuntimeCreateVolumeSpec(
                        name: actualVolumeName,
                        driver: driver,
                        labels: volumeConfig?.labels ?? [:],
                        driverOptions: volumeConfig?.driver_opts ?? [:]
                    )
                _ = try await Self.ensureNamedVolumeRegistered(
                    spec: spec,
                    existing: await loopState.cachedRuntimeVolume(name: actualVolumeName)
                )
                await loopState.cacheRuntimeVolume(name: actualVolumeName, volume: RuntimeVolume(name: actualVolumeName, driver: spec.driver, labels: spec.labels))
            }
            try await migrateLegacyNamedVolumeDataIfNeeded(projectName: projectName, actualVolumeName: actualVolumeName)
        }

        return PreparedVolumeSource(mountSource: actualVolumeName, actualName: actualVolumeName, usesLegacyFallback: false)
    }

    /// Lazily populates `existingNamedVolumeRegistryCache` from
    /// `RuntimeEnvironment.current.listVolumes()` on first use. Idempotent:
    /// subsequent calls within the same `up` are no-ops. If listing fails
    /// (e.g. backend unreachable), the cache is left empty and the create
    /// path will still attempt a create+catch-alreadyExists.
    private mutating func ensureExistingVolumeRegistryCacheLoaded() async {
        do {
            try await loopState.loadCacheOnce {
                let listed = try await RuntimeEnvironment.current.listVolumes()
                return Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0) })
            }
        } catch {
            writeWarningToStandardError(
                "Warning: could not list existing volumes from runtime; falling back to create-and-catch-alreadyExists. Error: \(error)"
            )
        }
    }

    /// Registers a named volume with the runtime if and only if it's not
    /// already present. Returns `true` if a `createVolume` call was actually
    /// issued, `false` if the volume was already present (or a race surfaced
    /// `RuntimeError.alreadyExists` from the create path).
    ///
    /// CHAOS-1398: apple/container's `ClientVolume.create` can fail with a
    /// Foundation NSCocoaErrorDomain error ("file with the same name already
    /// exists") when re-creating an existing volume because the on-disk
    /// `volume.img` is already there. That error doesn't map to
    /// `RuntimeError.alreadyExists` cleanly, so checking the registry list
    /// first is more robust than relying on error string matching.
    @discardableResult
    internal static func ensureNamedVolumeRegistered(
        spec: RuntimeCreateVolumeSpec,
        existing: RuntimeVolume?
    ) async throws -> Bool {
        if let existing {
            // TODO: extend RuntimeVolume to expose driverOptions for richer drift detection (separate follow-up)
            let driverDiffers = existing.driver != spec.driver
            let labelsDiffers = existing.labels != spec.labels

            if driverDiffers || labelsDiffers {
                print("Warning: named volume '\(spec.name)' already exists with different config than declared in compose:")
                if driverDiffers {
                    print("  - driver:  registry='\(existing.driver)', compose='\(spec.driver)'")
                }
                if labelsDiffers {
                    print("  - labels:  registry='\(formatLabels(existing.labels))', compose='\(formatLabels(spec.labels))'")
                }
                print("Reusing the existing volume; its data is from a previous run with different settings.")
                print("Run 'compose down -v' first to recreate with the current config.")
                return false
            }

            print("Warning: named volume '\(spec.name)' already exists from a previous run and was not torn down; reusing it. Run 'compose down -v' to start fresh.")
            return false
        }
        do {
            _ = try await RuntimeEnvironment.current.createVolume(spec: spec)
            return true
        } catch RuntimeError.alreadyExists {
            // Race-condition backstop: someone else created it between our
            // listVolumes() and createVolume() calls.
            return false
        }
    }

    private static func formatLabels(_ labels: [String: String]) -> String {
        labels
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }
}
