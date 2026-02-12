import AVFAudio
import AppKit
import CryptoKit
import Foundation
import WhispCore

enum BenchmarkDashboardTab: String, CaseIterable, Identifiable {
    case comparison = "Comparison"
    case integrity = "Case Integrity"

    var id: String { rawValue }
}

struct BenchmarkComparisonRow: Identifiable, Equatable {
    let candidate: BenchmarkCandidate
    let runCount: Int
    let executedCases: Int
    let skipCases: Int
    let avgCER: Double?
    let weightedCER: Double?
    let sttAfterStopP50: Double?
    let sttAfterStopP95: Double?
    let postMsP95: Double?
    let totalAfterStopP95: Double?
    let intentPreservationScore: Double?
    let hallucinationRate: Double?
    let lastRunAt: String?
    let datasetHashMismatch: Bool
    let currentDatasetHash: String?
    let latestRunDatasetHash: String?
    let latestRuntimeOptionsHash: String?
    let latestRunID: String?

    var id: String { candidate.id }
}

struct BenchmarkCaseBreakdownRow: Identifiable, Equatable {
    let id: String
    let status: BenchmarkCaseStatus
    let reason: String?
    let cer: Double?
    let sttTotalMs: Double?
    let sttAfterStopMs: Double?
    let postMs: Double?
    let totalAfterStopMs: Double?
    let intentPreservationScore: Double?
    let hallucinationRate: Double?
}

struct BenchmarkCaseDetail: Identifiable, Equatable {
    let runID: String
    let caseID: String
    let status: BenchmarkCaseStatus
    let reason: String?
    let audioFilePath: String?
    let recordingMs: Double?
    let sttMs: Double?
    let sttDeltaAfterRecordingMs: Double?
    let sttProvider: String?
    let sttRoute: String?
    let sttText: String?
    let referenceText: String?
    let attempts: [BenchmarkSTTAttempt]
    let cer: Double?
    let sttTotalMs: Double?
    let sttAfterStopMs: Double?
    let timeline: BenchmarkCaseTimelineSummary
    let missingDataMessages: [String]

    var id: String { "\(runID):\(caseID)" }
}

struct BenchmarkIntegrityCaseRow: Identifiable, Equatable {
    let id: String
    let audioFile: String
    let sttPreview: String
    let referencePreview: String
    let issueCount: Int
    let activeIssueCount: Int
    let excludedIssueCount: Int
    let issueTypesSummary: String
    let missingInDataset: Bool

    var hasActiveIssues: Bool { activeIssueCount > 0 }
    var hasOnlyExcludedIssues: Bool { issueCount > 0 && activeIssueCount == 0 }
}

@MainActor
final class BenchmarkViewModel: ObservableObject {
    @Published var selectedTab: BenchmarkDashboardTab = .comparison
    @Published var selectedTask: BenchmarkKind = .stt {
        didSet { handleTaskChanged() }
    }
    @Published var forceRerun = false

    @Published var candidates: [BenchmarkCandidate] = []
    @Published var selectedCandidateIDs: Set<String> = []
    @Published var comparisonRows: [BenchmarkComparisonRow] = []
    @Published var selectedComparisonCandidateID: String?
    @Published var caseBreakdownRows: [BenchmarkCaseBreakdownRow] = []
    @Published var isCaseDetailPresented = false
    @Published var selectedCaseDetail: BenchmarkCaseDetail?
    @Published var isCaseAudioPlaying = false

    @Published var integrityIssues: [BenchmarkIntegrityIssue] = []
    @Published var integrityCaseRows: [BenchmarkIntegrityCaseRow] = []
    @Published var selectedIntegrityIssueID: String?
    @Published var selectedIntegrityCaseID: String?

    @Published var statusMessage = ""
    @Published var statusIsError = false
    @Published var benchmarkErrorLog = ""
    @Published var isExecutingBenchmark = false

    private let store: BenchmarkStore
    private let candidateStore: BenchmarkCandidateStore
    private let integrityStore: BenchmarkIntegrityStore
    private let benchmarkDatasetPath: String
    private let caseEventAnalyzer = BenchmarkCaseEventAnalyzer()
    private var caseAudioPlayer: AVAudioPlayer?
    private var caseAudioPollingTimer: Timer?

