import ArgumentParser
import Foundation
import TestReport

@main
struct TestReportCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-report",
        abstract: "Summarize a swift-testing event-stream JSONL into JSON or human-readable text."
    )

    @Argument(help: "Path to a .jsonl file produced by `swift test --experimental-event-stream-output`.")
    var eventsPath: String

    @Option(name: .long, help: "Output format: 'json' or 'human'.")
    var format: ReportFormat = .human

    @Flag(name: .long, help: "Include passing tests in the human output.")
    var includePassed: Bool = false

    mutating func run() throws {
        let url = URL(fileURLWithPath: eventsPath)
        let readResult: Reader.Result
        do {
            readResult = try Reader.read(from: url)
        } catch Reader.Error.fileNotFound {
            FileHandle.standardError.write(Data("test-report: events file not found at \(url.path) — did 'swift test' fail to start? compile error?\n".utf8))
            throw ExitCode(2)
        }

        if readResult.records.isEmpty && readResult.malformedLineCount == 0 {
            FileHandle.standardError.write(Data("test-report: events file is empty — 'swift test' may have crashed before emitting any events\n".utf8))
            throw ExitCode(2)
        }

        let run = Aggregator.aggregate(records: readResult.records, malformedLineCount: readResult.malformedLineCount)
        let rendered = try Formatters.render(run, format: format, includePassed: includePassed)
        print(rendered, terminator: "")

        if run.summary.failed > 0 {
            throw ExitCode(1)
        }
    }
}

extension ReportFormat: ExpressibleByArgument {}
