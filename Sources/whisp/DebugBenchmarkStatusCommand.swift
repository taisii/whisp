import ArgumentParser
import Foundation
import WhispCore

func loadCasesCountForStatus(path: String, datasetStore: BenchmarkDatasetStore = BenchmarkDatasetStore()) -> Int? {
    do {
        return try datasetStore.loadCases(path: path).count
    } catch {
        return nil
    }
}

struct DebugBenchmarkStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark-status",
        abstract: "Show benchmark candidates and latest run status"
    )

    @Option(name: .long, help: "Manual cases JSONL path")
    var cases: String?

    @Option(name: .long, help: "Output format")
    var format: CLIOutputFormat = .text

    mutating func run() async throws {
        let service = BenchmarkDiagnosticsService()
        let snapshot = try service.loadStatusSnapshot()

        switch format {
        case .json:
            try writeCLIJSON(snapshot)
        case .text:
            let resolvedCasesPath = WhispPaths.normalizeForStorage(cases ?? service.defaultCasesPath())
            let casesCount = loadCasesCountForStatus(path: resolvedCasesPath)

            print("mode: benchmark_status")
            print("generated_at: \(snapshot.generatedAt)")
            print("cases: \(resolvedCasesPath)")
            print("cases_total: \(casesCount.map(String.init) ?? "unknown")")
            print("candidate_counts:")
            for item in snapshot.candidateCounts {
                print("- \(item.task): \(item.count)")
            }
            print("latest_runs:")
            if snapshot.latestRuns.isEmpty {
                print("- (none)")
            } else {
                for run in snapshot.latestRuns {
                    print("- \(run.task): id=\(run.runID) status=\(run.status) created_at=\(run.createdAt)")
                }
            }
        }
    }
}
