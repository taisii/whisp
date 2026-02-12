import Foundation
import XCTest
@testable import WhispCore

final class BenchmarkStoreTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(home: URL) -> BenchmarkStore {
        BenchmarkStore(environment: ["HOME": home.path])
    }

    private func makeRun(store: BenchmarkStore, runID: String = "bench-20260211-001") -> BenchmarkRunRecord {
        let paths = store.resolveRunPaths(runID: runID)

        return BenchmarkRunRecord(
            id: runID,
            kind: .stt,
            status: .completed,
            createdAt: "2026-02-11T12:00:00Z",
            updatedAt: "2026-02-11T12:01:00Z",
            options: BenchmarkRunOptions(
                sourceCasesPath: "/tmp/manual.jsonl",
                sttMode: "stream",
                chunkMs: 120,
                realtime: true,
                useCache: true
            ),
            metrics: BenchmarkRunMetrics(
                casesTotal: 10,
                casesSelected: 10,
                executedCases: 8,
                skippedCases: 1,
                failedCases: 1,
                cachedHits: 3,
                exactMatchRate: 0.75,
                avgCER: 0.1
            ),
            paths: paths
        )
    }

    func testSaveAndListRuns() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let run = makeRun(store: store)

        try store.saveRun(run)

        let listed = try store.listRuns(limit: 10)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, run.id)
        XCTAssertEqual(listed.first?.kind, .stt)

        let loaded = try store.loadRun(runID: run.id)
        XCTAssertEqual(loaded, run)
    }

    func testAppendAndLoadCaseResultsAndEvents() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let runID = "bench-20260211-002"
        try store.saveRun(makeRun(store: store, runID: runID))

        let caseResult = BenchmarkCaseResult(
            id: "case-1",
            status: .ok,
            cache: BenchmarkCacheRecord(hit: true, key: "abc123", namespace: "generation"),
            sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold", intent: "labels.intent_gold"),
            contextUsed: true,
            visionImageAttached: false,
            metrics: BenchmarkCaseMetrics(
                cer: 0.08,
                intentMatch: true,
                intentScore: 4,
                totalAfterStopMs: 412.0
            )
        )
        try store.appendCaseResult(runID: runID, result: caseResult)

        let base = BenchmarkCaseEventBase(
            runID: runID,
            caseID: "case-1",
            stage: .aggregate,
            status: .ok,
            startedAtMs: 1,
            endedAtMs: 2,
            recordedAtMs: 3
        )
        try store.appendEvent(
            runID: runID,
            event: .aggregate(BenchmarkAggregateLog(
                base: base,
                exactMatch: false,
                cer: 0.08,
                intentMatch: true,
                intentScore: 4,
                intentPreservationScore: nil,
                hallucinationScore: nil,
                hallucinationRate: nil,
                latencyMs: nil,
                totalAfterStopMs: 412,
                outputChars: 120
            ))
        )

        let rows = try store.loadCaseResults(runID: runID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "case-1")
        XCTAssertEqual(rows.first?.cache?.hit, true)
        XCTAssertEqual(rows.first?.metrics.intentScore, 4)

        let events = try store.loadEvents(runID: runID, caseID: "case-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.base.stage, .aggregate)
    }

    func testArtifactRoundtrip() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let runID = "bench-20260211-003"
        try store.saveRun(makeRun(store: store, runID: runID))

        let data = Data("artifact body".utf8)
        let ref = try store.writeArtifact(
            runID: runID,
            caseID: "case-3",
            fileName: "prompt.txt",
            mimeType: "text/plain",
            data: data
        )

        let restored = try store.loadArtifactText(runID: runID, ref: ref)
        XCTAssertEqual(restored, "artifact body")
        XCTAssertTrue(ref.relativePath.contains("cases/case-3/artifacts"))
    }

    func testCaseArtifactsDirectoryIsNotCreatedWhenUnused() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let runID = "bench-20260211-003b"
        let caseID = "case-no-artifacts"
        try store.saveRun(makeRun(store: store, runID: runID))

        try store.appendCaseResult(
            runID: runID,
            result: BenchmarkCaseResult(
                id: caseID,
                status: .ok,
                cache: BenchmarkCacheRecord(hit: false, namespace: "stt"),
                sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
                contextUsed: false,
                visionImageAttached: false,
                metrics: BenchmarkCaseMetrics(cer: 0.1, sttTotalMs: 500, sttAfterStopMs: 80)
            )
        )

        let casePaths = store.resolveCasePaths(runID: runID, caseID: caseID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: casePaths.artifactsDirectoryPath))
    }

    func testErrorEventCreatesArtifactsDirectoryOnDemand() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let runID = "bench-20260211-003c"
        let caseID = "case-error-artifact"
        try store.saveRun(makeRun(store: store, runID: runID))

        let base = BenchmarkCaseEventBase(
            runID: runID,
            caseID: caseID,
            stage: .error,
            status: .error,
            startedAtMs: 10,
            endedAtMs: 20,
            recordedAtMs: 21
        )
        try store.appendEvent(
            runID: runID,
            event: .error(BenchmarkErrorLog(
                base: base,
                originStage: .stt,
                errorType: "stt_case_error",
                message: "boom"
            ))
        )

        let casePaths = store.resolveCasePaths(runID: runID, caseID: caseID)
        let errorPath = URL(fileURLWithPath: casePaths.artifactsDirectoryPath, isDirectory: true)
            .appendingPathComponent("error.json", isDirectory: false).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: casePaths.artifactsDirectoryPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: errorPath))
    }

    func testDeleteRunRemovesDirectory() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let runID = "bench-20260211-004"

        try store.saveRun(makeRun(store: store, runID: runID))
        try store.deleteRun(runID: runID)

        let loaded = try store.loadRun(runID: runID)
        XCTAssertNil(loaded)
    }

    func testFindLatestCompletedRunByBenchmarkKey() throws {
        let home = tempHome()
        let store = makeStore(home: home)

        let key = BenchmarkKey(
            task: .stt,
            datasetPath: "/tmp/manual.jsonl",
            datasetHash: "hash-a",
            candidateID: "stt-a",
            runtimeOptionsHash: "runtime-a",
            evaluatorVersion: "v1",
            codeVersion: "dev"
        )

        let olderID = "bench-20260211-005"
        var older = makeRun(store: store, runID: olderID)
        older.candidateID = "stt-a"
        older.benchmarkKey = key
        older.updatedAt = "2026-02-11T12:00:00Z"
        try store.saveRun(older)

        let newerID = "bench-20260211-006"
        var newer = makeRun(store: store, runID: newerID)
        newer.candidateID = "stt-a"
        newer.benchmarkKey = key
        newer.updatedAt = "2026-02-11T12:30:00Z"
        try store.saveRun(newer)

        let found = try store.findLatestCompletedRun(matching: key)
        XCTAssertEqual(found?.id, newerID)
    }
}
