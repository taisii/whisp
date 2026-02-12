import Foundation
import XCTest
import WhispCore
@testable import whisp

final class BenchmarkPersistenceTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSaveBenchmarkRunPersistsRunCasesAndEvents() throws {
        let home = tempHome()
        let runID = "stt-20260211-000000-000-aaaa1111"
        let env = ["HOME": home.path]

        let caseResult = BenchmarkCaseResult(
            id: "case-1",
            status: .ok,
            reason: nil,
            cache: BenchmarkCacheRecord(hit: true, key: "cache-key", namespace: "stt"),
            sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
            contextUsed: false,
            visionImageAttached: false,
            metrics: BenchmarkCaseMetrics(
                exactMatch: true,
                cer: 0,
                sttTotalMs: 120,
                sttAfterStopMs: 40,
                latencyMs: 120,
                outputChars: 32
            )
        )

        let base = WhispCLI.makeEventBase(
            runID: runID,
            caseID: "case-1",
            stage: .aggregate,
            status: .ok,
            seed: 1
        )
        let event = BenchmarkCaseEvent.aggregate(BenchmarkAggregateLog(
            base: base,
            exactMatch: true,
            cer: 0,
            intentMatch: nil,
            intentScore: nil,
            intentPreservationScore: nil,
            hallucinationScore: nil,
            hallucinationRate: nil,
            latencyMs: 120,
            totalAfterStopMs: 40,
            outputChars: 32
        ))

        _ = try WhispCLI.saveBenchmarkRun(
            runID: runID,
            kind: .stt,
            options: BenchmarkRunOptions(sourceCasesPath: "/tmp/manual.jsonl", sttMode: "stream"),
            metrics: BenchmarkRunMetrics(
                casesTotal: 1,
                casesSelected: 1,
                executedCases: 1,
                skippedCases: 0,
                failedCases: 0,
                cachedHits: 1,
                exactMatchRate: 1,
                avgCER: 0,
                weightedCER: 0,
                latencyMs: BenchmarkLatencyDistribution(avg: 120, p50: 120, p95: 120, p99: 120)
            ),
            caseResults: [caseResult],
            events: [event],
            environment: env
        )

        let store = BenchmarkStore(environment: env)
        let run = try store.loadRun(runID: runID)
        XCTAssertNotNil(run)
        XCTAssertEqual(run?.id, runID)

        let rows = try store.loadCaseResults(runID: runID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "case-1")
        XCTAssertEqual(rows.first?.metrics.cer, 0)

        let events = try store.loadEvents(runID: runID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.base.stage, .aggregate)
    }
}
