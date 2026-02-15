import Foundation
import XCTest
@testable import WhispCore

final class TemporaryOpenAIBenchmarkSmokeTests: XCTestCase {
    private struct BenchmarkPattern: Sendable {
        let benchmarkWorkers: Int
        let compareWorkers: Int
    }

    func testOpenAIRealtimeBenchmarkSmokeSingleCase() async throws {
        let sourcePath = ("~/.config/whisp/debug/manual_test_cases.jsonl" as NSString).expandingTildeInPath
        let singleCasePath = try makeSingleCaseDataset(sourcePath: sourcePath)

        let patterns: [BenchmarkPattern] = [
            BenchmarkPattern(benchmarkWorkers: 1, compareWorkers: 1),
            BenchmarkPattern(benchmarkWorkers: 4, compareWorkers: 2),
        ]

        for pattern in patterns {
            let result = try await runBenchmark(
                datasetPath: singleCasePath,
                pattern: pattern
            )
            print(
                "check=benchmark_smoke[bw=\(pattern.benchmarkWorkers),cw=\(pattern.compareWorkers)]\tstatus=\(result.status)\trun_id=\(result.runID)\texecuted=\(result.executed)\tfailed=\(result.failed)\telapsed_ms=\(result.elapsedMs)"
            )
            XCTAssertGreaterThan(result.executed, 0)
            XCTAssertEqual(result.failed, 0)
        }
    }

    func testOpenAIRealtimeBenchmarkFullDatasetSingleWorker() async throws {
        let datasetPath = ("~/.config/whisp/debug/manual_test_cases.jsonl" as NSString).expandingTildeInPath
        let pattern = BenchmarkPattern(benchmarkWorkers: 1, compareWorkers: 1)
        let result = try await runBenchmark(datasetPath: datasetPath, pattern: pattern)

        print(
            "check=benchmark_full[bw=\(pattern.benchmarkWorkers),cw=\(pattern.compareWorkers)]\tstatus=\(result.status)\trun_id=\(result.runID)\texecuted=\(result.executed)\tfailed=\(result.failed)\telapsed_ms=\(result.elapsedMs)"
        )
        XCTAssertGreaterThanOrEqual(result.executed, 11)
        XCTAssertEqual(result.failed, 0)
    }

    func testOpenAIRealtimeBenchmarkFullDatasetParallelWorkers() async throws {
        let datasetPath = ("~/.config/whisp/debug/manual_test_cases.jsonl" as NSString).expandingTildeInPath
        let pattern = BenchmarkPattern(benchmarkWorkers: 4, compareWorkers: 2)
        let result = try await runBenchmark(datasetPath: datasetPath, pattern: pattern)

        print(
            "check=benchmark_full[bw=\(pattern.benchmarkWorkers),cw=\(pattern.compareWorkers)]\tstatus=\(result.status)\trun_id=\(result.runID)\texecuted=\(result.executed)\tfailed=\(result.failed)\telapsed_ms=\(result.elapsedMs)"
        )
        XCTAssertGreaterThanOrEqual(result.executed, 11)
        XCTAssertEqual(result.failed, 0)
    }

    private func makeSingleCaseDataset(sourcePath: String) throws -> String {
        let sourceText = try String(contentsOfFile: sourcePath, encoding: .utf8)
        guard let firstLine = sourceText.split(separator: "\n", omittingEmptySubsequences: true).first else {
            throw AppError.invalidArgument("manual test case がありません")
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "whisp-openai-smoke-\(UUID().uuidString).jsonl",
            isDirectory: false
        )
        try "\(firstLine)\n".write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL.path
    }

    private func runBenchmark(
        datasetPath: String,
        pattern: BenchmarkPattern
    ) async throws -> (status: String, runID: String, executed: Int, failed: Int, elapsedMs: Int) {
        let store = BenchmarkStore()
        let beforeIDs = Set(try store.listRuns(limit: 100).map(\.id))
        try clearBenchmarkCache()

        let request = BenchmarkExecutionRequest(
            flow: .stt,
            datasetPath: datasetPath,
            candidateIDs: ["stt-chatgpt-whisper-stream-default"],
            force: true,
            benchmarkWorkers: pattern.benchmarkWorkers,
            compareWorkers: pattern.compareWorkers
        )

        let startedAt = Date()
        try await BenchmarkExecutionService().runCompare(request: request)
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)

        let afterRuns = try store.listRuns(limit: 100)
        guard let matched = afterRuns.first(where: {
            $0.kind == .stt &&
                $0.candidateID == "stt-chatgpt-whisper-stream-default" &&
                !beforeIDs.contains($0.id)
        }) else {
            throw AppError.io("benchmark run が見つかりません")
        }

        guard case let .stt(metrics) = matched.metrics else {
            throw AppError.io("benchmark metrics が stt ではありません")
        }

        return (
            matched.status.rawValue,
            matched.id,
            metrics.counts.executedCases,
            metrics.counts.failedCases,
            elapsedMs
        )
    }

    private func clearBenchmarkCache() throws {
        let cacheRoot = try WhispPaths().benchmarkCacheDirectory
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: cacheRoot.path) {
            try fileManager.removeItem(at: cacheRoot)
        }
    }
}
