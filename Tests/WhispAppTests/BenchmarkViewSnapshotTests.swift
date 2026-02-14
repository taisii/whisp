import AppKit
import CryptoKit
import SwiftUI
import XCTest
import WhispCore
@testable import WhispApp

@MainActor
final class BenchmarkViewSnapshotTests: XCTestCase {
    private let width = 1460
    private let height = 900

    func testRenderBenchmarkViewBeforeAfter() throws {
        let artifactDir = try makeArtifactDirectory()

        let emptyHome = try makeTempHome()
        let emptyStore = BenchmarkStore(environment: ["HOME": emptyHome.path])
        let emptyCandidateStore = BenchmarkCandidateStore(environment: ["HOME": emptyHome.path])
        let emptyIntegrityStore = BenchmarkIntegrityStore(environment: ["HOME": emptyHome.path])
        let emptyViewModel = BenchmarkViewModel(
            store: emptyStore,
            candidateStore: emptyCandidateStore,
            integrityStore: emptyIntegrityStore
        )
        emptyViewModel.refresh()
        let before = try renderSnapshot(viewModel: emptyViewModel)
        let beforeURL = artifactDir.appendingPathComponent("benchmark_view_before.png")
        try pngData(from: before).write(to: beforeURL, options: .atomic)

        let dataHome = try makeTempHome()
        let env = ["HOME": dataHome.path]
        let dataStore = BenchmarkStore(environment: env)
        let dataCandidateStore = BenchmarkCandidateStore(environment: env)
        let dataIntegrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = dataHome.appendingPathComponent("cases.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: casesPath, options: .atomic)

        let candidateA = BenchmarkCandidate(
            id: "generation-gpt-5-nano-a",
            task: .generation,
            model: "gpt-5-nano",
            promptName: "business",
            generationPromptTemplate: "入力: {STT結果}",
            generationPromptHash: promptTemplateHash("入力: {STT結果}"),
            options: ["require_context": "true", "use_cache": "true"],
            createdAt: "2026-02-12T00:00:00.000Z",
            updatedAt: "2026-02-12T00:00:00.000Z"
        )
        let candidateB = BenchmarkCandidate(
            id: "generation-gemini-2.5-flash-lite-b",
            task: .generation,
            model: "gemini-2.5-flash-lite",
            promptName: "formal",
            generationPromptTemplate: "丁寧に整形: {STT結果}",
            generationPromptHash: promptTemplateHash("丁寧に整形: {STT結果}"),
            options: ["require_context": "false", "use_cache": "true"],
            createdAt: "2026-02-12T00:00:00.000Z",
            updatedAt: "2026-02-12T00:00:00.000Z"
        )
        try dataCandidateStore.saveCandidates([candidateA, candidateB])

        let runID = "generation-20260212-000000-aaaa1111"
        let paths = dataStore.resolveRunPaths(runID: runID)
        try dataStore.saveRun(
            BenchmarkRunRecord(
                id: runID,
                kind: .generation,
                status: .completed,
                createdAt: "2026-02-12T00:00:00.000Z",
                updatedAt: "2026-02-12T00:00:00.000Z",
                options: .generationPairwise(BenchmarkGenerationPairwiseRunOptions(
                    common: BenchmarkRunCommonOptions(
                        sourceCasesPath: casesPath.path,
                        datasetHash: "hash-a",
                        runtimeOptionsHash: "runtime-a",
                        evaluatorVersion: "pairwise-v1",
                        codeVersion: "dev"
                    ),
                    pairCanonicalID: BenchmarkPairwiseNormalizer.canonicalize(candidateB.id, candidateA.id),
                    pairExecutionOrder: BenchmarkPairExecutionOrder(firstCandidateID: candidateB.id, secondCandidateID: candidateA.id),
                    pairJudgeModel: "gpt-4o-mini"
                )),
                benchmarkKey: BenchmarkKey(
                    task: .generation,
                    datasetPath: casesPath.path,
                    datasetHash: "hash-a",
                    candidateID: "pair:\(candidateB.id)__vs__\(candidateA.id)",
                    runtimeOptionsHash: "runtime-a",
                    evaluatorVersion: "pairwise-v1",
                    codeVersion: "dev"
                ),
                metrics: .generationPairwise(BenchmarkGenerationPairwiseRunMetrics(
                    counts: BenchmarkRunCounts(
                        casesTotal: 2,
                        casesSelected: 2,
                        executedCases: 2,
                        skippedCases: 0,
                        failedCases: 0
                    ),
                    pairwiseSummary: PairwiseRunSummary(
                        judgedCases: 2,
                        judgeErrorCases: 0,
                        overallAWins: 1,
                        overallBWins: 1,
                        overallTies: 0,
                        intentAWins: 1,
                        intentBWins: 1,
                        intentTies: 0,
                        hallucinationAWins: 0,
                        hallucinationBWins: 2,
                        hallucinationTies: 0,
                        styleContextAWins: 1,
                        styleContextBWins: 0,
                        styleContextTies: 1
                    )
                )),
                paths: paths
            )
        )

        try dataStore.appendCaseResult(
            runID: runID,
            result: BenchmarkCaseResult(
                id: "case-1",
                status: .ok,
                reason: nil,
                cache: BenchmarkCacheRecord(hit: true, key: "abc", namespace: "generation_pairwise"),
                sources: BenchmarkReferenceSources(input: "stt_text", reference: "ground_truth_text"),
                contextUsed: true,
                visionImageAttached: false,
                metrics: BenchmarkCaseMetrics(
                    pairwise: PairwiseCaseJudgement(
                        overallWinner: .a,
                        intentWinner: .a,
                        hallucinationWinner: .b,
                        styleContextWinner: .tie,
                        overallReason: "Aが僅差で優位",
                        intentReason: "Aは意図表現が明確",
                        hallucinationReason: "Bは余計な補完が少ない",
                        styleContextReason: "同等",
                        confidence: "medium"
                    )
                )
            )
        )
        try dataStore.appendCaseResult(
            runID: runID,
            result: BenchmarkCaseResult(
                id: "case-2",
                status: .ok,
                reason: nil,
                cache: BenchmarkCacheRecord(hit: false, key: "def", namespace: "generation_pairwise"),
                sources: BenchmarkReferenceSources(input: "stt_text", reference: "ground_truth_text"),
                contextUsed: true,
                visionImageAttached: false,
                metrics: BenchmarkCaseMetrics(
                    pairwise: PairwiseCaseJudgement(
                        overallWinner: .b,
                        intentWinner: .b,
                        hallucinationWinner: .b,
                        styleContextWinner: .a,
                        overallReason: "Bが2軸で優位",
                        intentReason: "Bの指示追従が安定",
                        hallucinationReason: "Bの追加情報が少ない",
                        styleContextReason: "Aの文体がより自然",
                        confidence: "high"
                    )
                )
            )
        )
        _ = try dataStore.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "output_generation_a.txt", text: "A output case-1")
        _ = try dataStore.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "output_generation_b.txt", text: "B output case-1")
        _ = try dataStore.writeCaseIOText(runID: runID, caseID: "case-2", fileName: "output_generation_a.txt", text: "A output case-2")
        _ = try dataStore.writeCaseIOText(runID: runID, caseID: "case-2", fileName: "output_generation_b.txt", text: "B output case-2")

