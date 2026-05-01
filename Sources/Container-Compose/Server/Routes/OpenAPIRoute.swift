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

import Foundation
import Hummingbird
import NIOCore

/// CHAOS-1357 — `GET /openapi.yaml` serving the hand-written OpenAPI 3.1 spec.
///
/// The YAML file is bundled as a SwiftPM resource on `ContainerComposeCore`
/// via `resources: [.copy("Resources/openapi.yaml")]` in Package.swift.
/// Reads via `Bundle.module` so the path resolves correctly in both
/// test and production contexts.
public enum OpenAPIRoute {
    public static func register(router: Router<BasicRequestContext>) {
        router.get("/openapi.yaml") { _, _ -> Response in
            guard let url = Bundle.module.url(forResource: "openapi", withExtension: "yaml"),
                  let contents = try? Data(contentsOf: url) else {
                // Spec not found — return a minimal error (plain text, not envelope,
                // since this is a static resource delivery failure).
                var buf = ByteBuffer()
                buf.writeString("openapi.yaml not found")
                return Response(
                    status: .notFound,
                    headers: [.contentType: "text/plain"],
                    body: ResponseBody(byteBuffer: buf)
                )
            }
            var buffer = ByteBuffer()
            buffer.writeBytes(contents)
            return Response(
                status: .ok,
                headers: [.contentType: "application/yaml"],
                body: ResponseBody(byteBuffer: buffer)
            )
        }
    }
}
