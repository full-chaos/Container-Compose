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

import Testing
@testable import ContainerComposeCore

@Suite("GoTemplateRendering Tests")
struct GoTemplateRenderingTests {
    @Test("Empty template returns empty")
    func emptyTemplateReturnsEmpty() {
        #expect(renderGoTemplate("", env: ["USER": "alice"]) == "")
    }

    @Test("No placeholders returns input unchanged")
    func noPlaceholdersReturnsInputUnchanged() {
        #expect(renderGoTemplate("hello world", env: ["USER": "alice"]) == "hello world")
    }

    @Test("Dotted variable substitutes from env")
    func dottedVariableSubstitutesFromEnv() {
        #expect(renderGoTemplate("hello {{ .USER }}", env: ["USER": "alice"]) == "hello alice")
    }

    @Test("Dotted service context substitutes from context")
    func dottedServiceContextSubstitutesFromContext() {
        #expect(renderGoTemplate("service {{ .Service.Name }}", env: [:], context: ["Service.Name": "web"]) == "service web")
    }

    @Test("Missing dotted variable substitutes empty string")
    func missingDottedVariableSubstitutesEmptyString() {
        #expect(renderGoTemplate("hello {{ .MISSING }}", env: [:]) == "hello ")
    }

    @Test("Env function substitutes from env")
    func envFunctionSubstitutesFromEnv() {
        #expect(renderGoTemplate("hello {{ env \"USER\" }}", env: ["USER": "alice"]) == "hello alice")
    }

    @Test("Default pipeline uses fallback when var is missing")
    func defaultPipelineUsesFallbackWhenVarIsMissing() {
        #expect(renderGoTemplate("hello {{ .USER | default \"fallback\" }}", env: [:]) == "hello fallback")
    }

    @Test("Default pipeline uses env value when var is present")
    func defaultPipelineUsesEnvValueWhenVarIsPresent() {
        #expect(renderGoTemplate("hello {{ .USER | default \"fallback\" }}", env: ["USER": "alice"]) == "hello alice")
    }

    @Test("Multiple placeholders substitute independently")
    func multiplePlaceholdersSubstituteIndependently() {
        let template = "{{ .GREETING }}, {{ env \"USER\" }} from {{ .CITY | default \"Paris\" }}"
        let env = ["GREETING": "hello", "USER": "alice"]

        #expect(renderGoTemplate(template, env: env) == "hello, alice from Paris")
    }

    @Test("Whitespace around expressions is tolerated")
    func whitespaceAroundExpressionsIsTolerated() {
        let template = "{{.USER}}|{{  .USER  }}|{{ .USER}}"

        #expect(renderGoTemplate(template, env: ["USER": "alice"]) == "alice|alice|alice")
    }

    @Test("Unsupported syntax passes through unchanged")
    func unsupportedSyntaxPassesThroughUnchanged() {
        let template = "{{ if .X }}foo{{ end }}"

        #expect(renderGoTemplate(template, env: ["X": "true"]) == template)
    }
}
