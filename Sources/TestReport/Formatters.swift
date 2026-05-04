import Foundation

public enum ReportFormat: String, Sendable {
    case json
    case human
}

public enum Formatters {
    public static func render(_ run: TestRun, format: ReportFormat, includePassed: Bool = false) throws -> String {
        switch format {
        case .json:
            return try renderJSON(run)
        case .human:
            return renderHuman(run, includePassed: includePassed)
        }
    }

    private static func renderJSON(_ run: TestRun) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        return String(decoding: data, as: UTF8.self)
    }

    private static func renderHuman(_ run: TestRun, includePassed: Bool) -> String {
        var lines: [String] = []
        let s = run.summary
        let runState = s.runCompleted ? "completed" : "incomplete"
        lines.append("Test run \(runState) — \(s.passed) passed, \(s.failed) failed, \(s.skipped) skipped (in \(String(format: "%.3f", s.durationSeconds))s)")
        if let v = run.toolchainVersion {
            lines.append("  toolchain: swift-testing \(v)")
        }
        if s.malformedLineCount > 0 {
            lines.append("  warning: skipped \(s.malformedLineCount) malformed event line(s)")
        }
        if !run.unknownEventKinds.isEmpty {
            lines.append("  warning: unknown event kinds: \(run.unknownEventKinds.joined(separator: ", "))")
        }

        if !run.failures.isEmpty {
            lines.append("")
            lines.append("FAILED (\(run.failures.count)):")
            for f in run.failures {
                let label = f.displayName ?? f.testID
                lines.append("  ✘ \(label)  [\(f.testID)]")
                if let loc = f.sourceLocation {
                    lines.append("      at \(loc.fileID):\(loc.line):\(loc.column)")
                }
                for issue in f.issues {
                    lines.append("      - \(issue.message)")
                }
            }
        }

        if !run.skipped.isEmpty {
            lines.append("")
            lines.append("SKIPPED (\(run.skipped.count)):")
            for sk in run.skipped {
                lines.append("  - \(sk.displayName ?? sk.testID)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
