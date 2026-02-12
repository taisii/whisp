import Foundation
import XCTest
@testable import WhispCore

final class BenchmarkTypesTests: XCTestCase {
    func testBenchmarkCaseEventCodableRoundtrip() throws {
        let base = BenchmarkCaseEventBase(
            runID: "run-1",
            caseID: "case-1",
            stage: .judge,
            status: .ok,
            startedAtMs: 100,
            endedAtMs: 140,
            recordedAtMs: 141
        )
        let event = BenchmarkCaseEvent.judge(BenchmarkJudgeLog(
            base: base,
            model: "gpt-5-nano",
            match: true,
            score: 4,
            intentPreservationScore: nil,
            hallucinationScore: nil,
            hallucinationRate: nil,
            requestRef: BenchmarkArtifactRef(
                relativePath: "artifacts/case-1/request.txt",
                mimeType: "text/plain",
                sha256: "abc",
                bytes: 12
            ),
            responseRef: nil,
            error: nil
        ))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        let decoded = try JSONDecoder().decode(BenchmarkCaseEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func testBenchmarkRunRecordCodableRoundtrip() throws {
        let record = BenchmarkRunRecord(
            id: "run-2",
            kind: .generation,
            status: .completed,
            createdAt: "2026-02-11T10:00:00Z",
            updatedAt: "2026-02-11T10:01:00Z",
            options: BenchmarkRunOptions(sourceCasesPath: "/tmp/cases.jsonl", llmModel: "gpt-5-nano"),
            metrics: BenchmarkRunMetrics(
                casesTotal: 2,
                casesSelected: 2,
                executedCases: 2,
                skippedCases: 0,
                failedCases: 0,
                avgCER: 0.1
            ),
            paths: BenchmarkRunPaths(
                manifestPath: "/tmp/store/manifest.json",
                orchestratorEventsPath: "/tmp/store/orchestrator_events.jsonl",
                casesIndexPath: "/tmp/store/cases_index.jsonl",
                casesDirectoryPath: "/tmp/store/cases"
            )
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(BenchmarkRunRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }
}
