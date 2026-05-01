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

import Crypto
import Foundation

// MARK: - APIKeyGenerator

public enum APIKeyGenerator {

    /// Generates a fresh API key.
    ///
    /// - Returns: `(rawToken, hashHex)`. The raw token is shown to the user
    ///   once; the hash is persisted.
    ///
    /// Token format: `cc_v1_<base64url-no-padding>` where the base64url
    /// payload encodes 32 random bytes.
    public static func generate() -> (rawToken: String, hashHex: String) {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let base64URL = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "cc_v1_" + base64URL

        return (rawToken: token, hashHex: hash(rawToken: token))
    }

    /// Hashes an externally provided token.
    public static func hash(rawToken: String) -> String {
        let digest = SHA256.hash(data: Data(rawToken.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
