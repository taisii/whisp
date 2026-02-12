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
            options: .generation(BenchmarkGenerationRunOptions(
                common: BenchmarkRunCommonOptions(sourceCasesPath: "/tmp/cases.jsonl"),
                llmModel: "gpt-5-nano"
            )),
            metrics: .generation(BenchmarkGenerationRunMetrics(
                counts: BenchmarkRunCounts(
                    casesTotal: 2,
                    casesSelected: 2,
                    executedCases: 2,
                    skippedCases: 0,
                    failedCases: 0
                ),
                avgCER: 0.1
            )),
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

    func testBenchmarkRunRecordCodableRoundtripWithPairwiseFields() throws {
        let pairwise = PairwiseCaseJudgement(
            overallWinner: .a,
            intentWinner: .a,
            hallucinationWinner: .b,
            styleContextWinner: .tie,
            overallReason: "Aが2軸で優位",
            intentReason: "意図保持が高い",
            hallucinationReason: "Bの方が追加情報が少ない",
            styleContextReason: "同等",
            confidence: "medium"
        )
        let record = BenchmarkRunRecord(
            id: "run-pairwise-1",
            kind: .generation,
            status: .completed,
            createdAt: "2026-02-12T10:00:00.000Z",
            updatedAt: "2026-02-12T10:01:00.000Z",
            options: .generationPairwise(BenchmarkGenerationPairwiseRunOptions(
                common: BenchmarkRunCommonOptions(
                    sourceCasesPath: "/tmp/cases.jsonl"
                ),
                pairCandidateAID: "generation-a",
                pairCandidateBID: "generation-b",
                pairJudgeModel: "gpt-5-nano",
                llmModel: "gpt-5-nano|gemini-2.5-flash-lite"
            )),
            benchmarkKey: BenchmarkKey(
                task: .generation,
                datasetPath: "/tmp/cases.jsonl",
                datasetHash: "dataset-hash",
                candidateID: "pair:generation-a__vs__generation-b",
                runtimeOptionsHash: "runtime-hash",
                evaluatorVersion: "pairwise-v1",
                codeVersion: "dev"
            ),
            metrics: .generationPairwise(BenchmarkGenerationPairwiseRunMetrics(
                counts: BenchmarkRunCounts(
                    casesTotal: 1,
                    casesSelected: 1,
                    executedCases: 1,
                    skippedCases: 0,
                    failedCases: 0
                ),
                pairwiseSummary: PairwiseRunSummary(
                    judgedCases: 1,
                    judgeErrorCases: 0,
                    overallAWins: 1,
                    overallBWins: 0,
                    overallTies: 0,
                    intentAWins: 1,
                    intentBWins: 0,
                    intentTies: 0,
                    hallucinationAWins: 0,
                    hallucinationBWins: 1,
                    hallucinationTies: 0,
                    styleContextAWins: 0,
                    styleContextBWins: 0,
                    styleContextTies: 1
                )
            )),
            paths: BenchmarkRunPaths(
                manifestPath: "/tmp/store/manifest.json",
                orchestratorEventsPath: "/tmp/store/orchestrator_events.jsonl",
                casesIndexPath: "/tmp/store/cases_index.jsonl",
                casesDirectoryPath: "/tmp/store/cases"
            )
        )
        let caseResult = BenchmarkCaseResult(
            id: "case-1",
            status: .ok,
            metrics: BenchmarkCaseMetrics(pairwise: pairwise)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let runData = try encoder.encode(record)
        let caseData = try encoder.encode(caseResult)

        let decodedRun = try JSONDecoder().decode(BenchmarkRunRecord.self, from: runData)
        let decodedCase = try JSONDecoder().decode(BenchmarkCaseResult.self, from: caseData)

        XCTAssertEqual(decodedRun, record)
        XCTAssertEqual(decodedCase, caseResult)
        XCTAssertEqual(decodedRun.options.compareMode, .pairwise)
        XCTAssertEqual(decodedRun.options.pairJudgeModel, "gpt-5-nano")
        XCTAssertEqual(decodedCase.metrics.pairwise?.overallWinner, .a)
    }
}
