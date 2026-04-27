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
import Foundation
@testable import Yams
@testable import ContainerComposeCore

@Suite("DependsOn Parsing Tests")
struct DependsOnParsingTests {

    // Wrapper used for object-form decoding where depends_on is a keyed map.
    private struct Wrapper: Decodable {
        let depends_on: DependsOn
    }

    // MARK: - Test 1: List form

    @Test("List form: [db, redis] produces 2 entries with serviceStarted defaults")
    func listForm() throws {
        let yaml = """
        - db
        - redis
        """
        let result = try YAMLDecoder().decode(DependsOn.self, from: yaml)
        #expect(result.entries.count == 2)
        #expect(result.entries["db"]?.condition == .serviceStarted)
        #expect(result.entries["db"]?.required == true)
        #expect(result.entries["db"]?.restart == false)
        #expect(result.entries["redis"]?.condition == .serviceStarted)
        #expect(result.entries["redis"]?.required == true)
        #expect(result.entries["redis"]?.restart == false)
    }

    // MARK: - Test 2: Single string form

    @Test("Single string form: 'db' produces 1 entry with serviceStarted defaults")
    func singleStringForm() throws {
        let yaml = "db"
        let result = try YAMLDecoder().decode(DependsOn.self, from: yaml)
        #expect(result.entries.count == 1)
        #expect(result.entries["db"]?.condition == .serviceStarted)
    }

    // MARK: - Test 3: Object form full

    @Test("Object form full: db with condition service_healthy, required true, restart true")
    func objectFormFull() throws {
        let yaml = """
        depends_on:
          db:
            condition: service_healthy
            required: true
            restart: true
        """
        let wrapper = try YAMLDecoder().decode(Wrapper.self, from: yaml)
        let entry = wrapper.depends_on.entries["db"]
        #expect(entry?.condition == .serviceHealthy)
        #expect(entry?.required == true)
        #expect(entry?.restart == true)
    }

    // MARK: - Test 4: Object form with defaults

    @Test("Object form with only condition: required defaults to true, restart defaults to false")
    func objectFormWithDefaults() throws {
        let yaml = """
        depends_on:
          db:
            condition: service_healthy
        """
        let wrapper = try YAMLDecoder().decode(Wrapper.self, from: yaml)
        let entry = wrapper.depends_on.entries["db"]
        #expect(entry?.condition == .serviceHealthy)
        #expect(entry?.required == true)
        #expect(entry?.restart == false)
    }

    // MARK: - Test 5: All 3 condition enum values

    @Test("Object form with all 3 condition enum values")
    func allConditionEnumValues() throws {
        let yaml = """
        depends_on:
          svc_started:
            condition: service_started
          svc_healthy:
            condition: service_healthy
          svc_completed:
            condition: service_completed_successfully
        """
        let wrapper = try YAMLDecoder().decode(Wrapper.self, from: yaml)
        #expect(wrapper.depends_on.entries["svc_started"]?.condition == .serviceStarted)
        #expect(wrapper.depends_on.entries["svc_healthy"]?.condition == .serviceHealthy)
        #expect(wrapper.depends_on.entries["svc_completed"]?.condition == .serviceCompletedSuccessfully)
    }

    // MARK: - Test 6: restart as string "true"

    @Test("restart as string \"true\" decodes as Bool true")
    func restartStringTrue() throws {
        let yaml = """
        depends_on:
          db:
            condition: service_started
            restart: "true"
        """
        let wrapper = try YAMLDecoder().decode(Wrapper.self, from: yaml)
        #expect(wrapper.depends_on.entries["db"]?.restart == true)
    }

    // MARK: - Test 7: restart as string "false"

    @Test("restart as string \"false\" decodes as Bool false")
    func restartStringFalse() throws {
        let yaml = """
        depends_on:
          db:
            condition: service_started
            restart: "false"
        """
        let wrapper = try YAMLDecoder().decode(Wrapper.self, from: yaml)
        #expect(wrapper.depends_on.entries["db"]?.restart == false)
    }

    // MARK: - Test 8: Missing condition throws

    @Test("Missing condition throws a DecodingError")
    func missingConditionThrows() throws {
        let yaml = """
        depends_on:
          db:
            required: true
        """
        #expect(throws: Error.self) {
            try YAMLDecoder().decode(Wrapper.self, from: yaml)
        }
    }

    // MARK: - Test 9: DependsOn.list helper matches list-form decoder

    @Test("DependsOn.list([...]) produces the same result as the list-form decoder")
    func listHelperMatchesDecoder() throws {
        let yaml = """
        - db
        - redis
        """
        let decoded = try YAMLDecoder().decode(DependsOn.self, from: yaml)
        let fromHelper = DependsOn.list(["db", "redis"])

        // Both should have same entries
        #expect(fromHelper.entries.count == decoded.entries.count)
        #expect(fromHelper.entries["db"]?.condition == decoded.entries["db"]?.condition)
        #expect(fromHelper.entries["db"]?.required == decoded.entries["db"]?.required)
        #expect(fromHelper.entries["db"]?.restart == decoded.entries["db"]?.restart)
        #expect(fromHelper.entries["redis"]?.condition == decoded.entries["redis"]?.condition)
    }

    // MARK: - Test 10: DependsOnEntry memberwise default values

    @Test("DependsOnEntry.init(condition:) memberwise defaults are required=true, restart=false")
    func entryMemberwiseDefaults() {
        let entry = DependsOnEntry(condition: .serviceStarted)
        #expect(entry.condition == .serviceStarted)
        #expect(entry.required == true)
        #expect(entry.restart == false)
    }
}
