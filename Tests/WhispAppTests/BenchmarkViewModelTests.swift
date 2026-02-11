import Foundation
import XCTest
import WhispCore
@testable import WhispApp

@MainActor
final class BenchmarkViewModelTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRun(store: BenchmarkStore, runID: String) -> BenchmarkRunRecord {
        var paths = store.resolveRunPaths(runID: runID)
        paths.logDirectoryPath = "/tmp/logs"
        paths.rowsFilePath = "/tmp/logs/rows.jsonl"
        paths.summaryFilePath = "/tmp/logs/summary.json"
        return BenchmarkRunRecord(
            id: runID,
            kind: .generation,
            status: .completed,
            createdAt: "2026-02-11T00:00:00Z",
            updatedAt: "2026-02-11T00:01:00Z",
            options: BenchmarkRunOptions(sourceCasesPath: "/tmp/cases.jsonl"),
            metrics: BenchmarkRunMetrics(
                casesTotal: 1,
                casesSelected: 1,
                executedCases: 1,
                skippedCases: 0,
                failedCases: 0
            ),
            paths: paths
        )
    }

    func testRefreshLoadsRunsCasesAndEvents() throws {
        let home = tempHome()
        let store = BenchmarkStore(environment: ["HOME": home.path])
        let run = makeRun(store: store, runID: "run-1")
        try store.saveRun(run)

        try store.appendCaseResult(
            runID: run.id,
            result: BenchmarkCaseResult(
                id: "case-1",
                status: .ok,
                metrics: BenchmarkCaseMetrics(cer: 0.1)
            )
        )

        let base = BenchmarkCaseEventBase(
            runID: run.id,
            caseID: "case-1",
            stage: .aggregate,
            status: .ok,
            startedAtMs: 1,
            endedAtMs: 2,
            recordedAtMs: 3
        )
        try store.appendEvent(
            runID: run.id,
            event: .aggregate(BenchmarkAggregateLog(
                base: base,
                exactMatch: false,
                cer: 0.1,
                intentMatch: nil,
                intentScore: nil,
                latencyMs: nil,
                totalAfterStopMs: 320,
                outputChars: 100
            ))
        )

        let viewModel = BenchmarkViewModel(store: store)
        viewModel.refresh()

        XCTAssertEqual(viewModel.runs.count, 1)
        XCTAssertEqual(viewModel.cases.count, 1)
        XCTAssertEqual(viewModel.events.count, 1)
        XCTAssertEqual(viewModel.selectedRunID, "run-1")
        XCTAssertEqual(viewModel.selectedCaseID, "case-1")
    }

    func testSelectingEventLoadsArtifactPreview() throws {
        let home = tempHome()
        let store = BenchmarkStore(environment: ["HOME": home.path])
        let run = makeRun(store: store, runID: "run-2")
        try store.saveRun(run)

        try store.appendCaseResult(
            runID: run.id,
            result: BenchmarkCaseResult(
                id: "case-2",
                status: .ok
            )
        )

        let ref = try store.writeArtifact(
            runID: run.id,
            caseID: "case-2",
            fileName: "request.txt",
            mimeType: "text/plain",
            data: Data("judge request".utf8)
        )

        let base = BenchmarkCaseEventBase(
            runID: run.id,
            caseID: "case-2",
            stage: .judge,
            status: .ok,
            startedAtMs: 11,
            endedAtMs: 12,
            recordedAtMs: 13
        )
        try store.appendEvent(
            runID: run.id,
            event: .judge(BenchmarkJudgeLog(
                base: base,
                model: "gpt-5-nano",
                match: true,
                score: 4,
                requestRef: ref,
                responseRef: nil,
                error: nil
            ))
        )

        let viewModel = BenchmarkViewModel(store: store)
        viewModel.refresh()
        viewModel.selectEvent(index: 0)

        XCTAssertEqual(viewModel.artifactPanels.count, 1)
        XCTAssertTrue(viewModel.artifactPanels[0].text.contains("judge request"))
    }
}
