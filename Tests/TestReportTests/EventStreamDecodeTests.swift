import Foundation
import Testing
@testable import TestReport

@Suite("EventStream foundational types")
struct EventStreamFoundationalDecodeTests {
    @Test("SourceLocation decodes")
    func decodeSourceLocation() throws {
        let json = #"""
        {"_filePath":"<HOST_PATH_REDACTED>","column":6,"fileID":"X/Y.swift","filePath":"<HOST_PATH_REDACTED>","line":57}
        """#
        let loc = try JSONDecoder().decode(EventStream.SourceLocation.self, from: Data(json.utf8))
        #expect(loc.fileID == "X/Y.swift")
        #expect(loc.line == 57)
        #expect(loc.column == 6)
    }

    @Test("Instant decodes")
    func decodeInstant() throws {
        let json = #"{"absolute":349431.79,"since1970":1777927810.5}"#
        let inst = try JSONDecoder().decode(EventStream.Instant.self, from: Data(json.utf8))
        #expect(inst.absolute == 349431.79)
        #expect(inst.since1970 == 1777927810.5)
    }

    @Test("Message decodes")
    func decodeMessage() throws {
        let json = #"{"symbol":"pass","text":"Test passed."}"#
        let msg = try JSONDecoder().decode(EventStream.Message.self, from: Data(json.utf8))
        #expect(msg.symbol == "pass")
        #expect(msg.text == "Test passed.")
    }

    @Test("Issue decodes with sourceLocation")
    func decodeIssue() throws {
        let json = #"""
        {"isFailure":true,"isKnown":false,"severity":"error","sourceLocation":{"_filePath":"x","column":9,"fileID":"Mod/F.swift","filePath":"x","line":7}}
        """#
        let issue = try JSONDecoder().decode(EventStream.Issue.self, from: Data(json.utf8))
        #expect(issue.isFailure == true)
        #expect(issue.isKnown == false)
        #expect(issue.severity == "error")
        #expect(issue.sourceLocation?.line == 7)
    }
}

@Suite("EventStream test catalog payload")
struct EventStreamCatalogDecodeTests {
    @Test("suite payload decodes")
    func decodeSuite() throws {
        let json = #"""
        {"displayName":"Scale Expansion Tests","id":"Mod.ScaleTests","kind":"suite","name":"ScaleTests","sourceLocation":{"_filePath":"x","column":2,"fileID":"Mod/ScaleTests.swift","filePath":"x","line":27}}
        """#
        let payload = try JSONDecoder().decode(EventStream.TestCatalogPayload.self, from: Data(json.utf8))
        #expect(payload.kind == .suite)
        #expect(payload.id == "Mod.ScaleTests")
        #expect(payload.name == "ScaleTests")
        #expect(payload.displayName == "Scale Expansion Tests")
        #expect(payload.isParameterized == nil)
        #expect(payload.sourceLocation.line == 27)
    }

    @Test("function payload decodes with isParameterized")
    func decodeFunction() throws {
        let json = #"""
        {"displayName":"scale = 1","id":"Mod.ScaleTests/scaleOne()/X.swift:57:6","isParameterized":false,"kind":"function","name":"scaleOne()","sourceLocation":{"_filePath":"x","column":6,"fileID":"Mod/ScaleTests.swift","filePath":"x","line":57}}
        """#
        let payload = try JSONDecoder().decode(EventStream.TestCatalogPayload.self, from: Data(json.utf8))
        #expect(payload.kind == .function)
        #expect(payload.name == "scaleOne()")
        #expect(payload.isParameterized == false)
    }
}
