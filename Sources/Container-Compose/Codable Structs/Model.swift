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
//  Model.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a top-level model definition.
public struct Model: Codable, Hashable {
    /// Custom name for this model.
    public let name: String?

    /// Language model to run.
    public let model: String?

    /// Optional model tag used by some provider implementations.
    public let tag: String?

    /// Context size to configure for the model runtime.
    public let context_size: Int?

    /// Raw runtime flags to pass to the inference engine.
    public let runtime_flags: [String]?

    enum CodingKeys: String, CodingKey {
        case name, model, tag, context_size, runtime_flags
    }

    public init(
        name: String? = nil,
        model: String? = nil,
        tag: String? = nil,
        context_size: Int? = nil,
        runtime_flags: [String]? = nil
    ) {
        self.name = name
        self.model = model
        self.tag = tag
        self.context_size = context_size
        self.runtime_flags = runtime_flags
    }
}