    init(
        store: BenchmarkStore,
        candidateStore: BenchmarkCandidateStore = BenchmarkCandidateStore(),
        integrityStore: BenchmarkIntegrityStore = BenchmarkIntegrityStore(),
        datasetPathOverride: String? = nil
    ) {
        self.store = store
        self.candidateStore = candidateStore
        self.integrityStore = integrityStore
        benchmarkDatasetPath = Self.resolveDatasetPath(pathOverride: datasetPathOverride)
    }

    var taskCandidates: [BenchmarkCandidate] {
        candidates
            .filter { $0.task == selectedTask }
            .sorted { $0.id < $1.id }
    }

    var selectedComparisonRow: BenchmarkComparisonRow? {
        guard let selectedComparisonCandidateID else { return nil }
        return comparisonRows.first { $0.candidate.id == selectedComparisonCandidateID }
    }

    var selectedIntegrityIssue: BenchmarkIntegrityIssue? {
        guard let selectedIntegrityIssueID else { return nil }
        return integrityIssues.first { $0.id == selectedIntegrityIssueID }
    }

    var selectedIntegrityCaseRow: BenchmarkIntegrityCaseRow? {
        guard let selectedIntegrityCaseID else { return nil }
        return integrityCaseRows.first { $0.id == selectedIntegrityCaseID }
    }

    var selectedIntegrityCaseIssues: [BenchmarkIntegrityIssue] {
        guard let selectedIntegrityCaseID else { return [] }
        return integrityIssues.filter { $0.caseID == selectedIntegrityCaseID }
    }

    var canToggleSelectedIntegrityCaseExclusion: Bool {
        !selectedIntegrityCaseIssues.isEmpty
    }

    var selectedIntegrityCaseExclusionLabel: String {
        guard !selectedIntegrityCaseIssues.isEmpty else {
            return "Exclude"
        }
        let hasActive = selectedIntegrityCaseIssues.contains(where: { !$0.excluded })
        return hasActive ? "Exclude" : "Unexclude"
    }

    var hasBenchmarkErrorLog: Bool {
        !normalizedErrorLog(benchmarkErrorLog).isEmpty
    }

    var benchmarkErrorHeadline: String {
        compactHeadline(for: normalizedErrorLog(benchmarkErrorLog))
    }

