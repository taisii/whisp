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

    func testRefreshBuildsComparisonRowsFromCandidateRuns() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: casesPath, options: .atomic)

        let now = "2026-02-12T00:00:00.000Z"
        let candidate = BenchmarkCandidate(
            id: "stt-deepgram-a",
            task: .stt,
            model: "deepgram",
            promptProfileID: nil,
            options: ["stt_mode": "stream"],
            createdAt: now,
            updatedAt: now
        )
        try candidateStore.saveCandidates([candidate])

        let runID = "stt-20260212-000000-aaaa1111"
        let paths = store.resolveRunPaths(runID: runID)
        let run = BenchmarkRunRecord(
            id: runID,
            kind: .stt,
            status: .completed,
            createdAt: now,
            updatedAt: now,
            options: BenchmarkRunOptions(
                sourceCasesPath: casesPath.path,
                datasetHash: "hash-a",
                candidateID: candidate.id,
                sttMode: "stream"
            ),
            candidateID: candidate.id,
            benchmarkKey: BenchmarkKey(
                task: .stt,
                datasetPath: casesPath.path,
                datasetHash: "hash-a",
                candidateID: candidate.id,
                runtimeOptionsHash: "runtime-a",
                evaluatorVersion: "v1",
                codeVersion: "dev"
            ),
            metrics: BenchmarkRunMetrics(
                casesTotal: 10,
                casesSelected: 10,
                executedCases: 8,
                skippedCases: 1,
                failedCases: 1,
                cachedHits: 2,
                avgCER: 0.12,
                weightedCER: 0.2,
                latencyMs: BenchmarkLatencyDistribution(avg: 120, p50: 110, p95: 180, p99: 220),
                afterStopLatencyMs: BenchmarkLatencyDistribution(avg: 55, p50: 48, p95: 90, p99: 120)
            ),
            paths: paths
        )
        try store.saveRun(run)

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.refresh()

        XCTAssertTrue(viewModel.taskCandidates.contains(where: { $0.id == candidate.id }))
        guard let row = viewModel.comparisonRows.first(where: { $0.candidate.id == candidate.id }) else {
            return XCTFail("expected comparison row for custom candidate")
        }
        XCTAssertEqual(row.executedCases, 8)
        XCTAssertEqual(row.skipCases, 1)
        XCTAssertEqual(row.sttAfterStopP95, 90)
    }

    func testExcludeIssueTogglesPersistence() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let issue = BenchmarkIntegrityIssue(
            id: "issue-1",
            caseID: "case-1",
            task: .generation,
            issueType: "missing_stt_text",
            missingFields: ["stt_text"],
            sourcePath: "/tmp/manual.jsonl",
            excluded: false,
            detectedAt: "2026-02-12T00:00:00.000Z"
        )
        try integrityStore.saveIssues(task: .generation, issues: [issue])

        let viewModel = BenchmarkViewModel(store: store, candidateStore: candidateStore, integrityStore: integrityStore)
        viewModel.selectedTask = .generation
        viewModel.refresh()

        guard let loaded = viewModel.integrityIssues.first else {
            return XCTFail("issue missing")
        }
        viewModel.selectIntegrityIssue(loaded.id)
        viewModel.setIssueExcluded(loaded, excluded: true)

        let after = try integrityStore.loadIssues(task: .generation)
        XCTAssertEqual(after.first?.excluded, true)
    }

    func testIntegrityCaseRowsShowAllCasesAndMarkIssues() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"/tmp/a.wav","stt_text":"","ground_truth_text":"正解1"}
        {"id":"case-2","audio_file":"/tmp/b.wav","stt_text":"入力2","ground_truth_text":"正解2"}

        """
        try Data(jsonl.utf8).write(to: casesPath, options: .atomic)

        let issue = BenchmarkIntegrityIssue(
            id: "issue-case-1",
            caseID: "case-1",
            task: .generation,
            issueType: "missing_stt_text",
            missingFields: ["stt_text"],
            sourcePath: casesPath.path,
            excluded: false,
            detectedAt: "2026-02-12T00:00:00.000Z"
        )
        try integrityStore.saveIssues(task: .generation, issues: [issue])

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTask = .generation
        viewModel.refresh()

        XCTAssertEqual(viewModel.integrityCaseRows.count, 2)
        let case1 = try XCTUnwrap(viewModel.integrityCaseRows.first(where: { $0.id == "case-1" }))
        let case2 = try XCTUnwrap(viewModel.integrityCaseRows.first(where: { $0.id == "case-2" }))

        XCTAssertTrue(case1.hasActiveIssues)
        XCTAssertEqual(case1.issueCount, 1)
        XCTAssertFalse(case2.hasActiveIssues)
        XCTAssertEqual(case2.issueCount, 0)
    }

    func testOpenCaseDetailLoadsTimelineAndAttempts() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: casesPath, options: .atomic)

        let now = "2026-02-12T00:00:00.000Z"
        let candidate = BenchmarkCandidate(
            id: "stt-deepgram-detail",
            task: .stt,
            model: "deepgram",
            promptProfileID: nil,
            options: ["stt_mode": "stream"],
            createdAt: now,
            updatedAt: now
        )
        try candidateStore.saveCandidates([candidate])

        let runID = "stt-20260212-000001-bbbb1111"
        let paths = store.resolveRunPaths(runID: runID)
        let run = BenchmarkRunRecord(
            id: runID,
            kind: .stt,
            status: .completed,
            createdAt: now,
            updatedAt: now,
            options: BenchmarkRunOptions(
                sourceCasesPath: casesPath.path,
                sttExecutionProfile: "file_replay_realtime",
                datasetHash: "hash-a",
                candidateID: candidate.id,
                sttMode: "stream"
            ),
            candidateID: candidate.id,
            benchmarkKey: BenchmarkKey(
                task: .stt,
                datasetPath: casesPath.path,
                datasetHash: "hash-a",
                candidateID: candidate.id,
                runtimeOptionsHash: "runtime-a",
                evaluatorVersion: "v1",
                codeVersion: "dev"
            ),
            metrics: BenchmarkRunMetrics(
                casesTotal: 1,
                casesSelected: 1,
                executedCases: 1,
                skippedCases: 0,
                failedCases: 0,
                cachedHits: 0
            ),
            paths: paths
        )
        try store.saveRun(run)
        try store.appendCaseResult(
            runID: runID,
            result: BenchmarkCaseResult(
                id: "case-1",
                status: .ok,
                reason: nil,
                cache: BenchmarkCacheRecord(hit: false, namespace: "stt"),
                sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
                contextUsed: false,
                visionImageAttached: false,
                metrics: BenchmarkCaseMetrics(cer: 0.12, sttTotalMs: 700, sttAfterStopMs: 120)
            )
        )
        try store.appendEvent(runID: runID, event: .loadCase(BenchmarkLoadCaseLog(
            base: Self.eventBase(runID: runID, caseID: "case-1", stage: .loadCase, started: 0, ended: 10),
            sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
            contextPresent: false,
            visionImagePresent: false,
            audioFilePath: "/tmp/audio.wav",
            rawRowRef: nil
        )))
        try store.appendEvent(runID: runID, event: .audioReplay(BenchmarkAudioReplayLog(
            base: Self.eventBase(runID: runID, caseID: "case-1", stage: .audioReplay, started: 100, ended: 500),
            profile: "file_replay_realtime",
            chunkMs: 120,
            realtime: true
        )))
        try store.appendEvent(runID: runID, event: .stt(BenchmarkSTTLog(
            base: Self.eventBase(runID: runID, caseID: "case-1", stage: .stt, started: 300, ended: 900),
            provider: "deepgram",
            mode: "stream",
            transcriptText: "しょうさいをしめしてください",
            referenceText: "詳細を示してください",
            transcriptChars: 12,
            cer: 0.12,
            sttTotalMs: 700,
            sttAfterStopMs: 120,
            attempts: [
                BenchmarkSTTAttempt(kind: "stream_send", status: .ok, startedAtMs: 300, endedAtMs: 700),
                BenchmarkSTTAttempt(kind: "stream_finalize", status: .ok, startedAtMs: 701, endedAtMs: 900),
            ],
            rawResponseRef: nil,
            error: nil
        )))

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.refresh()
        viewModel.openCaseDetail(caseID: "case-1")

        XCTAssertTrue(viewModel.isCaseDetailPresented)
        XCTAssertEqual(viewModel.selectedCaseDetail?.caseID, "case-1")
        XCTAssertEqual(viewModel.selectedCaseDetail?.audioFilePath, "/tmp/audio.wav")
        XCTAssertEqual(viewModel.selectedCaseDetail?.timeline.phases.count, 3)
        XCTAssertEqual(viewModel.selectedCaseDetail?.attempts.count, 2)
        XCTAssertEqual(viewModel.selectedCaseDetail?.sttText, "しょうさいをしめしてください")
        XCTAssertEqual(viewModel.selectedCaseDetail?.referenceText, "詳細を示してください")
        XCTAssertEqual(viewModel.selectedCaseDetail?.sttDeltaAfterRecordingMs, 120)
        XCTAssertTrue(viewModel.selectedCaseDetail?.missingDataMessages.isEmpty ?? false)
    }

    func testOpenCaseDetailShowsFallbackWhenAudioReplayMissing() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: casesPath, options: .atomic)

        let now = "2026-02-12T00:00:00.000Z"
        let candidate = BenchmarkCandidate(
            id: "stt-deepgram-oldrun",
            task: .stt,
            model: "deepgram",
            promptProfileID: nil,
            options: ["stt_mode": "stream"],
            createdAt: now,
            updatedAt: now
        )
        try candidateStore.saveCandidates([candidate])

        let runID = "stt-20260212-000002-cccc1111"
        let paths = store.resolveRunPaths(runID: runID)
        try store.saveRun(
            BenchmarkRunRecord(
                id: runID,
                kind: .stt,
                status: .completed,
                createdAt: now,
                updatedAt: now,
                options: BenchmarkRunOptions(sourceCasesPath: casesPath.path, candidateID: candidate.id),
                candidateID: candidate.id,
                benchmarkKey: BenchmarkKey(
                    task: .stt,
                    datasetPath: casesPath.path,
                    datasetHash: "hash-b",
                    candidateID: candidate.id,
                    runtimeOptionsHash: "runtime-b",
                    evaluatorVersion: "v1",
                    codeVersion: "dev"
                ),
                metrics: BenchmarkRunMetrics(
                    casesTotal: 1,
                    casesSelected: 1,
                    executedCases: 1,
                    skippedCases: 0,
                    failedCases: 0
                ),
                paths: paths
            )
        )
        try store.appendCaseResult(
            runID: runID,
            result: BenchmarkCaseResult(
                id: "case-old",
                status: .ok,
                reason: nil,
                cache: BenchmarkCacheRecord(hit: false, namespace: "stt"),
                sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
                contextUsed: false,
                visionImageAttached: false,
                metrics: BenchmarkCaseMetrics(cer: 0.2, sttTotalMs: 150)
            )
        )
        try store.appendEvent(runID: runID, event: .loadCase(BenchmarkLoadCaseLog(
            base: Self.eventBase(runID: runID, caseID: "case-old", stage: .loadCase, started: 0, ended: 10),
            sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
            contextPresent: false,
            visionImagePresent: false,
            audioFilePath: "/tmp/audio-old.wav",
            rawRowRef: nil
        )))
        try store.appendEvent(runID: runID, event: .stt(BenchmarkSTTLog(
            base: Self.eventBase(runID: runID, caseID: "case-old", stage: .stt, started: 20, ended: 180),
            provider: "deepgram",
            mode: "stream",
            transcriptChars: 8,
            cer: 0.2,
            sttTotalMs: 150,
            sttAfterStopMs: 60,
            attempts: nil,
            rawResponseRef: nil,
            error: nil
        )))

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.refresh()
        viewModel.openCaseDetail(caseID: "case-old")

        XCTAssertTrue(viewModel.isCaseDetailPresented)
        XCTAssertEqual(viewModel.selectedCaseDetail?.caseID, "case-old")
        XCTAssertTrue(viewModel.selectedCaseDetail?.missingDataMessages.contains(where: { $0.contains("audio_replay") }) ?? false)
    }

    func testRefreshSeedsAppleSpeechDefaultCandidate() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: casesPath, options: .atomic)

        let now = "2026-02-12T00:00:00.000Z"
        try candidateStore.saveCandidates([
            BenchmarkCandidate(
                id: "stt-custom-deepgram-only",
                task: .stt,
                model: "deepgram",
                promptProfileID: nil,
                options: ["stt_mode": "stream"],
                createdAt: now,
                updatedAt: now
            ),
        ])

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.refresh()

        XCTAssertTrue(viewModel.taskCandidates.contains(where: { $0.model == STTProvider.appleSpeech.rawValue }))
        XCTAssertTrue(viewModel.taskCandidates.contains(where: { $0.id == "stt-apple-speech-rest-default" }))
    }

    private static func eventBase(
        runID: String,
        caseID: String,
        stage: BenchmarkEventStage,
        started: Int64,
        ended: Int64
    ) -> BenchmarkCaseEventBase {
        BenchmarkCaseEventBase(
            runID: runID,
            caseID: caseID,
            stage: stage,
            status: .ok,
            startedAtMs: started,
            endedAtMs: ended,
            recordedAtMs: ended + 1
        )
    }
}
