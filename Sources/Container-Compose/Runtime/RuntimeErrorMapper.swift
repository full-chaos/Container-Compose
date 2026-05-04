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

import ContainerizationError
import ContainerResource
import Foundation

// MARK: - RuntimeErrorMapper

/// Shared, backend-neutral helper that translates any upstream error into the
/// `RuntimeError` vocabulary.
///
/// ## Why this exists (CHAOS-1416)
///
/// Before this helper, the same upstream error could be mapped differently
/// depending on which conformer or which method caught it:
///
/// - `RuntimeVolumeClient.create` caught `VolumeError` and
///   `ContainerizationError` with string-matching, but a raw Foundation
///   `NSCocoaError` (e.g. `NSFileWriteFileExistsError` from the volume-image
///   creation path) fell through to `.backendFailure`.
/// - `BridgeContainerClientRuntime.mapUpstreamError` handled
///   `ContainerizationError(.notFound)` recursively but had no `VolumeError`
///   arm and no NSCocoaError arm.
/// - `AppleContainerizationRuntime.mapUpstreamError` only passed through
///   already-`RuntimeError` values; everything else became `.backendFailure`.
///
/// `RuntimeErrorMapper.map(_:id:)` is the single canonical translation point.
/// Conformers and `RuntimeVolumeClient` call it in their catch-all clause
/// instead of duplicating mapping logic.
///
/// ## Mapping table
///
/// | Upstream type | Condition | Result |
/// |---|---|---|
/// | `RuntimeError` | — (pass-through) | unchanged |
/// | `VolumeError.volumeAlreadyExists` | — | `.alreadyExists(id:)` |
/// | `VolumeError.volumeNotFound` | — | `.notFound(id:)` |
/// | `VolumeError` (other) | — | `.backendFailure` |
/// | `ContainerizationError` | `.isCode(.notFound)` (recursive) | `.notFound(id:)` |
/// | `ContainerizationError` | message contains "already exists" | `.alreadyExists(id:)` |
/// | `ContainerizationError` | message contains "not found" | `.notFound(id:)` |
/// | `ContainerizationError` (other) | — | `.backendFailure` |
/// | `NSError` in `NSCocoaErrorDomain` | code `NSFileWriteFileExistsError` | `.alreadyExists(id:)` |
/// | `NSError` in `NSCocoaErrorDomain` | code `NSFileNoSuchFileError` | `.notFound(id:)` |
/// | Any other | — | `.backendFailure(message: localizedDescription)` |
///
/// ## Note on CHAOS-1413 (Layer 1)
///
/// The NSCocoaError arm above is the fix for CHAOS-1413 Layer 1: when
/// `ClientVolume.create(...)` fails because the backing volume-image file
/// already exists on disk, Foundation raises `NSFileWriteFileExistsError`
/// (code 516). Before this mapper the error fell through to `.backendFailure`;
/// now it correctly surfaces as `.alreadyExists(id:)` so callers applying
/// idempotent-create logic get the expected `RuntimeError` rather than an
/// opaque failure message.
enum RuntimeErrorMapper {

    /// Translate `error` into a `RuntimeError`.
    ///
    /// - Parameters:
    ///   - error: The upstream error to translate.
    ///   - id: The resource identifier involved in the operation (container /
    ///     volume / network name). Supplied to `.notFound` and
    ///     `.alreadyExists`; if `nil` the typed-error's own embedded name is
    ///     used where available, falling back to `"unknown"`.
    static func map(_ error: Error, id: String? = nil) -> RuntimeError {
        // 1. Pass-through: already a RuntimeError.
        if let re = error as? RuntimeError {
            return re
        }

        // 2. Typed VolumeError cases — exact enum matching, no string sniffing.
        if let ve = error as? VolumeError {
            switch ve {
            case .volumeAlreadyExists(let name):
                return .alreadyExists(id: id ?? name)
            case .volumeNotFound(let name):
                return .notFound(id: id ?? name)
            default:
                return .backendFailure(message: ve.localizedDescription)
            }
        }

        // 3. ContainerizationError — typed code first, then message substring
        //    fallback for cases where the upstream code is `.internalError` but
        //    the human-readable message carries the semantics.
        if let ce = error as? ContainerizationError {
            if RuntimeErrorMapper.isNotFound(ce) {
                return .notFound(id: id ?? "unknown")
            }
            if ce.message.contains("already exists") {
                return .alreadyExists(id: id ?? "unknown")
            }
            if ce.message.contains("not found") {
                return .notFound(id: id ?? "unknown")
            }
            return .backendFailure(message: ce.localizedDescription)
        }

        // 4. NSCocoaError — Foundation file-system errors raised by the volume
        //    image creation path (e.g. NSFileWriteFileExistsError when the
        //    .img file already exists on disk). This is the CHAOS-1413 Layer 1 fix.
        let nsErr = error as NSError
        if nsErr.domain == NSCocoaErrorDomain {
            switch nsErr.code {
            case NSFileWriteFileExistsError:
                return .alreadyExists(id: id ?? "unknown")
            case NSFileNoSuchFileError:
                return .notFound(id: id ?? "unknown")
            default:
                break
            }
        }

        // 5. Default fallback.
        return .backendFailure(message: error.localizedDescription)
    }

    // MARK: - Private helpers

    /// Recursively check whether a `ContainerizationError` (or any error in
    /// its `.cause` chain) carries a `.notFound` code. Mirrors the logic
    /// previously embedded in `BridgeContainerClientRuntime.isNotFound(_:)`.
    private static func isNotFound(_ error: ContainerizationError) -> Bool {
        if error.isCode(.notFound) {
            return true
        }
        if let cause = error.cause as? ContainerizationError {
            return isNotFound(cause)
        }
        return false
    }
}
