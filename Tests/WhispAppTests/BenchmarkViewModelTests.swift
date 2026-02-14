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
            model: "deepgram_stream",
            options: [:],
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
            options: .stt(BenchmarkSTTRunOptions(
                common: BenchmarkRunCommonOptions(
                    sourceCasesPath: casesPath.path,
                    datasetHash: "hash-a"
                ),
                candidateID: candidate.id,
                sttMode: "stream"
            )),
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
            metrics: .stt(BenchmarkSTTRunMetrics(
                counts: BenchmarkRunCounts(
                    casesTotal: 10,
                    casesSelected: 10,
                    executedCases: 8,
                    skippedCases: 1,
                    failedCases: 1,
                    cachedHits: 2
                ),
                avgCER: 0.12,
                weightedCER: 0.2,
                latencyMs: BenchmarkLatencyDistribution(avg: 120, p50: 110, p95: 180, p99: 220),
                afterStopLatencyMs: BenchmarkLatencyDistribution(avg: 55, p50: 48, p95: 90, p99: 120)
            )),
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

    func testIntegrityAutoScanAggregatesSttAndGenerationIssues() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"","stt_text":"","ground_truth_text":""}
        """
        try Data((jsonl + "\n").utf8).write(to: casesPath, options: .atomic)

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTab = .integrity
        viewModel.refresh()

        let sttIssues = viewModel.integrityIssues.filter { $0.task == .stt && $0.caseID == "case-1" }
        let generationIssues = viewModel.integrityIssues.filter { $0.task == .generation && $0.caseID == "case-1" }
        XCTAssertFalse(sttIssues.isEmpty)
        XCTAssertFalse(generationIssues.isEmpty)
    }

    func testIntegrityAutoScanFirstRunClearsLegacyIssuesWithoutState() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let audioURL = home.appendingPathComponent("audio.wav", isDirectory: false)
        try Data("ok".utf8).write(to: audioURL, options: .atomic)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"\(audioURL.path)","stt_text":"入力","ground_truth_text":"正解"}
        """
        try Data((jsonl + "\n").utf8).write(to: casesPath, options: .atomic)

        let staleIssue = BenchmarkIntegrityIssue(
            id: "legacy-issue",
            caseID: "legacy-case",
            task: .stt,
            issueType: "missing_audio_file",
            missingFields: ["audio_file"],
            sourcePath: "/tmp/legacy.jsonl",
            excluded: false,
            detectedAt: "2026-02-14T00:00:00.000Z"
        )
        try integrityStore.saveIssues(task: .stt, issues: [staleIssue])

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTab = .integrity
        viewModel.selectedTask = .stt
        viewModel.refresh()

        XCTAssertFalse(viewModel.integrityIssues.contains(where: { $0.caseID == "legacy-case" }))
        XCTAssertFalse(viewModel.integrityCaseRows.contains(where: { $0.id == "legacy-case" }))
        XCTAssertTrue((try integrityStore.loadIssues(task: .stt)).isEmpty)
    }

    func testCopyIntegrityCaseIDUpdatesStatusMessage() {
        let home = tempHome()
        let env = ["HOME": home.path]
        let viewModel = BenchmarkViewModel(
            store: BenchmarkStore(environment: env),
            candidateStore: BenchmarkCandidateStore(environment: env),
            integrityStore: BenchmarkIntegrityStore(environment: env)
        )

        viewModel.copyIntegrityCaseID("case-1")
        XCTAssertEqual(viewModel.statusMessage, "case_id をコピーしました。")
        XCTAssertFalse(viewModel.statusIsError)
    }

    func testIntegrityCaseRowsShowAllCasesAndMarkIssues() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let audio1Path = home.appendingPathComponent("audio-1.wav", isDirectory: false).path
        let audio2Path = home.appendingPathComponent("audio-2.wav", isDirectory: false).path
        try Data().write(to: URL(fileURLWithPath: audio1Path), options: .atomic)
        try Data().write(to: URL(fileURLWithPath: audio2Path), options: .atomic)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"\(audio1Path)","stt_text":"","ground_truth_text":"正解1"}
        {"id":"case-2","audio_file":"\(audio2Path)","stt_text":"入力2","ground_truth_text":"正解2"}

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
        viewModel.selectedTab = .integrity
        viewModel.selectedTask = .generation
        viewModel.refresh()

        XCTAssertEqual(viewModel.integrityCaseRows.count, 2)
        let case1 = try XCTUnwrap(viewModel.integrityCaseRows.first(where: { $0.id == "case-1" }))
        let case2 = try XCTUnwrap(viewModel.integrityCaseRows.first(where: { $0.id == "case-2" }))

        XCTAssertEqual(case1.status, .issue)
        XCTAssertEqual(case1.issueCount, 1)
        XCTAssertEqual(case2.status, .ok)
        XCTAssertEqual(case2.issueCount, 0)
    }

    func testOpenIntegrityCaseDetailLoadsRecordFields() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"/tmp/a.wav","stt_text":"元入力","output_text":"生成済み","ground_truth_text":"期待出力","vision_image_file":"/tmp/v.png","vision_image_mime_type":"image/png"}
        """
        try Data(jsonl.utf8).write(to: casesPath, options: .atomic)

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTab = .integrity
        viewModel.selectedTask = .generation
        viewModel.refresh()
        viewModel.openIntegrityCaseDetail(caseID: "case-1")

        XCTAssertTrue(viewModel.isIntegrityCaseDetailPresented)
        XCTAssertEqual(viewModel.selectedIntegrityCaseDetail?.id, "case-1")
        XCTAssertEqual(viewModel.selectedIntegrityCaseDetail?.audioFilePath, "/tmp/a.wav")
        XCTAssertEqual(viewModel.selectedIntegrityCaseDetail?.visionImageFilePath, "/tmp/v.png")
        XCTAssertEqual(viewModel.selectedIntegrityCaseDetail?.visionImageMimeType, "image/png")
        XCTAssertEqual(viewModel.selectedIntegrityCaseDetail?.sttText, "元入力")
        XCTAssertEqual(viewModel.selectedIntegrityCaseDetail?.groundTruthText, "期待出力")
        XCTAssertEqual(viewModel.selectedIntegrityCaseDetail?.outputText, "生成済み")
    }

    func testSaveIntegrityCaseEditsUpdatesJSONLAndRecomputesStatus() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let audioPath = home.appendingPathComponent("audio.wav", isDirectory: false).path
        try Data().write(to: URL(fileURLWithPath: audioPath), options: .atomic)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"\(audioPath)","stt_text":"","ground_truth_text":"旧期待出力"}
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
        viewModel.selectedTab = .integrity
        viewModel.selectedTask = .generation
        viewModel.refresh()
        viewModel.openIntegrityCaseDetail(caseID: "case-1")
        viewModel.beginIntegrityCaseEditing()
        viewModel.integrityCaseDraftSTTText = "更新後STT"
        viewModel.integrityCaseDraftGroundTruthText = "更新後期待出力"
        viewModel.saveIntegrityCaseEdits()

        waitForCondition {
            viewModel.integrityCaseRows.first(where: { $0.id == "case-1" })?.status == .ok
        }

        let saved = try String(contentsOf: casesPath, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"stt_text\":\"更新後STT\""))
        XCTAssertTrue(saved.contains("\"ground_truth_text\":\"更新後期待出力\""))
        XCTAssertEqual(viewModel.selectedIntegrityCaseDetail?.sttText, "更新後STT")
        XCTAssertEqual(viewModel.selectedIntegrityCaseDetail?.groundTruthText, "更新後期待出力")
    }

    func testConfirmIntegrityCaseDeleteRemovesCaseFromJSONL() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"/tmp/a.wav","stt_text":"入力1","ground_truth_text":"正解1"}
        {"id":"case-2","audio_file":"/tmp/b.wav","stt_text":"入力2","ground_truth_text":"正解2"}
        """
        try Data((jsonl + "\n").utf8).write(to: casesPath, options: .atomic)

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTab = .integrity
        viewModel.selectedTask = .generation
        viewModel.refresh()
        viewModel.openIntegrityCaseDetail(caseID: "case-1")
        viewModel.requestIntegrityCaseDelete()
        viewModel.confirmIntegrityCaseDelete()

        waitForCondition {
            !viewModel.integrityCaseRows.contains(where: { $0.id == "case-1" })
        }

        let saved = try String(contentsOf: casesPath, encoding: .utf8)
        XCTAssertFalse(saved.contains("\"id\":\"case-1\""))
        XCTAssertTrue(saved.contains("\"id\":\"case-2\""))
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
            model: "deepgram_stream",
            options: [:],
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
            options: .stt(BenchmarkSTTRunOptions(
                common: BenchmarkRunCommonOptions(
                    sourceCasesPath: casesPath.path,
                    datasetHash: "hash-a"
                ),
                candidateID: candidate.id,
                sttExecutionProfile: "file_replay_realtime",
                sttMode: "stream"
            )),
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
            model: "deepgram_stream",
            options: [:],
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
                options: .stt(BenchmarkSTTRunOptions(
                    common: BenchmarkRunCommonOptions(sourceCasesPath: casesPath.path),
                    candidateID: candidate.id
                )),
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
                metrics: .stt(BenchmarkSTTRunMetrics(
                    counts: BenchmarkRunCounts(
                        casesTotal: 1,
                        casesSelected: 1,
                        executedCases: 1,
                        skippedCases: 0,
                        failedCases: 0
                    )
                )),
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
                model: "deepgram_stream",
                options: [:],
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

        XCTAssertTrue(viewModel.taskCandidates.contains(where: { $0.model == STTPresetID.appleSpeechRecognizerStream.rawValue }))
        XCTAssertTrue(viewModel.taskCandidates.contains(where: { $0.model == STTPresetID.appleSpeechAnalyzerStream.rawValue }))
        XCTAssertTrue(viewModel.taskCandidates.contains(where: { $0.id == "stt-apple-speech-recognizer-stream-default" }))
    }

    func testSavePromptCandidateModalCreatesGenerationCandidate() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: casesPath, options: .atomic)

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTab = .generationSingle
        viewModel.selectedTask = .generation
        viewModel.refresh()
        viewModel.openCreatePromptCandidateModal()
        let candidateID = viewModel.promptCandidateDraftCandidateID
        viewModel.promptCandidateDraftName = "concise"
        viewModel.promptCandidateDraftTemplate = "整形してください。入力: {STT結果}"
        viewModel.promptCandidateDraftRequireContext = true
        viewModel.savePromptCandidateModal()

        let saved = try candidateStore.loadCandidate(id: candidateID)
        XCTAssertEqual(saved?.task, .generation)
        XCTAssertEqual(saved?.promptName, "concise")
        XCTAssertEqual(saved?.generationPromptTemplate, "整形してください。入力: {STT結果}")
        XCTAssertEqual(saved?.generationPromptHash, promptTemplateHash("整形してください。入力: {STT結果}"))
        XCTAssertEqual(saved?.options["require_context"], "true")
    }

    func testSavePromptCandidateModalRejectsEmptyTemplate() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: casesPath, options: .atomic)

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTab = .generationSingle
        viewModel.selectedTask = .generation
        viewModel.refresh()
        viewModel.openCreatePromptCandidateModal()
        viewModel.promptCandidateDraftName = "invalid"
        viewModel.promptCandidateDraftTemplate = "   "
        viewModel.savePromptCandidateModal()

        XCTAssertTrue(viewModel.isPromptCandidateModalPresented)
        XCTAssertEqual(viewModel.promptCandidateDraftValidationError, "prompt_template は空にできません。")
    }

    func testRunCompareRejectsSamePairwiseCandidateSelection() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let now = "2026-02-12T00:00:00.000Z"
        try candidateStore.saveCandidates([
            BenchmarkCandidate(
                id: "generation-a",
                task: .generation,
                model: "gpt-5-nano",
                promptName: "A",
                generationPromptTemplate: "入力: {STT結果}",
                generationPromptHash: promptTemplateHash("入力: {STT結果}"),
                options: ["use_cache": "true"],
                createdAt: now,
                updatedAt: now
            ),
        ])

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore
        )
        viewModel.selectedTab = .generationBattle
        viewModel.selectedTask = .generation
        viewModel.refresh()

        viewModel.generationPairCandidateAID = "generation-a"
        viewModel.generationPairCandidateBID = "generation-a"
        viewModel.runCompare()

        XCTAssertTrue(viewModel.statusIsError)
        XCTAssertEqual(viewModel.statusMessage, "candidate A/B は異なる候補を選択してください。")
        XCTAssertFalse(viewModel.isExecutingBenchmark)
    }

    func testGenerationPairwiseRowsShowWinnersAndReasonsInDetailOnly() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: casesPath, options: .atomic)

        let now = "2026-02-12T00:00:00.000Z"
        let candidateA = BenchmarkCandidate(
            id: "generation-a",
            task: .generation,
            model: "gpt-5-nano",
            promptName: "A",
            generationPromptTemplate: "入力: {STT結果}",
            generationPromptHash: promptTemplateHash("入力: {STT結果}"),
            options: ["use_cache": "true"],
            createdAt: now,
            updatedAt: now
        )
        let candidateB = BenchmarkCandidate(
            id: "generation-b",
            task: .generation,
            model: "gemini-2.5-flash-lite",
            promptName: "B",
            generationPromptTemplate: "入力を整形: {STT結果}",
            generationPromptHash: promptTemplateHash("入力を整形: {STT結果}"),
            options: ["use_cache": "true"],
            createdAt: now,
            updatedAt: now
        )
        try candidateStore.saveCandidates([candidateA, candidateB])

        let runID = "generation-20260212-111111-pair1111"
        let paths = store.resolveRunPaths(runID: runID)
        try store.saveRun(
            BenchmarkRunRecord(
                id: runID,
                kind: .generation,
                status: .completed,
                createdAt: now,
                updatedAt: now,
                options: .generationPairwise(BenchmarkGenerationPairwiseRunOptions(
                    common: BenchmarkRunCommonOptions(
                        sourceCasesPath: casesPath.path,
                        datasetHash: "hash-pair",
                        runtimeOptionsHash: "runtime-pair",
                        evaluatorVersion: "pairwise-v1",
                        codeVersion: "dev"
                    ),
                    pairCanonicalID: BenchmarkPairwiseNormalizer.canonicalize(candidateA.id, candidateB.id),
                    pairExecutionOrder: BenchmarkPairExecutionOrder(firstCandidateID: candidateA.id, secondCandidateID: candidateB.id),
                    pairJudgeModel: LLMModel.gpt4oMini.rawValue
                )),
                benchmarkKey: BenchmarkKey(
                    task: .generation,
                    datasetPath: casesPath.path,
                    datasetHash: "hash-pair",
                    candidateID: "pair:\(candidateA.id)__vs__\(candidateB.id)",
                    runtimeOptionsHash: "runtime-pair",
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
                paths: paths
            )
        )
        try store.appendCaseResult(
            runID: runID,
            result: BenchmarkCaseResult(
                id: "case-1",
                status: .ok,
                reason: nil,
                cache: BenchmarkCacheRecord(hit: false, namespace: "generation_pairwise"),
                sources: BenchmarkReferenceSources(input: "stt_text", reference: "ground_truth_text"),
                contextUsed: true,
                visionImageAttached: false,
                metrics: BenchmarkCaseMetrics(
                    pairwise: PairwiseCaseJudgement(
                        overallWinner: .a,
                        intentWinner: .a,
                        hallucinationWinner: .b,
                        styleContextWinner: .tie,
                        overallReason: "Aが2軸で優位",
                        intentReason: "Aは依頼意図を維持",
                        hallucinationReason: "Bは不要な補完が少ない",
                        styleContextReason: "文体は同等",
                        confidence: "high"
                    )
                )
            )
        )
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "output_generation_a.txt", text: "A output")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "output_generation_b.txt", text: "B output")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "input_stt.txt", text: "STT入力テキスト")

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTab = .generationBattle
        viewModel.selectedTask = .generation
        viewModel.refresh()
        viewModel.setGenerationPairJudgeModel(.gpt4oMini)

        let row = try XCTUnwrap(viewModel.generationPairwiseCaseRows.first(where: { $0.id == "case-1" }))
        XCTAssertEqual(row.overallWinner, .a)
        XCTAssertEqual(row.intentWinner, .a)
        XCTAssertEqual(row.hallucinationWinner, .b)
        XCTAssertEqual(row.styleContextWinner, .tie)

        viewModel.selectGenerationPairwiseCase("case-1")
        let detail = try XCTUnwrap(viewModel.generationPairwiseCaseDetail)
        XCTAssertEqual(detail.overallReason, "Aが2軸で優位")
        XCTAssertEqual(detail.intentReason, "Aは依頼意図を維持")
        XCTAssertEqual(detail.hallucinationReason, "Bは不要な補完が少ない")
        XCTAssertEqual(detail.styleContextReason, "文体は同等")
        XCTAssertEqual(detail.sttText, "STT入力テキスト")
        XCTAssertEqual(detail.outputA, "A output")
        XCTAssertEqual(detail.outputB, "B output")
    }

    func testGenerationPairwiseRunSelectionFollowsJudgeModel() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: casesPath, options: .atomic)

        let now = "2026-02-12T00:00:00.000Z"
        let candidateA = BenchmarkCandidate(
            id: "generation-a",
            task: .generation,
            model: "gpt-5-nano",
            promptName: "A",
            generationPromptTemplate: "入力: {STT結果}",
            generationPromptHash: promptTemplateHash("入力: {STT結果}"),
            options: ["use_cache": "true"],
            createdAt: now,
            updatedAt: now
        )
        let candidateB = BenchmarkCandidate(
            id: "generation-b",
            task: .generation,
            model: "gemini-2.5-flash-lite",
            promptName: "B",
            generationPromptTemplate: "入力を整形: {STT結果}",
            generationPromptHash: promptTemplateHash("入力を整形: {STT結果}"),
            options: ["use_cache": "true"],
            createdAt: now,
            updatedAt: now
        )
        try candidateStore.saveCandidates([candidateA, candidateB])

        let geminiRunID = "generation-20260212-100000-gemini"
        try store.saveRun(
            BenchmarkRunRecord(
                id: geminiRunID,
                kind: .generation,
                status: .completed,
                createdAt: "2026-02-12T10:00:00.000Z",
                updatedAt: "2026-02-12T10:00:00.000Z",
                options: .generationPairwise(BenchmarkGenerationPairwiseRunOptions(
                    common: BenchmarkRunCommonOptions(sourceCasesPath: casesPath.path),
                    pairCanonicalID: BenchmarkPairwiseNormalizer.canonicalize(candidateA.id, candidateB.id),
                    pairExecutionOrder: BenchmarkPairExecutionOrder(firstCandidateID: candidateA.id, secondCandidateID: candidateB.id),
                    pairJudgeModel: LLMModel.gemini25FlashLite.rawValue
                )),
                metrics: .generationPairwise(BenchmarkGenerationPairwiseRunMetrics(
                    counts: BenchmarkRunCounts(
                        casesTotal: 1,
                        casesSelected: 1,
                        executedCases: 1,
                        skippedCases: 0,
                        failedCases: 0
                    ),
                    pairwiseSummary: PairwiseRunSummary(overallAWins: 1)
                )),
                paths: store.resolveRunPaths(runID: geminiRunID)
            )
        )

        let gptRunID = "generation-20260212-100500-gpt4o"
        try store.saveRun(
            BenchmarkRunRecord(
                id: gptRunID,
                kind: .generation,
                status: .completed,
                createdAt: "2026-02-12T10:05:00.000Z",
                updatedAt: "2026-02-12T10:05:00.000Z",
                options: .generationPairwise(BenchmarkGenerationPairwiseRunOptions(
                    common: BenchmarkRunCommonOptions(sourceCasesPath: casesPath.path),
                    pairCanonicalID: BenchmarkPairwiseNormalizer.canonicalize(candidateA.id, candidateB.id),
                    pairExecutionOrder: BenchmarkPairExecutionOrder(firstCandidateID: candidateA.id, secondCandidateID: candidateB.id),
                    pairJudgeModel: LLMModel.gpt4oMini.rawValue
                )),
                metrics: .generationPairwise(BenchmarkGenerationPairwiseRunMetrics(
                    counts: BenchmarkRunCounts(
                        casesTotal: 1,
                        casesSelected: 1,
                        executedCases: 1,
                        skippedCases: 0,
                        failedCases: 0
                    ),
                    pairwiseSummary: PairwiseRunSummary(overallBWins: 1)
                )),
                paths: store.resolveRunPaths(runID: gptRunID)
            )
        )

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTab = .generationBattle
        viewModel.selectedTask = .generation
        viewModel.refresh()

        XCTAssertEqual(viewModel.generationPairJudgeModel, .gemini25FlashLite)
        XCTAssertEqual(viewModel.generationPairwiseRunID, geminiRunID)
        XCTAssertEqual(viewModel.generationPairwiseSummary?.overallAWins, 1)

        viewModel.setGenerationPairJudgeModel(.gpt4oMini)
        XCTAssertEqual(viewModel.generationPairwiseRunID, gptRunID)
        XCTAssertEqual(viewModel.generationPairwiseSummary?.overallBWins, 1)
    }

    func testPromptVariableItemsExposeMinimumContextSet() {
        let viewModel = BenchmarkViewModel(
            store: BenchmarkStore(environment: [:]),
            candidateStore: BenchmarkCandidateStore(environment: [:]),
            integrityStore: BenchmarkIntegrityStore(environment: [:])
        )

        let tokens = viewModel.promptVariableItems.map(\.token)
        XCTAssertEqual(tokens, ["{STT結果}", "{選択テキスト}", "{画面テキスト}", "{画面要約}", "{専門用語候補}"])
    }

    func testAppendPromptVariableToDraftAddsTokenWithLineBreak() {
        let viewModel = BenchmarkViewModel(
            store: BenchmarkStore(environment: [:]),
            candidateStore: BenchmarkCandidateStore(environment: [:]),
            integrityStore: BenchmarkIntegrityStore(environment: [:])
        )
        viewModel.promptCandidateDraftTemplate = "先頭"

        viewModel.appendPromptVariableToDraft("{画面要約}")
        viewModel.appendPromptVariableToDraft("{専門用語候補}")

        XCTAssertEqual(viewModel.promptCandidateDraftTemplate, "先頭\n{画面要約}\n{専門用語候補}")
    }

    func testRefreshNormalizesGenerationCandidateWithoutPrompt() throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let now = "2026-02-12T00:00:00.000Z"
        try candidateStore.saveCandidates([
            BenchmarkCandidate(
                id: "generation-old",
                task: .generation,
                model: "gemini-2.5-flash-lite",
                options: ["use_cache": "true"],
                createdAt: now,
                updatedAt: now
            ),
        ])

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore
        )
        viewModel.selectedTask = .generation
        viewModel.refresh()

        let normalized = try candidateStore.loadCandidate(id: "generation-old")
        XCTAssertEqual(normalized?.promptName, "generation-old")
        XCTAssertEqual(normalized?.generationPromptTemplate, defaultPostProcessPromptTemplate)
        XCTAssertEqual(normalized?.generationPromptHash, promptTemplateHash(defaultPostProcessPromptTemplate))
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

    private func waitForCondition(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.02,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        XCTFail("condition timeout", file: file, line: line)
    }
}