    func refresh() {
        do {
            try reloadAll()
            setStatus("ベンチマーク画面を更新しました。", isError: false, clearErrorLog: true)
        } catch {
            setStatus("読み込みに失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    func runCompare() {
        guard !isExecutingBenchmark else { return }
        let task = selectedTask
        let dataset = benchmarkDatasetPath
        let force = forceRerun
        let candidateIDs = taskCandidates
            .map(\.id)
            .filter { selectedCandidateIDs.contains($0) }
        guard !candidateIDs.isEmpty else {
            setStatus("Candidateを1件以上選択してください。", isError: true)
            return
        }

        isExecutingBenchmark = true
        setStatus("比較実行を開始しました。", isError: false, clearErrorLog: true)

        Task {
            defer { isExecutingBenchmark = false }
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try Self.runCompareCommand(
                        task: task,
                        datasetPath: dataset,
                        candidateIDs: candidateIDs,
                        force: force
                    )
                }.value
                try reloadAll()
                setStatus("比較実行が完了しました。", isError: false, clearErrorLog: true)
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    benchmarkErrorLog = ""
                }
            } catch {
                let log = normalizedErrorLog(error.localizedDescription)
                setStatus("比較実行に失敗: \(compactHeadline(for: log))", isError: true, errorLog: log)
            }
        }
    }

    func scanIntegrity() {
        guard !isExecutingBenchmark else { return }
        let task = selectedTask
        let dataset = benchmarkDatasetPath
        isExecutingBenchmark = true
        setStatus("ケース不備スキャンを開始しました。", isError: false, clearErrorLog: true)

        Task {
            defer { isExecutingBenchmark = false }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try Self.runIntegrityScanCommand(task: task, datasetPath: dataset)
                }.value
                try loadIntegrityIssues()
                try loadIntegrityCaseRows()
                setStatus("ケース不備スキャンが完了しました。", isError: false, clearErrorLog: true)
            } catch {
                let log = normalizedErrorLog(error.localizedDescription)
                setStatus("ケース不備スキャンに失敗: \(compactHeadline(for: log))", isError: true, errorLog: log)
            }
        }
    }

    func toggleCandidateSelection(_ candidateID: String) {
        if selectedCandidateIDs.contains(candidateID) {
            selectedCandidateIDs.remove(candidateID)
        } else {
            selectedCandidateIDs.insert(candidateID)
        }
    }

    func selectComparisonCandidate(_ candidateID: String?) {
        clearCaseDetail()
        selectedComparisonCandidateID = candidateID
        reloadCaseBreakdown()
    }

    func openCaseDetail(caseID: String) {
        guard let row = selectedComparisonRow,
              let runID = row.latestRunID,
              let caseRow = caseBreakdownRows.first(where: { $0.id == caseID })
        else {
            setStatus("ケース詳細の読み込み対象が見つかりません。", isError: true)
            return
        }

        do {
            let events = try store.loadEvents(runID: runID, caseID: caseID)
            let analysis = caseEventAnalyzer.analyze(events: events)
            let sttLog = analysis.sttLog
            let attempts = sttLog?.attempts ?? []

            var missingDataMessages = analysis.timeline.missingMessages
            if sttLog == nil {
                missingDataMessages.append("stt イベントが不足しています。")
            } else if attempts.isEmpty {
                missingDataMessages.append("stt attempt データが不足しています。")
            }

            selectedCaseDetail = BenchmarkCaseDetail(
                runID: runID,
                caseID: caseID,
                status: caseRow.status,
                reason: caseRow.reason,
                audioFilePath: analysis.audioFilePath,
                recordingMs: analysis.timeline.recordingMs,
                sttMs: analysis.timeline.sttMs,
                sttDeltaAfterRecordingMs: sttLog?.sttAfterStopMs
                    ?? analysis.timeline.deltaAfterRecordingMs
                    ?? {
                        guard let sttTotal = sttLog?.sttTotalMs ?? caseRow.sttTotalMs,
                              let recording = analysis.timeline.recordingMs
                        else {
                            return nil
                        }
                        return max(0, sttTotal - recording)
                    }(),
                sttProvider: sttLog?.provider,
                sttRoute: sttLog?.mode,
                sttText: sttLog?.transcriptText,
                referenceText: sttLog?.referenceText,
                attempts: attempts,
                cer: sttLog?.cer ?? caseRow.cer,
                sttTotalMs: sttLog?.sttTotalMs ?? caseRow.sttTotalMs,
                sttAfterStopMs: sttLog?.sttAfterStopMs ?? caseRow.sttAfterStopMs,
                timeline: analysis.timeline,
                missingDataMessages: missingDataMessages
            )
            isCaseDetailPresented = true
        } catch {
            setStatus("ケース詳細読み込みに失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    func dismissCaseDetail() {
        clearCaseDetail()
    }

    func toggleCaseAudioPlayback() {
        if isCaseAudioPlaying {
            stopCaseAudioPlayback(showMessage: false)
            return
        }
        playCaseAudio()
    }

    func selectIntegrityIssue(_ issueID: String?) {
        selectedIntegrityIssueID = issueID
        if let issueID,
           let issue = integrityIssues.first(where: { $0.id == issueID })
        {
            selectedIntegrityCaseID = issue.caseID
        }
    }

    func selectIntegrityCase(_ caseID: String?) {
        selectedIntegrityCaseID = caseID
        if let caseID {
            selectedIntegrityIssueID = integrityIssues.first(where: { $0.caseID == caseID })?.id
        } else {
            selectedIntegrityIssueID = nil
        }
    }

    func toggleSelectedIntegrityCaseExclusion() {
        let issues = selectedIntegrityCaseIssues
        guard !issues.isEmpty else {
            setStatus("除外対象の不備がありません。", isError: true)
            return
        }
        let shouldExclude = issues.contains(where: { !$0.excluded })
        do {
            for issue in issues {
                try integrityStore.setExcluded(issueID: issue.id, task: issue.task, excluded: shouldExclude)
            }
            try loadIntegrityIssues()
            try loadIntegrityCaseRows()
            setStatus(
                shouldExclude ? "ケース不備を除外しました。" : "ケース不備の除外を解除しました。",
                isError: false,
                clearErrorLog: true
            )
        } catch {
            setStatus("除外更新に失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    func setIssueExcluded(_ issue: BenchmarkIntegrityIssue, excluded: Bool) {
        do {
            try integrityStore.setExcluded(issueID: issue.id, task: issue.task, excluded: excluded)
            try loadIntegrityIssues()
            try loadIntegrityCaseRows()
            setStatus(
                excluded ? "ケースを除外しました。" : "ケース除外を解除しました。",
                isError: false,
                clearErrorLog: true
            )
        } catch {
            setStatus("除外更新に失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    func copySelectedIssueCaseID() {
        guard let caseID = selectedIntegrityCaseID ?? selectedIntegrityIssue?.caseID else {
            setStatus("case_id を選択してください。", isError: true)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(caseID, forType: .string)
        setStatus("case_id をコピーしました。", isError: false)
    }

    func openRelatedRunDirectory() {
        guard let caseID = selectedIntegrityCaseID ?? selectedIntegrityIssue?.caseID else {
            setStatus("case_id を選択してください。", isError: true)
            return
        }
        do {
            guard let runID = try findRelatedRunID(
                task: selectedTask,
                sourcePath: benchmarkDatasetPath,
                caseID: caseID
            ) else {
                setStatus("関連runディレクトリが見つかりません。", isError: true)
                return
            }
            let path = store.runDirectoryPath(runID: runID)
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        } catch {
            setStatus("関連run検索に失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    func copyBenchmarkErrorLog() {
        let log = normalizedErrorLog(benchmarkErrorLog)
        guard !log.isEmpty else {
            setStatus("コピー対象のエラーログがありません。", isError: true)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(log, forType: .string)
        setStatus("エラーログをコピーしました。", isError: false)
    }

    func benchmarkKindLabel(_ kind: BenchmarkKind) -> String {
        switch kind {
        case .stt:
            return "STT"
        case .generation:
            return "Generation"
        case .vision:
            return "Vision"
        }
    }

    private func handleTaskChanged() {
        clearCaseDetail()
        do {
            try loadComparisonRows()
            try loadIntegrityIssues()
            try loadIntegrityCaseRows()
        } catch {
            setStatus("タスク切り替えに失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    private func reloadAll() throws {
        try ensureDefaultCandidatesIfNeeded()
        candidates = try candidateStore.listCandidates()
        let valid = Set(taskCandidates.map(\.id))
        selectedCandidateIDs = selectedCandidateIDs.intersection(valid)
        if selectedCandidateIDs.isEmpty {
            selectedCandidateIDs = Set(taskCandidates.prefix(3).map(\.id))
        }
        try loadComparisonRows()
        try loadIntegrityIssues()
        try loadIntegrityCaseRows()
    }

    private func ensureDefaultCandidatesIfNeeded() throws {
        let existing = try candidateStore.listCandidates()
        let now = Self.isoNow()
        let defaults = [
            BenchmarkCandidate(
                id: "stt-deepgram-stream-default",
                task: .stt,
                model: "deepgram",
                promptProfileID: nil,
                options: [
                    "stt_mode": "stream",
                    "chunk_ms": "120",
                    "realtime": "true",
                    "min_audio_seconds": "2.0",
                    "use_cache": "true",
                ],
                createdAt: now,
                updatedAt: now
            ),
            BenchmarkCandidate(
                id: "stt-apple-speech-rest-default",
                task: .stt,
                model: "apple_speech",
                promptProfileID: nil,
                options: [
                    "stt_mode": "rest",
                    "chunk_ms": "120",
                    "realtime": "true",
                    "min_audio_seconds": "2.0",
                    "use_cache": "true",
                ],
                createdAt: now,
                updatedAt: now
            ),
            BenchmarkCandidate(
                id: "generation-gemini-2.5-flash-lite-default",
                task: .generation,
                model: "gemini-2.5-flash-lite",
                promptProfileID: nil,
                options: [
                    "require_context": "false",
                    "use_cache": "true",
                    "llm_eval": "false",
                ],
                createdAt: now,
                updatedAt: now
            ),
        ]

        if existing.isEmpty {
            try candidateStore.saveCandidates(defaults)
            return
        }

        var merged = existing
        let existingIDs = Set(existing.map(\.id))
        for candidate in defaults where !existingIDs.contains(candidate.id) {
            merged.append(candidate)
        }

        if merged.count != existing.count {
            try candidateStore.saveCandidates(merged)
        }
    }

    private func loadComparisonRows() throws {
        let allRuns = try store.listRuns(limit: 2_000)
        let normalizedDatasetPath = benchmarkDatasetPath
        let currentDatasetHash = datasetHashIfExists(path: normalizedDatasetPath)

        comparisonRows = taskCandidates.map { candidate in
            let runsForCandidate = allRuns.filter { run in
                guard run.kind == selectedTask else { return false }
                let runCandidateID = run.candidateID ?? run.options.candidateID
                guard runCandidateID == candidate.id else { return false }
                return normalizePath(run.options.sourceCasesPath) == normalizedDatasetPath
            }
            let sorted = runsForCandidate.sorted { $0.updatedAt > $1.updatedAt }
            let latest = sorted.first
            let runDatasetHash = latest?.benchmarkKey?.datasetHash ?? latest?.options.datasetHash
            let datasetHashMismatch: Bool
            if let currentDatasetHash, let runDatasetHash {
                datasetHashMismatch = currentDatasetHash != runDatasetHash
            } else {
                datasetHashMismatch = false
            }

            return BenchmarkComparisonRow(
                candidate: candidate,
                runCount: runsForCandidate.count,
                executedCases: latest?.metrics.executedCases ?? 0,
                skipCases: latest?.metrics.skippedCases ?? 0,
                avgCER: latest?.metrics.avgCER,
                weightedCER: latest?.metrics.weightedCER,
                sttAfterStopP50: latest?.metrics.afterStopLatencyMs?.p50,
                sttAfterStopP95: latest?.metrics.afterStopLatencyMs?.p95,
                postMsP95: latest?.metrics.postLatencyMs?.p95,
                totalAfterStopP95: latest?.metrics.totalAfterStopLatencyMs?.p95,
                intentPreservationScore: latest?.metrics.intentPreservationScore,
                hallucinationRate: latest?.metrics.hallucinationRate,
                lastRunAt: latest?.updatedAt,
                datasetHashMismatch: datasetHashMismatch,
                currentDatasetHash: currentDatasetHash,
                latestRunDatasetHash: runDatasetHash,
                latestRuntimeOptionsHash: latest?.benchmarkKey?.runtimeOptionsHash ?? latest?.options.runtimeOptionsHash,
                latestRunID: latest?.id
            )
        }
        .sorted {
            let lhs = $0.lastRunAt ?? ""
            let rhs = $1.lastRunAt ?? ""
            if lhs != rhs {
                return lhs > rhs
            }
            return $0.candidate.id < $1.candidate.id
        }

        if let selectedComparisonCandidateID,
           comparisonRows.contains(where: { $0.candidate.id == selectedComparisonCandidateID })
        {
            reloadCaseBreakdown()
        } else {
            selectedComparisonCandidateID = comparisonRows.first?.candidate.id
            reloadCaseBreakdown()
        }
    }

    private func reloadCaseBreakdown() {
        guard let row = selectedComparisonRow,
              let runID = row.latestRunID
        else {
            clearCaseDetail()
            caseBreakdownRows = []
            return
        }

        do {
            let results = try store.loadCaseResults(runID: runID)
            caseBreakdownRows = results
                .map { result in
                    BenchmarkCaseBreakdownRow(
                        id: result.id,
                        status: result.status,
                        reason: result.reason,
                        cer: result.metrics.cer,
                        sttTotalMs: result.metrics.sttTotalMs,
                        sttAfterStopMs: result.metrics.sttAfterStopMs,
                        postMs: result.metrics.postMs,
                        totalAfterStopMs: result.metrics.totalAfterStopMs,
                        intentPreservationScore: result.metrics.intentPreservationScore,
                        hallucinationRate: result.metrics.hallucinationRate
                    )
                }
                .sorted(by: caseBreakdownSort)
        } catch {
            clearCaseDetail()
            caseBreakdownRows = []
            setStatus("ケース詳細読み込みに失敗: \(error.localizedDescription)", isError: true)
        }
    }

    private func caseBreakdownSort(_ lhs: BenchmarkCaseBreakdownRow, _ rhs: BenchmarkCaseBreakdownRow) -> Bool {
        if lhs.status != rhs.status {
            let rank: [BenchmarkCaseStatus: Int] = [.error: 0, .skipped: 1, .ok: 2]
            return rank[lhs.status, default: 3] < rank[rhs.status, default: 3]
        }
        let lhsScore = lhs.cer ?? -1
        let rhsScore = rhs.cer ?? -1
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        let lhsLatency = lhs.totalAfterStopMs ?? lhs.postMs ?? lhs.sttTotalMs ?? -1
        let rhsLatency = rhs.totalAfterStopMs ?? rhs.postMs ?? rhs.sttTotalMs ?? -1
        if lhsLatency != rhsLatency {
            return lhsLatency > rhsLatency
        }
        return lhs.id < rhs.id
    }

    private func loadIntegrityIssues() throws {
        integrityIssues = try integrityStore.loadIssues(task: selectedTask)
        if let selectedIntegrityIssueID,
           !integrityIssues.contains(where: { $0.id == selectedIntegrityIssueID })
        {
            self.selectedIntegrityIssueID = nil
        }

        if let selectedIntegrityCaseID,
           let issue = integrityIssues.first(where: { $0.caseID == selectedIntegrityCaseID })
        {
            selectedIntegrityIssueID = issue.id
            return
        }

        if selectedIntegrityIssueID == nil {
            selectedIntegrityIssueID = integrityIssues.first?.id
        }
    }

    private func loadIntegrityCaseRows() throws {
        let cases = try loadIntegrityDatasetCases(path: benchmarkDatasetPath)
        let issuesByCase = Dictionary(grouping: integrityIssues, by: \.caseID)
        let knownCaseIDs = Set(cases.map(\.id))

        var rows: [BenchmarkIntegrityCaseRow] = cases.map { item in
            let caseIssues = issuesByCase[item.id] ?? []
            let activeIssueCount = caseIssues.filter { !$0.excluded }.count
            let excludedIssueCount = caseIssues.count - activeIssueCount
            let issueTypes = caseIssues
                .filter { !$0.excluded }
                .map(\.issueType)
            let issueTypesFallback = caseIssues.map(\.issueType)
            let summary = (issueTypes.isEmpty ? issueTypesFallback : issueTypes)
                .sorted()
                .joined(separator: ", ")

            return BenchmarkIntegrityCaseRow(
                id: item.id,
                audioFile: shortFileName(item.audioFile),
                sttPreview: preview(item.sttText),
                referencePreview: preview(item.referenceText),
                issueCount: caseIssues.count,
                activeIssueCount: activeIssueCount,
                excludedIssueCount: excludedIssueCount,
                issueTypesSummary: summary.isEmpty ? "-" : summary,
                missingInDataset: false
            )
        }

        for (caseID, caseIssues) in issuesByCase where !knownCaseIDs.contains(caseID) {
            let activeIssueCount = caseIssues.filter { !$0.excluded }.count
            let excludedIssueCount = caseIssues.count - activeIssueCount
            let issueTypes = caseIssues
                .filter { !$0.excluded }
                .map(\.issueType)
            let issueTypesFallback = caseIssues.map(\.issueType)
            let summary = (issueTypes.isEmpty ? issueTypesFallback : issueTypes)
                .sorted()
                .joined(separator: ", ")

            rows.append(
                BenchmarkIntegrityCaseRow(
                    id: caseID,
                    audioFile: "-",
                    sttPreview: "-",
                    referencePreview: "-",
                    issueCount: caseIssues.count,
                    activeIssueCount: activeIssueCount,
                    excludedIssueCount: excludedIssueCount,
                    issueTypesSummary: summary.isEmpty ? "-" : summary,
                    missingInDataset: true
                )
            )
        }

        integrityCaseRows = rows.sorted(by: integrityCaseSort)

        if let selectedIntegrityCaseID,
           integrityCaseRows.contains(where: { $0.id == selectedIntegrityCaseID })
        {
            if let issue = integrityIssues.first(where: { $0.caseID == selectedIntegrityCaseID }) {
                selectedIntegrityIssueID = issue.id
            }
            return
        }

        selectedIntegrityCaseID = integrityCaseRows.first?.id
        if let selectedIntegrityCaseID {
            selectedIntegrityIssueID = integrityIssues.first(where: { $0.caseID == selectedIntegrityCaseID })?.id
        } else {
            selectedIntegrityIssueID = nil
        }
    }

    private func integrityCaseSort(_ lhs: BenchmarkIntegrityCaseRow, _ rhs: BenchmarkIntegrityCaseRow) -> Bool {
        let lhsRank: Int
        if lhs.hasActiveIssues {
            lhsRank = 0
        } else if lhs.hasOnlyExcludedIssues {
            lhsRank = 1
        } else {
            lhsRank = 2
        }

        let rhsRank: Int
        if rhs.hasActiveIssues {
            rhsRank = 0
        } else if rhs.hasOnlyExcludedIssues {
            rhsRank = 1
        } else {
            rhsRank = 2
        }

        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.id < rhs.id
    }

    private func findRelatedRunID(task: BenchmarkKind, sourcePath: String, caseID: String) throws -> String? {
        let normalizedIssuePath = normalizePath(sourcePath)
        let runs = try store.listRuns(limit: 500)
        for run in runs where run.kind == task {
            if normalizePath(run.options.sourceCasesPath) != normalizedIssuePath {
                continue
            }
            let rows = try store.loadCaseResults(runID: run.id)
            if rows.contains(where: { $0.id == caseID }) {
                return run.id
            }
        }
        return nil
    }

    private func playCaseAudio() {
        guard let path = selectedCaseDetail?.audioFilePath,
              !path.isEmpty
        else {
            setStatus("音声ファイルが見つかりません。", isError: true)
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            setStatus("音声ファイルが存在しません: \(path)", isError: true)
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            stopCaseAudioPlayback(showMessage: false)
            caseAudioPlayer = player
            player.prepareToPlay()
            guard player.play() else {
                throw AppError.io("再生開始に失敗しました")
            }
            isCaseAudioPlaying = true
            startCaseAudioPolling()
            setStatus("ケース音声を再生中です。", isError: false)
        } catch {
            stopCaseAudioPlayback(showMessage: false)
            setStatus("ケース音声の再生に失敗: \(error.localizedDescription)", isError: true)
        }
    }

    private func stopCaseAudioPlayback(showMessage: Bool) {
        caseAudioPlayer?.stop()
        caseAudioPlayer = nil
        caseAudioPollingTimer?.invalidate()
        caseAudioPollingTimer = nil
        isCaseAudioPlaying = false
        if showMessage {
            setStatus("ケース音声の再生を停止しました。", isError: false)
        }
    }

    private func startCaseAudioPolling() {
        caseAudioPollingTimer?.invalidate()
        caseAudioPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let player = self.caseAudioPlayer else {
                    self.stopCaseAudioPlayback(showMessage: false)
                    return
                }
                if !player.isPlaying {
                    self.stopCaseAudioPlayback(showMessage: false)
                }
            }
        }
    }

    private func clearCaseDetail() {
        stopCaseAudioPlayback(showMessage: false)
        selectedCaseDetail = nil
        isCaseDetailPresented = false
    }

    private func setStatus(
        _ message: String,
        isError: Bool,
        errorLog: String? = nil,
        clearErrorLog: Bool = false
    ) {
        statusMessage = message
        statusIsError = isError
        if clearErrorLog {
            benchmarkErrorLog = ""
        }
        if let errorLog {
            let normalized = normalizedErrorLog(errorLog)
            if !normalized.isEmpty {
                benchmarkErrorLog = normalized
            }
        } else if isError {
            let normalized = normalizedErrorLog(message)
            if !normalized.isEmpty {
                benchmarkErrorLog = normalized
            }
        }
    }

    private func normalizedErrorLog(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compactHeadline(for log: String) -> String {
        let firstLine = log
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !firstLine.isEmpty else {
            return "不明なエラー"
        }
        let maxChars = 86
        guard firstLine.count > maxChars else {
            return firstLine
        }
        return "\(firstLine.prefix(maxChars - 3))..."
    }

    private struct IntegrityCaseLabels: Decodable {
        let transcriptGold: String?
        let transcriptSilver: String?

        enum CodingKeys: String, CodingKey {
            case transcriptGold = "transcript_gold"
            case transcriptSilver = "transcript_silver"
        }
    }

    private struct IntegrityDatasetCase: Decodable {
        let id: String
        let audioFile: String?
        let sttText: String?
        let groundTruthText: String?
        let createdAt: String?
        let labels: IntegrityCaseLabels?

        enum CodingKeys: String, CodingKey {
            case id
            case audioFile = "audio_file"
            case sttText = "stt_text"
            case groundTruthText = "ground_truth_text"
            case createdAt = "created_at"
            case labels
        }

        var referenceText: String? {
            let direct = (groundTruthText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !direct.isEmpty {
                return direct
            }
            let gold = (labels?.transcriptGold ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !gold.isEmpty {
                return gold
            }
            let silver = (labels?.transcriptSilver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !silver.isEmpty {
                return silver
            }
            return nil
        }
    }

    private func loadIntegrityDatasetCases(path: String) throws -> [IntegrityDatasetCase] {
        let normalizedPath = normalizePath(path)
        guard !normalizedPath.isEmpty else {
            return []
        }
        guard FileManager.default.fileExists(atPath: normalizedPath) else {
            return []
        }

        let content = try String(contentsOfFile: normalizedPath, encoding: .utf8)
        let decoder = JSONDecoder()
        var uniqueByID: [String: IntegrityDatasetCase] = [:]
        var order: [String] = []

        for (index, rawLine) in content.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            guard let data = line.data(using: .utf8) else {
                throw AppError.invalidArgument("ケース一覧の読み込みに失敗しました(line=\(index + 1))")
            }
            do {
                let item = try decoder.decode(IntegrityDatasetCase.self, from: data)
                if uniqueByID[item.id] == nil {
                    order.append(item.id)
                }
                uniqueByID[item.id] = item
            } catch {
                throw AppError.invalidArgument("ケース一覧JSONLのデコードに失敗しました(line=\(index + 1)): \(error.localizedDescription)")
            }
        }

        return order.compactMap { uniqueByID[$0] }
    }

    private func shortFileName(_ path: String?) -> String {
        let trimmed = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "-"
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private func preview(_ text: String?, maxLength: Int = 56) -> String {
        let normalized = (text ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "-"
        }
        if normalized.count <= maxLength {
            return normalized
        }
        return "\(normalized.prefix(maxLength - 3))..."
    }

    private func datasetHashIfExists(path: String) -> String? {
        let normalized = normalizePath(path)
        guard FileManager.default.fileExists(atPath: normalized),
              let data = try? Data(contentsOf: URL(fileURLWithPath: normalized, isDirectory: false))
        else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func normalizePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + "/" + trimmed.dropFirst(2)
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    nonisolated private static func resolveDatasetPath(pathOverride: String?) -> String {
        if let override = pathOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return normalizePathForStorage(override)
        }
        if let paths = try? WhispPaths() {
            return normalizePathForStorage(paths.manualCasesFile.path)
        }
        return normalizePathForStorage("~/.config/whisp/debug/manual_test_cases.jsonl")
    }

    nonisolated private static func normalizePathForStorage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + "/" + trimmed.dropFirst(2)
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    nonisolated private static func runCompareCommand(
        task: BenchmarkKind,
        datasetPath: String,
        candidateIDs: [String],
        force: Bool
    ) throws -> String {
        var args = [
            "--benchmark-compare",
            "--task", task.rawValue,
            "--cases", datasetPath,
        ]
        for candidateID in candidateIDs {
            args.append("--candidate-id")
            args.append(candidateID)
        }
        if force {
            args.append("--force")
        }
        return try runWhispCLI(args)
    }

    nonisolated private static func runIntegrityScanCommand(task: BenchmarkKind, datasetPath: String) throws -> String {
        let args = [
            "--benchmark-scan-integrity",
            "--task", task.rawValue,
            "--cases", datasetPath,
        ]
        return try runWhispCLI(args)
    }

    nonisolated private static func runWhispCLI(_ arguments: [String]) throws -> String {
        let projectRoot = try resolveProjectRoot()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env", isDirectory: false)
        process.arguments = ["swift", "run", "whisp"] + arguments
        process.currentDirectoryURL = projectRoot

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let tail = tailLines(output, maxLines: 50)
            throw AppError.io("benchmark command failed (exit: \(process.terminationStatus))\n\(tail)")
        }
        return output
    }

    nonisolated private static func tailLines(_ text: String, maxLines: Int) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else {
            return ""
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    nonisolated private static func resolveProjectRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent()
        while true {
            let packageFile = directory.appendingPathComponent("Package.swift", isDirectory: false)
            if FileManager.default.fileExists(atPath: packageFile.path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }
        throw AppError.io("Package.swift not found from source path")
    }

    nonisolated private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
