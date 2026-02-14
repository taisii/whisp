import ArgumentParser
import Foundation
import WhispCore

struct DebugBenchmarkIntegrityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark-integrity",
        abstract: "Run read-only integrity diagnostics against dataset"
    )

    @Option(name: .long, help: "Task to validate")
    var task: CLIBenchmarkTask

    @Option(name: .long, help: "Manual cases JSONL path")
    var cases: String

    @Option(name: .long, help: "Output format")
    var format: CLIOutputFormat = .text

    mutating func run() async throws {
        let service = BenchmarkDiagnosticsService()
        let resolvedCasesPath = WhispPaths.normalizeForStorage(cases)
        let snapshot = try service.loadIntegritySnapshot(task: task.kind, casesPath: resolvedCasesPath)

        switch format {
        case .json:
            try writeCLIJSON(snapshot)
        case .text:
            print("mode: benchmark_integrity")
            print("task: \(snapshot.task)")
            print("cases: \(resolvedCasesPath)")
            print("issues_total: \(snapshot.totalIssues)")
            print("severity_counts:")
            if snapshot.severityCounts.isEmpty {
                print("- (none)")
            } else {
                for item in snapshot.severityCounts {
                    print("- \(item.severity): \(item.count)")
                }
            }
        }
    }
}
