import Foundation
import WhispCore

extension WhispCLI {
    static func executeBenchmarkRunLifecycle<Summary: Sendable>(
        selectedCases: [ManualBenchmarkCase],
        recorder: BenchmarkRunRecorder,
        runWorkers: @escaping () async throws -> Void,
        snapshotSummary: @escaping () async -> Summary,
        makeMetrics: @escaping (Summary) -> BenchmarkRunMetrics,
        makeRunOptions: @escaping (Summary) -> BenchmarkRunOptions
    ) async throws -> (summary: Summary, metrics: BenchmarkRunMetrics, run: BenchmarkRunRecord) {
        for item in selectedCases {
            try recorder.markCaseQueued(caseID: item.id)
        }

        do {
            try await runWorkers()
        } catch {
            let partial = await snapshotSummary()
            let failedMetrics = makeMetrics(partial)
            let failedOptions = makeRunOptions(partial)
            _ = try? recorder.finalize(metrics: failedMetrics, options: failedOptions, status: .failed)
            throw error
        }

        let summary = await snapshotSummary()
        let metrics = makeMetrics(summary)
        let options = makeRunOptions(summary)
        let run = try recorder.finalize(metrics: metrics, options: options, status: .completed)
        return (summary: summary, metrics: metrics, run: run)
    }
}
