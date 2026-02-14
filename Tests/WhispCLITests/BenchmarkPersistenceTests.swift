import Foundation
import XCTest
import WhispCore

final class BenchmarkPersistenceTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRunRecord(
        runID: String,
        kind: BenchmarkKind,
        createdAt: String,
        store: BenchmarkStore
    ) -> BenchmarkRunRecord {
        BenchmarkRunRecord(
            id: runID,
            kind: kind,
            status: .completed,
            createdAt: createdAt,
            updatedAt: createdAt,
            options: .stt(BenchmarkSTTRunOptions(
                common: BenchmarkRunCommonOptions(sourceCasesPath: "/tmp/manual.jsonl"),
                sttMode: "stream"
            )),
            metrics: .stt(BenchmarkSTTRunMetrics(
                counts: BenchmarkRunCounts(
                    casesTotal: 1,
                    casesSelected: 1,
                    executedCases: 1,
                    skippedCases: 0,
                    failedCases: 0,
                    cachedHits: 0
                )
            )),
            paths: store.resolveRunPaths(runID: runID)
        )
    }

    func testLoadStatusSnapshotReturnsCandidateCountsAndLatestRuns() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let benchmarkStore = BenchmarkStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        try candidateStore.saveCandidates([
            BenchmarkCandidate(
                id: "stt-a",
                task: .stt,
                model: "deepgram_stream",
                createdAt: "2026-02-15T00:00:00Z",
                updatedAt: "2026-02-15T00:00:00Z"
            ),
            BenchmarkCandidate(
                id: "gen-a",
                task: .generation,
                model: "gpt-5-mini",
                createdAt: "2026-02-15T00:00:00Z",
                updatedAt: "2026-02-15T00:00:00Z"
            ),
        ])

        try benchmarkStore.saveRun(makeRunRecord(
            runID: "run-stt-old",
            kind: .stt,
            createdAt: "2026-02-10T00:00:00Z",
            store: benchmarkStore
        ))
        try benchmarkStore.saveRun(makeRunRecord(
            runID: "run-stt-new",
            kind: .stt,
            createdAt: "2026-02-11T00:00:00Z",
            store: benchmarkStore
        ))
        try benchmarkStore.saveRun(makeRunRecord(
            runID: "run-gen",
            kind: .generation,
            createdAt: "2026-02-12T00:00:00Z",
            store: benchmarkStore
        ))

        let service = BenchmarkDiagnosticsService(
            candidateStore: candidateStore,
            benchmarkStore: benchmarkStore,
            integrityStore: integrityStore,
            environment: env
        )

        let snapshot = try service.loadStatusSnapshot()
        XCTAssertFalse(snapshot.generatedAt.isEmpty)

        let sttCount = snapshot.candidateCounts.first { $0.task == BenchmarkKind.stt.rawValue }
        let generationCount = snapshot.candidateCounts.first { $0.task == BenchmarkKind.generation.rawValue }
        let visionCount = snapshot.candidateCounts.first { $0.task == BenchmarkKind.vision.rawValue }

        XCTAssertEqual(sttCount?.count, 1)
        XCTAssertEqual(generationCount?.count, 1)
        XCTAssertEqual(visionCount?.count, 0)

        XCTAssertEqual(snapshot.latestRuns.first { $0.task == BenchmarkKind.stt.rawValue }?.runID, "run-stt-new")
        XCTAssertEqual(snapshot.latestRuns.first { $0.task == BenchmarkKind.generation.rawValue }?.runID, "run-gen")
    }

    func testLoadStatusSnapshotIncludesOldTaskRunBeyondThousandRecentEntries() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let benchmarkStore = BenchmarkStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        try candidateStore.saveCandidates([
            BenchmarkCandidate(
                id: "stt-a",
                task: .stt,
                model: "deepgram_stream",
                createdAt: "2026-02-15T00:00:00Z",
                updatedAt: "2026-02-15T00:00:00Z"
            ),
            BenchmarkCandidate(
                id: "gen-a",
                task: .generation,
                model: "gpt-5-mini",
                createdAt: "2026-02-15T00:00:00Z",
                updatedAt: "2026-02-15T00:00:00Z"
            ),
        ])

        try benchmarkStore.saveRun(makeRunRecord(
            runID: "run-stt-only",
            kind: .stt,
            createdAt: "2026-01-01T00:00:00Z",
            store: benchmarkStore
        ))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let baseDate = try XCTUnwrap(formatter.date(from: "2026-02-01T00:00:00Z"))

        for index in 0..<1_005 {
            let createdAt = formatter.string(from: baseDate.addingTimeInterval(Double(index)))
            try benchmarkStore.saveRun(makeRunRecord(
                runID: "run-gen-\(index)",
                kind: .generation,
                createdAt: createdAt,
                store: benchmarkStore
            ))
        }

        let service = BenchmarkDiagnosticsService(
            candidateStore: candidateStore,
            benchmarkStore: benchmarkStore,
            integrityStore: integrityStore,
            environment: env
        )

        let snapshot = try service.loadStatusSnapshot()
        XCTAssertEqual(snapshot.latestRuns.first { $0.task == BenchmarkKind.stt.rawValue }?.runID, "run-stt-only")
    }

    func testLoadIntegritySnapshotIsReadOnlyAndRespectsExclusions() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let benchmarkStore = BenchmarkStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)
        let datasetStore = BenchmarkDatasetStore()
        let service = BenchmarkDiagnosticsService(
            candidateStore: candidateStore,
            benchmarkStore: benchmarkStore,
            integrityStore: integrityStore,
            datasetStore: datasetStore,
            environment: env
        )

        let casesPath = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("manual_test_cases.jsonl", isDirectory: false)
            .path

        let records = [
            BenchmarkDatasetCaseRecord(
                id: "case-1",
                audioFile: "/tmp/not-found.wav",
                sttText: "",
                groundTruthText: ""
            ),
        ]
        try datasetStore.saveCases(path: casesPath, records: records)

        let scanCases = [BenchmarkIntegrityScanCase(
            id: "case-1",
            audioFile: "/tmp/not-found.wav",
            sttText: "",
            groundTruthText: "",
            transcriptGold: nil,
            transcriptSilver: nil
        )]
        var scanned = BenchmarkIntegrityScanner.scanIssues(
            task: .stt,
            cases: scanCases,
            sourcePath: WhispPaths.normalizeForStorage(casesPath),
            detectedAt: "2026-02-15T00:00:00Z"
        )
        XCTAssertEqual(scanned.count, 2)

        scanned[0].excluded = true
        try integrityStore.saveIssues(task: .stt, issues: [scanned[0]])

        let snapshot = try service.loadIntegritySnapshot(task: .stt, casesPath: casesPath)
        XCTAssertEqual(snapshot.task, BenchmarkKind.stt.rawValue)
        XCTAssertEqual(snapshot.totalIssues, 1)
        XCTAssertEqual(snapshot.severityCounts.reduce(0) { $0 + $1.count }, 1)

        let persistedIssues = try integrityStore.loadIssues(task: .stt)
        XCTAssertEqual(persistedIssues.count, 1)
    }
}
