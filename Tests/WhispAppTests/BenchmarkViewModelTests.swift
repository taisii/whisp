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
                options: BenchmarkRunOptions(
                    sourceCasesPath: casesPath.path,
                    datasetHash: "hash-pair",
                    runtimeOptionsHash: "runtime-pair",
                    evaluatorVersion: "pairwise-v1",
                    codeVersion: "dev",
                    compareMode: .pairwise,
                    pairCandidateAID: candidateA.id,
                    pairCandidateBID: candidateB.id,
                    pairJudgeModel: "gpt-5-nano"
                ),
                benchmarkKey: BenchmarkKey(
                    task: .generation,
                    datasetPath: casesPath.path,
                    datasetHash: "hash-pair",
                    candidateID: "pair:\(candidateA.id)__vs__\(candidateB.id)",
                    runtimeOptionsHash: "runtime-pair",
                    evaluatorVersion: "pairwise-v1",
                    codeVersion: "dev"
                ),
                metrics: BenchmarkRunMetrics(
                    casesTotal: 1,
                    casesSelected: 1,
                    executedCases: 1,
                    skippedCases: 0,
                    failedCases: 0,
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
                ),
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

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTask = .generation
        viewModel.refresh()
        viewModel.setGenerationPairJudgeModel(.gpt5Nano)

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
                options: BenchmarkRunOptions(
                    sourceCasesPath: casesPath.path,
                    compareMode: .pairwise,
                    pairCandidateAID: candidateA.id,
                    pairCandidateBID: candidateB.id,
                    pairJudgeModel: LLMModel.gemini25FlashLite.rawValue
                ),
                metrics: BenchmarkRunMetrics(
                    casesTotal: 1,
                    casesSelected: 1,
                    executedCases: 1,
                    skippedCases: 0,
                    failedCases: 0,
                    pairwiseSummary: PairwiseRunSummary(overallAWins: 1)
                ),
                paths: store.resolveRunPaths(runID: geminiRunID)
            )
        )

        let gptRunID = "generation-20260212-100500-gpt5"
        try store.saveRun(
            BenchmarkRunRecord(
                id: gptRunID,
                kind: .generation,
                status: .completed,
                createdAt: "2026-02-12T10:05:00.000Z",
                updatedAt: "2026-02-12T10:05:00.000Z",
                options: BenchmarkRunOptions(
                    sourceCasesPath: casesPath.path,
                    compareMode: .pairwise,
                    pairCandidateAID: candidateA.id,
                    pairCandidateBID: candidateB.id,
                    pairJudgeModel: LLMModel.gpt5Nano.rawValue
                ),
                metrics: BenchmarkRunMetrics(
                    casesTotal: 1,
                    casesSelected: 1,
                    executedCases: 1,
                    skippedCases: 0,
                    failedCases: 0,
                    pairwiseSummary: PairwiseRunSummary(overallBWins: 1)
                ),
                paths: store.resolveRunPaths(runID: gptRunID)
            )
        )

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTask = .generation
        viewModel.refresh()

        XCTAssertEqual(viewModel.generationPairJudgeModel, .gemini25FlashLite)
        XCTAssertEqual(viewModel.generationPairwiseRunID, geminiRunID)
        XCTAssertEqual(viewModel.generationPairwiseSummary?.overallAWins, 1)

        viewModel.setGenerationPairJudgeModel(.gpt5Nano)
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
}