        let issue = BenchmarkIntegrityIssue(
            id: "issue-1",
            caseID: "case-2",
            task: .generation,
            issueType: "missing_stt_text",
            missingFields: ["stt_text"],
            sourcePath: casesPath.path,
            excluded: false,
            detectedAt: "2026-02-12T00:00:00.000Z"
        )
        try dataIntegrityStore.saveIssues(task: .generation, issues: [issue])

        let dataViewModel = BenchmarkViewModel(
            store: dataStore,
            candidateStore: dataCandidateStore,
            integrityStore: dataIntegrityStore,
            datasetPathOverride: casesPath.path
        )
        dataViewModel.selectedTask = .generation
        dataViewModel.refresh()
        let after = try renderSnapshot(viewModel: dataViewModel)
        let afterURL = artifactDir.appendingPathComponent("benchmark_view_after.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    func testRenderBenchmarkErrorStatusChipBeforeAfter() throws {
        let artifactDir = try makeArtifactDirectory()
        let home = try makeTempHome()
        let env = ["HOME": home.path]
        let viewModel = BenchmarkViewModel(
            store: BenchmarkStore(environment: env),
            candidateStore: BenchmarkCandidateStore(environment: env),
            integrityStore: BenchmarkIntegrityStore(environment: env)
        )
        viewModel.refresh()

        viewModel.statusIsError = true
        viewModel.statusMessage = "比較実行に失敗"
        viewModel.benchmarkErrorLog = ""
        let before = try renderSnapshot(viewModel: viewModel)
        let beforeURL = artifactDir.appendingPathComponent("benchmark_error_chip_before.png")
        try pngData(from: before).write(to: beforeURL, options: .atomic)

        viewModel.benchmarkErrorLog = """
        io error: benchmark command failed (exit: 1)
        building...
        error: API key not found
        """
        let after = try renderSnapshot(viewModel: viewModel)
        let afterURL = artifactDir.appendingPathComponent("benchmark_error_chip_after.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    func testRenderBenchmarkPromptCandidateModalAfter() throws {
        let artifactDir = try makeArtifactDirectory()
        let home = try makeTempHome()
        let env = ["HOME": home.path]
        let viewModel = BenchmarkViewModel(
            store: BenchmarkStore(environment: env),
            candidateStore: BenchmarkCandidateStore(environment: env),
            integrityStore: BenchmarkIntegrityStore(environment: env)
        )
        viewModel.selectedTask = .generation
        viewModel.refresh()
        viewModel.openCreatePromptCandidateModal()
        viewModel.promptCandidateDraftName = "modal-preview"
        viewModel.promptCandidateDraftTemplate = "整形してください。入力: {STT結果}"

        let rendered = try renderSnapshot(viewModel: viewModel)
        let url = artifactDir.appendingPathComponent("benchmark_prompt_candidate_modal_after.png")
        try pngData(from: rendered).write(to: url, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRenderBenchmarkViewRoundTripTabSwitchKeepsLayout() throws {
        let artifactDir = try makeArtifactDirectory()
        let home = try makeTempHome()
        let env = ["HOME": home.path]
        let viewModel = BenchmarkViewModel(
            store: BenchmarkStore(environment: env),
            candidateStore: BenchmarkCandidateStore(environment: env),
            integrityStore: BenchmarkIntegrityStore(environment: env)
        )
        viewModel.refresh()

        viewModel.selectedTab = .stt
        let before = try renderSnapshot(viewModel: viewModel)
        let beforeURL = artifactDir.appendingPathComponent("benchmark_roundtrip_comparison_before.png")
        try pngData(from: before).write(to: beforeURL, options: .atomic)

        viewModel.selectedTab = .integrity
        let integrity = try renderSnapshot(viewModel: viewModel)
        let integrityURL = artifactDir.appendingPathComponent("benchmark_roundtrip_integrity.png")
        try pngData(from: integrity).write(to: integrityURL, options: .atomic)

        viewModel.selectedTab = .stt
        let after = try renderSnapshot(viewModel: viewModel)
        let afterURL = artifactDir.appendingPathComponent("benchmark_roundtrip_comparison_after.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)

        XCTAssertEqual(imageDigest(before), imageDigest(after))
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: integrityURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    func testRenderBenchmarkIntegrityAllCasesAfter() throws {
        let artifactDir = try makeArtifactDirectory()
        let dataHome = try makeTempHome()
        let env = ["HOME": dataHome.path]
        let dataStore = BenchmarkStore(environment: env)
        let dataCandidateStore = BenchmarkCandidateStore(environment: env)
        let dataIntegrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = dataHome.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"/tmp/a.wav","stt_text":"","ground_truth_text":"正解1"}
        {"id":"case-2","audio_file":"/tmp/b.wav","stt_text":"入力2","ground_truth_text":"正解2"}
        {"id":"case-3","audio_file":"/tmp/c.wav","stt_text":"入力3","ground_truth_text":"正解3"}

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
        try dataIntegrityStore.saveIssues(task: .generation, issues: [issue])

        let viewModel = BenchmarkViewModel(
            store: dataStore,
            candidateStore: dataCandidateStore,
            integrityStore: dataIntegrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTask = .generation
        viewModel.selectedTab = .integrity
        viewModel.refresh()

        let after = try renderSnapshot(viewModel: viewModel)
        let afterURL = artifactDir.appendingPathComponent("benchmark_integrity_all_cases_after.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    func testRenderBenchmarkIntegrityCaseModalBeforeAfter() throws {
        let artifactDir = try makeArtifactDirectory()
        let home = try makeTempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let imagePath = home.appendingPathComponent("vision.png", isDirectory: false)
        try makeSampleImage(path: imagePath.path)
        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"/tmp/a.wav","stt_text":"STT入力","output_text":"出力ログ","ground_truth_text":"期待出力","vision_image_file":"\(imagePath.path)","vision_image_mime_type":"image/png"}
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

        let before = try renderSnapshot(viewModel: viewModel)
        let beforeURL = artifactDir.appendingPathComponent("benchmark_integrity_case_modal_before.png")
        try pngData(from: before).write(to: beforeURL, options: .atomic)

        viewModel.openIntegrityCaseDetail(caseID: "case-1")
        let after = try renderSnapshot(viewModel: viewModel)
        let afterURL = artifactDir.appendingPathComponent("benchmark_integrity_case_modal_after.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    func testRenderBenchmarkIntegrityCaseModalEditAfter() throws {
        let artifactDir = try makeArtifactDirectory()
        let home = try makeTempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"/tmp/a.wav","stt_text":"STT入力","ground_truth_text":"期待出力"}
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
        viewModel.beginIntegrityCaseEditing()
        viewModel.integrityCaseDraftSTTText = "編集後STT"
        viewModel.integrityCaseDraftGroundTruthText = "編集後期待出力"

        let edit = try renderSnapshot(viewModel: viewModel)
        let editURL = artifactDir.appendingPathComponent("benchmark_integrity_case_modal_edit_after.png")
        try pngData(from: edit).write(to: editURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: editURL.path))
    }

    func testRenderBenchmarkTabsUpdatedUI() throws {
        let artifactDir = try makeArtifactDirectory()
        let home = try makeTempHome()
        let env = ["HOME": home.path]
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let store = BenchmarkStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"/tmp/a.wav","stt_text":"入力","ground_truth_text":"正解"}
        {"id":"case-2","audio_file":"/tmp/b.wav","stt_text":"入力2","ground_truth_text":"正解2"}
        """
        try Data(jsonl.utf8).write(to: casesPath, options: .atomic)

        try candidateStore.saveCandidates([
            BenchmarkCandidate(
                id: "stt-deepgram-stream",
                task: .stt,
                model: "deepgram_stream",
                options: ["use_cache": "true", "chunk_ms": "120"],
                createdAt: "2026-02-12T00:00:00.000Z",
                updatedAt: "2026-02-12T00:00:00.000Z"
            ),
            BenchmarkCandidate(
                id: "generation-a",
                task: .generation,
                model: "gpt-5-nano",
                promptName: "A",
                generationPromptTemplate: "入力: {STT結果}",
                generationPromptHash: promptTemplateHash("入力: {STT結果}"),
                options: ["use_cache": "true", "limit": "2"],
                createdAt: "2026-02-12T00:00:00.000Z",
                updatedAt: "2026-02-12T00:00:00.000Z"
            ),
            BenchmarkCandidate(
                id: "generation-b",
                task: .generation,
                model: "gemini-2.5-flash-lite",
                promptName: "B",
                generationPromptTemplate: "入力を整形: {STT結果}",
                generationPromptHash: promptTemplateHash("入力を整形: {STT結果}"),
                options: ["use_cache": "true", "limit": "2"],
                createdAt: "2026-02-12T00:00:00.000Z",
                updatedAt: "2026-02-12T00:00:00.000Z"
            ),
        ])

        let run = {
            let runID = "stt-20260212-000000-aaaa1111"
            let paths = store.resolveRunPaths(runID: runID)
            return BenchmarkRunRecord(
                id: runID,
                kind: .stt,
                status: .completed,
                createdAt: "2026-02-12T00:00:00.000Z",
                updatedAt: "2026-02-12T00:00:00.000Z",
                options: .stt(BenchmarkSTTRunOptions(
                    common: BenchmarkRunCommonOptions(
                        sourceCasesPath: casesPath.path,
                        datasetHash: "hash-a",
                        runtimeOptionsHash: "runtime-a",
                        evaluatorVersion: "v1",
                        codeVersion: "dev"
                    ),
                    candidateID: "stt-deepgram-stream",
                    sttMode: "stream"
                )),
                candidateID: "stt-deepgram-stream",
                benchmarkKey: BenchmarkKey(
                    task: .stt,
                    datasetPath: casesPath.path,
                    datasetHash: "hash-a",
                    candidateID: "stt-deepgram-stream",
                    runtimeOptionsHash: "runtime-a",
                    evaluatorVersion: "v1",
                    codeVersion: "dev"
                ),
                metrics: .stt(BenchmarkSTTRunMetrics(
                    counts: BenchmarkRunCounts(
                        casesTotal: 2,
                        casesSelected: 2,
                        executedCases: 2,
                        skippedCases: 0,
                        failedCases: 0,
                        cachedHits: 0
                    ),
                    avgCER: 0.16,
                    weightedCER: 0.18,
                    latencyMs: BenchmarkLatencyDistribution(avg: 120, p50: 90, p95: 180, p99: 240),
                    afterStopLatencyMs: BenchmarkLatencyDistribution(avg: 48, p50: 40, p95: 65, p99: 90)
                )),
                paths: paths
            )
        }()
        try store.saveRun(run)
        try store.appendCaseResult(
            runID: run.id,
            result: BenchmarkCaseResult(
                id: "case-1",
                status: .ok,
                reason: nil,
                cache: BenchmarkCacheRecord(hit: false, namespace: "stt"),
                sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
                contextUsed: false,
                visionImageAttached: false,
                metrics: BenchmarkCaseMetrics(
                    cer: 0.13,
                    sttTotalMs: 1200,
                    sttAfterStopMs: 40
                )
            )
        )

        try integrityStore.saveIssues(task: .stt, issues: [
            BenchmarkIntegrityIssue(
                id: "issue-1",
                caseID: "case-1",
                task: .stt,
                issueType: "missing_audio_file",
                missingFields: ["audio_file"],
                sourcePath: casesPath.path,
                excluded: false,
                detectedAt: "2026-02-12T00:00:00.000Z"
            )
        ])

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.refresh()

        let tabs: [(BenchmarkDashboardTab, String)] = [
            (.stt, "benchmark_tab_stt.png"),
            (.generationSingle, "benchmark_tab_generation_single.png"),
            (.generationBattle, "benchmark_tab_generation_battle.png"),
            (.integrity, "benchmark_tab_integrity.png"),
        ]

        for (tab, fileName) in tabs {
            viewModel.selectedTab = tab
            viewModel.refresh()
            let image = try renderSnapshot(viewModel: viewModel)
            let url = artifactDir.appendingPathComponent(fileName)
            try pngData(from: image).write(to: url, options: .atomic)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testRenderBenchmarkGenerationBattlePairwiseModal() throws {
        let artifactDir = try makeArtifactDirectory()
        let home = try makeTempHome()
        let env = ["HOME": home.path]
        let store = BenchmarkStore(environment: env)
        let candidateStore = BenchmarkCandidateStore(environment: env)
        let integrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = home.appendingPathComponent("cases.jsonl", isDirectory: false)
        let jsonl = """
        {"id":"case-1","audio_file":"/tmp/a.wav","stt_text":"元音声テキスト","ground_truth_text":"期待出力"}
        """
        try Data(jsonl.utf8).write(to: casesPath, options: .atomic)

        let generationA = BenchmarkCandidate(
            id: "generation-gpt-5-nano-a",
            task: .generation,
            model: "gpt-5-nano",
            promptName: "A",
            generationPromptTemplate: "入力: {STT結果}",
            generationPromptHash: promptTemplateHash("入力: {STT結果}"),
            options: ["use_cache": "true"],
            createdAt: "2026-02-12T00:00:00.000Z",
            updatedAt: "2026-02-12T00:00:00.000Z"
        )
        let generationB = BenchmarkCandidate(
            id: "generation-gemini-2.5-flash-lite-b",
            task: .generation,
            model: "gemini-2.5-flash-lite",
            promptName: "B",
            generationPromptTemplate: "整形: {STT結果}",
            generationPromptHash: promptTemplateHash("整形: {STT結果}"),
            options: ["use_cache": "true"],
            createdAt: "2026-02-12T00:00:00.000Z",
            updatedAt: "2026-02-12T00:00:00.000Z"
        )
        try candidateStore.saveCandidates([generationA, generationB])

        let runID = "generation-20260212-120000-pair"
        let paths = store.resolveRunPaths(runID: runID)
        try store.saveRun(
            BenchmarkRunRecord(
                id: runID,
                kind: .generation,
                status: .completed,
                createdAt: "2026-02-12T00:00:00.000Z",
                updatedAt: "2026-02-12T00:00:00.000Z",
                options: .generationPairwise(BenchmarkGenerationPairwiseRunOptions(
                    common: BenchmarkRunCommonOptions(
                        sourceCasesPath: casesPath.path,
                        datasetHash: "hash-a",
                        runtimeOptionsHash: "runtime-a",
                        evaluatorVersion: "pairwise-v1",
                        codeVersion: "dev"
                    ),
                    pairCanonicalID: BenchmarkPairwiseNormalizer.canonicalize(generationA.id, generationB.id),
                    pairExecutionOrder: BenchmarkPairExecutionOrder(firstCandidateID: generationA.id, secondCandidateID: generationB.id),
                    pairJudgeModel: "gpt-4o-mini"
                )),
                benchmarkKey: BenchmarkKey(
                    task: .generation,
                    datasetPath: casesPath.path,
                    datasetHash: "hash-a",
                    candidateID: "pair:\(generationA.id)__vs__\(generationB.id)",
                    runtimeOptionsHash: "runtime-a",
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
                        hallucinationAWins: 1,
                        hallucinationBWins: 0,
                        hallucinationTies: 0,
                        styleContextAWins: 1,
                        styleContextBWins: 0,
                        styleContextTies: 0
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
                sources: BenchmarkReferenceSources(input: "元音声テキスト", reference: "期待出力"),
                contextUsed: true,
                visionImageAttached: false,
                metrics: BenchmarkCaseMetrics(
                    pairwise: PairwiseCaseJudgement(
                        overallWinner: .a,
                        intentWinner: .a,
                        hallucinationWinner: .a,
                        styleContextWinner: .a,
                        overallReason: "Aのほうが意図を保った",
                        intentReason: "Aは指示解釈が正確",
                        hallucinationReason: "Aは余計な補足が少ない",
                        styleContextReason: "Aの文体が自然"
                    )
                )
            )
        )
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "input_stt.txt", text: "元音声テキスト")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "prompt_generation_a.txt", text: "A prompt")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "prompt_generation_b.txt", text: "B prompt")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "output_generation_a.txt", text: "整形A")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "output_generation_b.txt", text: "整形B")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "prompt_pairwise_round1.txt", text: "比較プロンプト round1")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "prompt_pairwise_round2.txt", text: "比較プロンプト round2")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "pairwise_round1_response.json", text: "{\"winner\":\"A\",\"score\":0.93}")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "pairwise_round2_response.json", text: "{\"winner\":\"B\",\"score\":0.77}")
        _ = try store.writeCaseIOText(runID: runID, caseID: "case-1", fileName: "pairwise_decision.json", text: "{\"overall\":\"A\",\"intent\":\"A\",\"hallucination\":\"A\",\"style\":\"A\"}")

        let viewModel = BenchmarkViewModel(
            store: store,
            candidateStore: candidateStore,
            integrityStore: integrityStore,
            datasetPathOverride: casesPath.path
        )
        viewModel.selectedTab = .generationBattle
        viewModel.selectedTask = .generation
        viewModel.refresh()
        viewModel.setGenerationPairCandidateA(generationA.id)
        viewModel.setGenerationPairCandidateB(generationB.id)
        viewModel.setGenerationPairJudgeModel(.gpt4oMini)
        viewModel.selectGenerationPairwiseCase("case-1")
        viewModel.isPairwiseCaseDetailPresented = true
        XCTAssertNotNil(viewModel.generationPairwiseCaseDetail)

        let before = try renderPairwiseModalSnapshot(viewModel: viewModel, startsInJudgeTab: true)
        let beforeURL = artifactDir.appendingPathComponent("benchmark_pairwise_modal_before_judge_image.png")
        try pngData(from: before).write(to: beforeURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))

        let judgeImagePath = home.appendingPathComponent("judge-input.png", isDirectory: false)
        try makeSampleImage(path: judgeImagePath.path)
        _ = try store.writeCaseIOText(
            runID: runID,
            caseID: "case-1",
            fileName: "pairwise_judge_input_meta.json",
            text: """
            {
              "vision_image_path": "\(judgeImagePath.path)",
              "vision_image_mime_type": "image/png",
              "image_attached": true,
              "image_missing": false
            }
            """
        )

        viewModel.refresh()
        viewModel.setGenerationPairCandidateA(generationA.id)
        viewModel.setGenerationPairCandidateB(generationB.id)
        viewModel.setGenerationPairJudgeModel(.gpt4oMini)
        viewModel.selectGenerationPairwiseCase("case-1")
        viewModel.isPairwiseCaseDetailPresented = true
        XCTAssertNotNil(viewModel.generationPairwiseCaseDetail)

        let after = try renderPairwiseModalSnapshot(viewModel: viewModel, startsInJudgeTab: true)
        let afterURL = artifactDir.appendingPathComponent("benchmark_pairwise_modal_after_judge_image.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    private func renderSnapshot(viewModel: BenchmarkViewModel) throws -> NSBitmapImageRep {
        let root = BenchmarkView(viewModel: viewModel, autoRefreshOnAppear: false)
            .frame(width: CGFloat(width), height: CGFloat(height))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw AppError.io("failed to create bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private func renderPairwiseModalSnapshot(
        viewModel: BenchmarkViewModel,
        startsInJudgeTab: Bool
    ) throws -> NSBitmapImageRep {
        let root = BenchmarkPairwiseCaseDetailModal(
            viewModel: viewModel,
            startsInJudgeTab: startsInJudgeTab
        )
        .frame(width: CGFloat(width), height: CGFloat(height))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw AppError.io("failed to create bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private func pngData(from bitmap: NSBitmapImageRep) throws -> Data {
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.io("failed to encode png")
        }
        return png
    }

    private func imageDigest(_ bitmap: NSBitmapImageRep) -> String {
        let data = bitmap.tiffRepresentation ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeArtifactDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = root.appendingPathComponent(".build/snapshot-artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSampleImage(path: String) throws {
        let width = 520
        let height = 260
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw AppError.io("failed to allocate bitmap")
        }
        let size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            throw AppError.io("failed to create graphics context")
        }
        NSGraphicsContext.current = context

        NSColor(calibratedRed: 0.95, green: 0.97, blue: 1.0, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        NSColor(calibratedRed: 0.15, green: 0.30, blue: 0.75, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 20, y: 184, width: 220, height: 52), xRadius: 10, yRadius: 10).fill()

        NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 280, y: 72, width: 210, height: 132), xRadius: 10, yRadius: 10).fill()

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:])
        else {
            throw AppError.io("failed to make sample image")
        }
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
