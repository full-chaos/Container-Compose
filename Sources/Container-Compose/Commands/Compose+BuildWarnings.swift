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

func warnUnsupportedContainerBuildFields(_ buildConfig: Build, serviceName: String) {
    if let cacheFrom = buildConfig.cache_from, !cacheFrom.isEmpty {
        warnUnsupportedRuntimeFieldOnce(
            "build.cache_from",
            "Note: 'build.cache_from' is parsed but not supported by Apple container's build; ignored."
        )
    }

    if let cacheTo = buildConfig.cache_to, !cacheTo.isEmpty {
        warnUnsupportedRuntimeFieldOnce(
            "build.cache_to",
            "Note: 'build.cache_to' is parsed but not supported by Apple container's build; ignored."
        )
    }

    if buildConfig.network != nil {
        warnUnsupportedRuntimeFieldOnce(
            "build.network",
            "Note: 'build.network' is parsed but not supported by Apple container's build; ignored."
        )
    }

    if let ssh = buildConfig.ssh, !ssh.isEmpty {
        warnUnsupportedRuntimeFieldOnce(
            "build.ssh",
            "Note: 'build.ssh' is parsed but not supported by Apple container's build; ignored."
        )
    }

    if buildConfig.shm_size != nil {
        warnUnsupportedRuntimeFieldOnce(
            "build.shm_size",
            "Note: 'build.shm_size' is parsed but not supported by Apple container's build; ignored."
        )
    }

    if let entitlements = buildConfig.entitlements, !entitlements.isEmpty {
        warnUnsupportedRuntimeFieldOnce(
            "build.entitlements",
            "Warning: 'build.entitlements' [\(entitlements.joined(separator: ", "))] Detected, But Not Supported for service '\(serviceName)'. Entitlements will be ignored."
        )
    }
}
