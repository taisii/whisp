import Foundation
import AVFAudio
import AppKit
import CryptoKit
import WhispCore

enum BenchmarkDashboardTab: String, CaseIterable, Identifiable {
    case stt = "STT"
    case generation = "Generation"
    case candidateManagement = "候補管理"
    case integrity = "Case Integrity"

    var id: String { rawValue }

    var benchmarkTask: BenchmarkKind {
        switch self {
        case .stt, .integrity:
            return .stt
        case .generation, .candidateManagement:
            return .generation
        }
    }

    var flow: BenchmarkFlow? {
        switch self {
        case .stt:
            return .stt
        case .generation:
            return .generation
        case .candidateManagement:
            return nil
        case .integrity:
            return nil
        }
    }
}

struct BenchmarkCandidateManagementRow: Identifiable, Equatable {
    let candidate: BenchmarkCandidate
    let wins: Int
    let losses: Int
    let ties: Int
    let winRate: Double?

    var id: String { candidate.id }
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

struct BenchmarkPairwiseCaseRow: Identifiable, Equatable {
    let id: String
    let status: BenchmarkCaseStatus
    let overallWinner: PairwiseWinner?
    let intentWinner: PairwiseWinner?
    let hallucinationWinner: PairwiseWinner?
    let styleContextWinner: PairwiseWinner?
}

struct BenchmarkPairwiseCaseDetail: Equatable {
    let caseID: String
    let status: BenchmarkCaseStatus
    let overallWinner: PairwiseWinner?
    let intentWinner: PairwiseWinner?
    let hallucinationWinner: PairwiseWinner?
    let styleContextWinner: PairwiseWinner?
    let sttText: String
    let overallReason: String?
    let intentReason: String?
    let hallucinationReason: String?
    let styleContextReason: String?
    let outputA: String
    let outputB: String
    let promptA: String
    let promptB: String
    let promptPairwiseRound1: String
    let promptPairwiseRound2: String
    let judgeResponseRound1: String
    let judgeResponseRound2: String
    let judgeDecisionJSON: String
    let judgeError: String?
    let judgeInputImagePath: String?
    let judgeInputImageMissingReason: String?
}

private struct PairwiseJudgeInputMeta: Decodable {
    let visionImagePath: String?
    let imageMissing: Bool?
    let imageMissingReason: String?

    enum CodingKeys: String, CodingKey {
        case visionImagePath = "vision_image_path"
        case imageMissing = "image_missing"
        case imageMissingReason = "image_missing_reason"
    }
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
    let sttPreview: String
    let referencePreview: String
    let status: BenchmarkIntegrityStatusBadge
    let issueCount: Int
    let activeIssueCount: Int

    var isMissingInDataset: Bool { status == .datasetMissing }
}

struct BenchmarkIntegrityIssueDetailItem: Identifiable, Equatable {
    let id: String
    let taskLabel: String
    let title: String
    let missingFields: [String]
    let excluded: Bool
}

enum BenchmarkIntegrityStatusBadge: Equatable {
    case ok
    case issue
    case excluded
    case datasetMissing
}

struct BenchmarkIntegrityCaseDetail: Identifiable, Equatable {
    let id: String
    let audioFilePath: String?
    let visionImageFilePath: String?
    let visionImageMimeType: String?
    let sttText: String
    let groundTruthText: String
    let outputText: String
    let status: BenchmarkIntegrityStatusBadge
    let issueDetails: [BenchmarkIntegrityIssueDetailItem]
}

enum PromptCandidateModalMode {
    case create
    case edit
}

enum CandidateDetailModalMode {
    case view
    case edit
    case create
}

struct PromptVariableItem: Identifiable, Equatable {
    let id: String
    let token: String
    let description: String
    let sample: String
}

@MainActor
final class BenchmarkViewModel: ObservableObject {
    @Published var selectedTab: BenchmarkDashboardTab = .stt {
        didSet {
            synchronizeSelectionForCurrentTab()
        }
    }
    @Published var selectedTask: BenchmarkKind = .stt {
        didSet { handleTaskChanged() }
    }
    @Published var forceRerun = false
    @Published var compareWorkers: Int?

    @Published var candidates: [BenchmarkCandidate] = []
    @Published var selectedCandidateIDs: Set<String> = []
    @Published var comparisonRows: [BenchmarkComparisonRow] = []
    @Published var selectedComparisonCandidateID: String?
    @Published var caseBreakdownRows: [BenchmarkCaseBreakdownRow] = []
    @Published var generationPairCandidateAID: String?
    @Published var generationPairCandidateBID: String?
    @Published var generationPairJudgeModel: LLMModel = LLMModelCatalog.defaultModel(for: .benchmarkJudge)
    @Published var generationPairwiseRunID: String?
    @Published var generationPairwiseSummary: PairwiseRunSummary?
    @Published var generationPairwiseCaseRows: [BenchmarkPairwiseCaseRow] = []
    @Published var selectedGenerationPairwiseCaseID: String?
    @Published var generationPairwiseCaseDetail: BenchmarkPairwiseCaseDetail?
    @Published var isCaseDetailPresented = false
    @Published var isPairwiseCaseDetailPresented = false
    @Published var selectedCaseDetail: BenchmarkCaseDetail?
    @Published var isCaseAudioPlaying = false

    @Published var integrityIssues: [BenchmarkIntegrityIssue] = []
    @Published var integrityCaseRows: [BenchmarkIntegrityCaseRow] = []
    @Published var selectedIntegrityCaseID: String?
    @Published var isIntegrityCaseDetailPresented = false
    @Published var selectedIntegrityCaseDetail: BenchmarkIntegrityCaseDetail?
    @Published var isIntegrityCaseEditing = false
    @Published var integrityCaseDraftSTTText = ""
    @Published var integrityCaseDraftGroundTruthText = ""
    @Published var isIntegrityCaseDeleteConfirmationPresented = false

    @Published var statusMessage = ""
    @Published var statusIsError = false
    @Published var benchmarkErrorLog = ""
    @Published var isExecutingBenchmark = false
    @Published var isPromptCandidateModalPresented = false
    @Published var promptCandidateModalMode: PromptCandidateModalMode = .create
    @Published var promptCandidateDraftCandidateID = ""
    @Published var promptCandidateDraftModel: LLMModel = LLMModelCatalog.defaultModel(for: .benchmarkPromptCandidate)
    @Published var promptCandidateDraftName = ""
    @Published var promptCandidateDraftTemplate = defaultPostProcessPromptTemplate
    @Published var promptCandidateDraftRequireContext = false
    @Published var promptCandidateDraftUseCache = true
    @Published var promptCandidateDraftValidationError = ""
    @Published var candidateManagementRows: [BenchmarkCandidateManagementRow] = []
    @Published var selectedCandidateManagementID: String?
    @Published var isCandidateDetailModalPresented = false
    @Published var candidateDetailModalMode: CandidateDetailModalMode = .view
    @Published var isCandidateDeleteConfirmationPresented = false

    private let store: BenchmarkStore
    private let candidateStore: BenchmarkCandidateStore
    private let integrityStore: BenchmarkIntegrityStore
    private let datasetStore: BenchmarkDatasetStore
    private let executionService: BenchmarkExecutionService
    private let benchmarkDatasetPath: String
    private let caseEventAnalyzer = BenchmarkCaseEventAnalyzer()
    private var caseAudioPlayer: AVAudioPlayer?
    private var caseAudioPollingTimer: Timer?
    private var integrityRecordsByCaseID: [String: BenchmarkDatasetCaseRecord] = [:]
    private var integrityAutoScanTask: Task<Void, Never>?
    private var hasInitializedSTTCandidateSelection = false
    private let defaultCompareWorkers = 2

    init(
        store: BenchmarkStore,
        candidateStore: BenchmarkCandidateStore = BenchmarkCandidateStore(),
        integrityStore: BenchmarkIntegrityStore = BenchmarkIntegrityStore(),
        datasetStore: BenchmarkDatasetStore = BenchmarkDatasetStore(),
        executionService: BenchmarkExecutionService = BenchmarkExecutionService(),
        datasetPathOverride: String? = nil
    ) {
        self.store = store
        self.candidateStore = candidateStore
        self.integrityStore = integrityStore
        self.datasetStore = datasetStore
        self.executionService = executionService
        benchmarkDatasetPath = Self.resolveDatasetPath(pathOverride: datasetPathOverride)
        synchronizeSelectionForCurrentTab()
    }

    var taskCandidates: [BenchmarkCandidate] {
        let filtered = candidates.filter { $0.task == selectedTask }
        if selectedTask != .stt {
            return filtered.sorted { $0.id < $1.id }
        }
        let availableModels = Set(STTPresetCatalog.settingsSpecs().map { $0.id.rawValue })
        return filtered
            .filter { availableModels.contains($0.model) }
            .sorted { $0.id < $1.id }
    }

    var generationCandidates: [BenchmarkCandidate] {
        candidates
            .filter { $0.task == .generation }
            .sorted { $0.id < $1.id }
    }

    var generationPairCandidateA: BenchmarkCandidate? {
        guard let generationPairCandidateAID else { return nil }
        return generationCandidates.first(where: { $0.id == generationPairCandidateAID })
    }

    var generationPairCandidateB: BenchmarkCandidate? {
        guard let generationPairCandidateBID else { return nil }
        return generationCandidates.first(where: { $0.id == generationPairCandidateBID })
    }

    var selectedComparisonRow: BenchmarkComparisonRow? {
        guard let selectedComparisonCandidateID else { return nil }
        return comparisonRows.first { $0.candidate.id == selectedComparisonCandidateID }
    }

    var selectedIntegrityCaseRow: BenchmarkIntegrityCaseRow? {
        guard let selectedIntegrityCaseID else { return nil }
        return integrityCaseRows.first { $0.id == selectedIntegrityCaseID }
    }

    var selectedIntegrityCaseIssues: [BenchmarkIntegrityIssue] {
        guard let selectedIntegrityCaseID else { return [] }
        return integrityIssues.filter { $0.caseID == selectedIntegrityCaseID }
    }

    var hasBenchmarkErrorLog: Bool {
        !normalizedErrorLog(benchmarkErrorLog).isEmpty
    }

    var benchmarkErrorHeadline: String {
        compactHeadline(for: normalizedErrorLog(benchmarkErrorLog))
    }

    var canOpenPromptCandidateModal: Bool {
        selectedTask == .generation
    }

    var isPromptCandidateEditing: Bool {
        promptCandidateModalMode == .edit
    }

    var promptVariableItems: [PromptVariableItem] {
        Self.generationPromptVariables
    }

    var isCandidateDetailEditable: Bool {
        candidateDetailModalMode == .edit || candidateDetailModalMode == .create
    }

    var canDeleteCandidateInDetail: Bool {
        candidateDetailModalMode == .view || candidateDetailModalMode == .edit
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
        let dataset = benchmarkDatasetPath
        let force = forceRerun
        let candidateIDs: [String]
        let judgeModel: LLMModel?
        guard selectedTask == .stt else {
            runGenerationCompare()
            return
        }
        candidateIDs = taskCandidates.map(\.id).filter { selectedCandidateIDs.contains($0) }
        guard !candidateIDs.isEmpty else {
            setStatus("Candidateを1件以上選択してください。", isError: true)
            return
        }
        judgeModel = nil
        isExecutingBenchmark = true
        setStatus("比較実行を開始しました。", isError: false, clearErrorLog: true)

        Task {
            defer { isExecutingBenchmark = false }
            do {
                try await executionService.runCompare(request: BenchmarkExecutionRequest(
                    flow: .stt,
                    datasetPath: dataset,
                    candidateIDs: candidateIDs,
                    judgeModel: judgeModel?.rawValue,
                    force: force,
                    compareWorkers: resolvedCompareWorkers()
                ))
                try reloadAll()
                setStatus("比較実行が完了しました。", isError: false, clearErrorLog: true)
                benchmarkErrorLog = ""
            } catch {
                let log = normalizedErrorLog(error.localizedDescription)
                setStatus("比較実行に失敗: \(compactHeadline(for: log))", isError: true, errorLog: log)
            }
        }
    }

    func runGenerationCompare() {
        guard !isExecutingBenchmark else { return }
        guard selectedTask == .generation else {
            setStatus("Generation 比較は generation タブから実行してください。", isError: true)
            return
        }
        let dataset = benchmarkDatasetPath
        let force = forceRerun
        let candidateIDs: [String]
        let judgeModel: LLMModel?
        guard let candidateAID = generationPairCandidateAID,
              let candidateBID = generationPairCandidateBID,
              !candidateAID.isEmpty,
              !candidateBID.isEmpty
        else {
            setStatus("Generation 比較は candidate A/B を選択してください。", isError: true)
            return
        }
        guard candidateAID != candidateBID else {
            setStatus("candidate A/B は異なる候補を選択してください。", isError: true)
            return
        }
        candidateIDs = [candidateAID, candidateBID]
        judgeModel = generationPairJudgeModel

        isExecutingBenchmark = true
        setStatus("比較実行を開始しました。", isError: false, clearErrorLog: true)

        Task {
            defer { isExecutingBenchmark = false }
            do {
                try await executionService.runCompare(request: BenchmarkExecutionRequest(
                    flow: .generation,
                    datasetPath: dataset,
                    candidateIDs: candidateIDs,
                    judgeModel: judgeModel?.rawValue,
                    force: force,
                    compareWorkers: resolvedCompareWorkers()
                ))
                try reloadAll()
                setStatus("比較実行が完了しました。", isError: false, clearErrorLog: true)
                benchmarkErrorLog = ""
            } catch {
                let log = normalizedErrorLog(error.localizedDescription)
                setStatus("比較実行に失敗: \(compactHeadline(for: log))", isError: true, errorLog: log)
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

    func setGenerationPairCandidateA(_ candidateID: String) {
        generationPairCandidateAID = candidateID
        if generationPairCandidateBID == candidateID {
            generationPairCandidateBID = generationCandidates.first(where: { $0.id != candidateID })?.id
        }
        clearPairwiseCaseDetail()
        try? reloadGenerationPairwiseState()
    }

    func setGenerationPairCandidateB(_ candidateID: String) {
        generationPairCandidateBID = candidateID
        if generationPairCandidateAID == candidateID {
            generationPairCandidateAID = generationCandidates.first(where: { $0.id != candidateID })?.id
        }
        clearPairwiseCaseDetail()
        try? reloadGenerationPairwiseState()
    }

    func setGenerationPairJudgeModel(_ model: LLMModel) {
        generationPairJudgeModel = LLMModelCatalog.resolveOrFallback(model, for: .benchmarkJudge)
        clearPairwiseCaseDetail()
        try? reloadGenerationPairwiseState()
    }

    func selectGenerationPairwiseCase(_ caseID: String?) {
        selectedGenerationPairwiseCaseID = caseID
        selectedCaseDetail = nil
        isCaseDetailPresented = false
        if caseID == nil {
            clearPairwiseCaseDetail()
            return
        }
        loadGenerationPairwiseCaseDetail()
        isPairwiseCaseDetailPresented = selectedGenerationPairwiseCaseID != nil
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
        clearPairwiseCaseDetail()
    }

    func dismissPairwiseCaseDetail() {
        clearPairwiseCaseDetail()
    }

    func dismissIntegrityCaseDetail() {
        clearIntegrityCaseDetail()
    }

    func toggleCaseAudioPlayback() {
        if isCaseAudioPlaying {
            stopCaseAudioPlayback(showMessage: false)
            return
        }
        playCaseAudio()
    }

    func selectIntegrityCase(_ caseID: String?) {
        selectedIntegrityCaseID = caseID
    }

    func openIntegrityCaseDetail(caseID: String) {
        selectIntegrityCase(caseID)
        guard let detail = buildIntegrityCaseDetail(caseID: caseID) else {
            setStatus("ケース詳細の読み込み対象が見つかりません。", isError: true)
            return
        }
        selectedIntegrityCaseDetail = detail
        integrityCaseDraftSTTText = detail.sttText
        integrityCaseDraftGroundTruthText = detail.groundTruthText
        isIntegrityCaseEditing = false
        isIntegrityCaseDeleteConfirmationPresented = false
        isIntegrityCaseDetailPresented = true
    }

    func beginIntegrityCaseEditing() {
        guard let detail = selectedIntegrityCaseDetail else { return }
        integrityCaseDraftSTTText = detail.sttText
        integrityCaseDraftGroundTruthText = detail.groundTruthText
        isIntegrityCaseEditing = true
    }

    func cancelIntegrityCaseEditing() {
        guard let detail = selectedIntegrityCaseDetail else {
            isIntegrityCaseEditing = false
            return
        }
        integrityCaseDraftSTTText = detail.sttText
        integrityCaseDraftGroundTruthText = detail.groundTruthText
        isIntegrityCaseEditing = false
    }

    func saveIntegrityCaseEdits() {
        guard let detail = selectedIntegrityCaseDetail else {
            setStatus("保存対象のケースが選択されていません。", isError: true)
            return
        }
        let targetCaseID = detail.id
        do {
            var records = try loadAllIntegrityDatasetCaseRecords(path: benchmarkDatasetPath)
            var updated = false
            for index in records.indices where records[index].id == targetCaseID {
                records[index].sttText = integrityCaseDraftSTTText
                records[index].groundTruthText = integrityCaseDraftGroundTruthText
                updated = true
            }
            guard updated else {
                throw AppError.invalidArgument("編集対象の case_id がJSONLに見つかりません: \(targetCaseID)")
            }
            try saveIntegrityDatasetCaseRecords(path: benchmarkDatasetPath, records: records)
            isIntegrityCaseEditing = false
            runIntegrityScanAfterMutation(successPrefix: "ケースを更新しました。")
            if let refreshed = buildIntegrityCaseDetail(caseID: targetCaseID) {
                selectedIntegrityCaseDetail = refreshed
                integrityCaseDraftSTTText = refreshed.sttText
                integrityCaseDraftGroundTruthText = refreshed.groundTruthText
            }
        } catch {
            setStatus("ケース更新に失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    func requestIntegrityCaseDelete() {
        guard selectedIntegrityCaseDetail != nil else {
            setStatus("削除対象のケースが選択されていません。", isError: true)
            return
        }
        isIntegrityCaseDeleteConfirmationPresented = true
    }

    func cancelIntegrityCaseDelete() {
        isIntegrityCaseDeleteConfirmationPresented = false
    }

    func confirmIntegrityCaseDelete() {
        guard let detail = selectedIntegrityCaseDetail else {
            setStatus("削除対象のケースが選択されていません。", isError: true)
            return
        }
        let targetCaseID = detail.id
        do {
            let records = try loadAllIntegrityDatasetCaseRecords(path: benchmarkDatasetPath)
            let filtered = records.filter { $0.id != targetCaseID }
            guard filtered.count != records.count else {
                throw AppError.invalidArgument("削除対象の case_id がJSONLに見つかりません: \(targetCaseID)")
            }
            try saveIntegrityDatasetCaseRecords(path: benchmarkDatasetPath, records: filtered)
            clearIntegrityCaseDetail()
            runIntegrityScanAfterMutation(successPrefix: "ケースを削除しました。")
        } catch {
            setStatus("ケース削除に失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    func copyIntegrityCaseID(_ caseID: String) {
        let trimmed = caseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setStatus("case_id を選択してください。", isError: true)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        setStatus("case_id をコピーしました。", isError: false)
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

    func openCreatePromptCandidateModal() {
        guard selectedTask == .generation else { return }
        let baseCandidate = generationPairCandidateA
        let defaultModel = resolveDefaultPromptCandidateModel(baseCandidate: baseCandidate)
        let candidateID = makeAutoPromptCandidateID(model: defaultModel)
        presentPromptCandidateModal(
            mode: .create,
            candidateID: candidateID,
            model: defaultModel,
            promptName: baseCandidate?.promptName ?? "New Prompt",
            promptTemplate: baseCandidate?.generationPromptTemplate,
            options: baseCandidate?.options
        )
    }

    func openCreateCandidateDetailModal() {
        let baseCandidate = generationPairCandidateA
        let defaultModel = resolveDefaultPromptCandidateModel(baseCandidate: baseCandidate)
        let candidateID = makeAutoPromptCandidateID(model: defaultModel)
        candidateDetailModalMode = .create
        isCandidateDeleteConfirmationPresented = false
        presentCandidateDraft(
            candidateID: candidateID,
            model: defaultModel,
            promptName: baseCandidate?.promptName ?? "New Prompt",
            promptTemplate: baseCandidate?.generationPromptTemplate,
            options: baseCandidate?.options
        )
        selectedCandidateManagementID = candidateID
        isCandidateDetailModalPresented = true
    }

    func openCandidateDetailModal(candidateID: String) {
        guard let candidate = generationCandidates.first(where: { $0.id == candidateID }) else {
            setStatus("候補が見つかりません。", isError: true)
            return
        }
        guard let parsedModel = LLMModelCatalog.resolveRegistered(rawValue: candidate.model) else {
            setStatus("candidate model が不正です: \(candidate.model)", isError: true)
            return
        }
        candidateDetailModalMode = .view
        isCandidateDeleteConfirmationPresented = false
        selectedCandidateManagementID = candidate.id
        presentCandidateDraft(
            candidateID: candidate.id,
            model: parsedModel,
            promptName: candidate.promptName ?? candidate.id,
            promptTemplate: candidate.generationPromptTemplate,
            options: candidate.options
        )
        isCandidateDetailModalPresented = true
    }

    func beginCandidateDetailEditing() {
        guard candidateDetailModalMode == .view else { return }
        candidateDetailModalMode = .edit
    }

    func cancelCandidateDetailEditing() {
        if candidateDetailModalMode == .create {
            dismissCandidateDetailModal()
            return
        }
        guard let selectedCandidateManagementID,
              let candidate = generationCandidates.first(where: { $0.id == selectedCandidateManagementID }),
              let parsedModel = LLMModelCatalog.resolveRegistered(rawValue: candidate.model)
        else {
            dismissCandidateDetailModal()
            return
        }
        candidateDetailModalMode = .view
        presentCandidateDraft(
            candidateID: candidate.id,
            model: parsedModel,
            promptName: candidate.promptName ?? candidate.id,
            promptTemplate: candidate.generationPromptTemplate,
            options: candidate.options
        )
    }

    func dismissCandidateDetailModal() {
        isCandidateDetailModalPresented = false
        isCandidateDeleteConfirmationPresented = false
        promptCandidateDraftValidationError = ""
    }

    func requestCandidateDeleteConfirmation() {
        guard canDeleteCandidateInDetail else { return }
        isCandidateDeleteConfirmationPresented = true
    }

    func deleteCandidateFromDetail() {
        guard let selectedCandidateManagementID else {
            setStatus("削除対象が見つかりません。", isError: true)
            return
        }
        do {
            try candidateStore.deleteCandidate(id: selectedCandidateManagementID)
            selectedCandidateIDs.remove(selectedCandidateManagementID)
            if generationPairCandidateAID == selectedCandidateManagementID {
                generationPairCandidateAID = nil
            }
            if generationPairCandidateBID == selectedCandidateManagementID {
                generationPairCandidateBID = nil
            }
            if selectedComparisonCandidateID == selectedCandidateManagementID {
                selectedComparisonCandidateID = nil
            }
            dismissCandidateDetailModal()
            try reloadAll()
            setStatus("候補を削除しました。", isError: false, clearErrorLog: true)
        } catch {
            setStatus("候補削除に失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    func openEditPromptCandidateModal(candidateID: String? = nil) {
        guard selectedTask == .generation else { return }
        let targetID = candidateID ?? generationPairCandidateAID
        guard let targetID,
              let candidate = generationCandidates.first(where: { $0.id == targetID })
        else {
            setStatus("編集対象のGeneration candidateを選択してください。", isError: true)
            return
        }

        guard let parsedModel = LLMModelCatalog.resolveRegistered(rawValue: candidate.model) else {
            setStatus("candidate model が不正です: \(candidate.model)", isError: true)
            return
        }
        presentPromptCandidateModal(
            mode: .edit,
            candidateID: candidate.id,
            model: parsedModel,
            promptName: candidate.promptName ?? candidate.id,
            promptTemplate: candidate.generationPromptTemplate,
            options: candidate.options
        )
    }

    func dismissPromptCandidateModal() {
        isPromptCandidateModalPresented = false
        promptCandidateDraftValidationError = ""
    }

    func appendPromptVariableToDraft(_ token: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return }
        var template = promptCandidateDraftTemplate
        if !template.isEmpty, !template.hasSuffix("\n") {
            template += "\n"
        }
        template += trimmedToken
        promptCandidateDraftTemplate = template
    }

    func savePromptCandidateModal() {
        saveGenerationCandidate(mode: promptCandidateModalMode) { saved in
            isPromptCandidateModalPresented = false
            applySavedCandidateSelection(saved)
            setStatus("Prompt candidate を保存しました。", isError: false, clearErrorLog: true)
        }
    }

    func saveCandidateDetailModal() {
        let mode: PromptCandidateModalMode
        switch candidateDetailModalMode {
        case .create:
            mode = .create
        case .edit:
            mode = .edit
        case .view:
            return
        }
        saveGenerationCandidate(mode: mode) { saved in
            selectedCandidateManagementID = saved.id
            applySavedCandidateSelection(saved)
            candidateDetailModalMode = .view
            isCandidateDeleteConfirmationPresented = false
            setStatus("候補を保存しました。", isError: false, clearErrorLog: true)
        }
    }

    private func applySavedCandidateSelection(_ saved: BenchmarkCandidate) {
        selectedTask = .generation
        selectedCandidateIDs.insert(saved.id)
        selectedComparisonCandidateID = saved.id
        if generationPairCandidateAID == nil {
            generationPairCandidateAID = saved.id
        } else if generationPairCandidateBID == nil, generationPairCandidateAID != saved.id {
            generationPairCandidateBID = saved.id
        }
        try? reloadGenerationPairwiseState()
    }

    private func saveGenerationCandidate(
        mode: PromptCandidateModalMode,
        onSuccess: (BenchmarkCandidate) -> Void
    ) {
        let candidateID = promptCandidateDraftCandidateID.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptName = promptCandidateDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptTemplate = canonicalPromptTemplate(promptCandidateDraftTemplate)
        guard !candidateID.isEmpty else {
            promptCandidateDraftValidationError = "candidate_id が不正です。"
            return
        }
        guard !promptName.isEmpty else {
            promptCandidateDraftValidationError = "prompt_name を入力してください。"
            return
        }
        guard !promptTemplate.isEmpty else {
            promptCandidateDraftValidationError = "prompt_template は空にできません。"
            return
        }
        do {
            let all = try candidateStore.listCandidates()
            let existing = all.first { $0.id == candidateID }
            if mode == .create, existing != nil {
                promptCandidateDraftValidationError = "candidate_id が重複しています: \(candidateID)"
                return
            }
            if mode == .edit, existing == nil {
                promptCandidateDraftValidationError = "編集対象candidateが見つかりません。"
                return
            }

            let now = WhispTime.isoNow()
            var options = existing?.options ?? [:]
            options["require_context"] = promptCandidateDraftRequireContext ? "true" : "false"
            options["use_cache"] = promptCandidateDraftUseCache ? "true" : "false"

            let saved = BenchmarkCandidate(
                id: candidateID,
                task: .generation,
                model: promptCandidateDraftModel.rawValue,
                promptName: promptName,
                generationPromptTemplate: promptTemplate,
                generationPromptHash: promptTemplateHash(promptTemplate),
                options: options,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            _ = try candidateStore.upsertCandidate(saved)
            try reloadAll()
            promptCandidateDraftValidationError = ""
            onSuccess(saved)
        } catch {
            promptCandidateDraftValidationError = error.localizedDescription
            setStatus("候補保存に失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
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
        clearPairwiseCaseDetail()
        clearIntegrityCaseDetail()
        dismissCandidateDetailModal()
        do {
            try loadComparisonRows()
            try reloadGenerationPairwiseState()
            try loadCandidateManagementRows()
            try refreshIntegrityCases(performAutoScan: selectedTab == .integrity)
        } catch {
            setStatus("タスク切り替えに失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    private func reloadAll() throws {
        try BenchmarkCandidateDefaults.ensureSeededAndNormalized(store: candidateStore)
        candidates = try candidateStore.listCandidates()
        synchronizeSelectionForCurrentTab()
        let valid = Set(taskCandidates.map(\.id))
        selectedCandidateIDs = selectedCandidateIDs.intersection(valid)
        if selectedTask == .stt,
           !hasInitializedSTTCandidateSelection,
           selectedCandidateIDs.isEmpty,
           !taskCandidates.isEmpty
        {
            selectedCandidateIDs = Set(taskCandidates.prefix(3).map(\.id))
            hasInitializedSTTCandidateSelection = true
        }
        try loadComparisonRows()
        try reloadGenerationPairwiseState()
        try loadCandidateManagementRows()
        try refreshIntegrityCases(performAutoScan: selectedTab == .integrity)
    }

    func synchronizeSelectionForCurrentTab() {
        if selectedTab != .integrity {
            integrityAutoScanTask?.cancel()
            integrityAutoScanTask = nil
        }

        switch selectedTab {
        case .stt:
            clearIntegrityCaseDetail()
            selectedTask = .stt
        case .generation:
            clearIntegrityCaseDetail()
            selectedTask = .generation
        case .candidateManagement:
            clearIntegrityCaseDetail()
            selectedTask = .generation
        case .integrity:
            if selectedTask == .vision {
                selectedTask = .stt
            }
            do {
                try refreshIntegrityCases(performAutoScan: false)
                scheduleIntegrityAutoScanInBackground()
            } catch {
                setStatus("Case Integrityの読み込みに失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
            }
        }
    }

    private func scheduleIntegrityAutoScanInBackground() {
        integrityAutoScanTask?.cancel()
        let datasetPath = benchmarkDatasetPath
        let store = integrityStore

        integrityAutoScanTask = Task { [weak self] in
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try Self.runAutoIntegrityScanIfNeeded(datasetPath: datasetPath, integrityStore: store)
                }.value
                guard !Task.isCancelled else { return }
                guard let self else { return }
                try self.refreshIntegrityCases(performAutoScan: false)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.setStatus("Case Integrityの自動再計算に失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
            }
        }
    }

    private func loadComparisonRows() throws {
        let allRuns = try store.listRuns(limit: 2_000)
        let normalizedDatasetPath = normalizePath(benchmarkDatasetPath)
        let currentDatasetHash = datasetHashIfExists(path: normalizedDatasetPath)

        comparisonRows = taskCandidates.map { candidate in
            let runsForCandidate = allRuns.filter { run in
                guard run.kind == selectedTask else { return false }
                let runCandidateID = (run.candidateID?.isEmpty == false ? run.candidateID : nil) ?? run.options.candidateID
                guard runCandidateID == candidate.id else { return false }
                return normalizePath(run.options.sourceCasesPath) == normalizedDatasetPath
            }
            let sorted = runsForCandidate.sorted { $0.updatedAt > $1.updatedAt }
            let latest = sorted.first
            let latestMetrics = latest?.metrics
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
                executedCases: latestMetrics?.executedCases ?? 0,
                skipCases: latestMetrics?.skippedCases ?? 0,
                avgCER: latestMetrics?.avgCER,
                weightedCER: latestMetrics?.weightedCER,
                sttAfterStopP50: latestMetrics?.afterStopLatencyMs?.p50,
                sttAfterStopP95: latestMetrics?.afterStopLatencyMs?.p95,
                postMsP95: latestMetrics?.postLatencyMs?.p95,
                intentPreservationScore: latestMetrics?.intentPreservationScore,
                hallucinationRate: latestMetrics?.hallucinationRate,
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

    private func loadCandidateManagementRows() throws {
        let generation = generationCandidates
        guard !generation.isEmpty else {
            candidateManagementRows = []
            selectedCandidateManagementID = nil
            return
        }

        struct CandidateWinStats {
            var wins = 0
            var losses = 0
            var ties = 0
        }

        var statsMap: [String: CandidateWinStats] = [:]
        let runs = try store.listRuns(limit: 5_000)
        let pairwiseRuns = runs.filter {
            $0.kind == .generation &&
            $0.status == .completed &&
            $0.options.compareMode == .pairwise
        }

        for run in pairwiseRuns {
            guard let candidateAID = run.options.pairCandidateAID,
                  let candidateBID = run.options.pairCandidateBID,
                  let summary = run.metrics.pairwiseSummary
            else {
                continue
            }
            var aStats = statsMap[candidateAID] ?? CandidateWinStats()
            aStats.wins += summary.overallAWins
            aStats.losses += summary.overallBWins
            aStats.ties += summary.overallTies
            statsMap[candidateAID] = aStats

            var bStats = statsMap[candidateBID] ?? CandidateWinStats()
            bStats.wins += summary.overallBWins
            bStats.losses += summary.overallAWins
            bStats.ties += summary.overallTies
            statsMap[candidateBID] = bStats
        }

        candidateManagementRows = generation.map { candidate in
            let stats = statsMap[candidate.id] ?? CandidateWinStats()
            let total = stats.wins + stats.losses + stats.ties
            let winRate = total > 0 ? Double(stats.wins) / Double(total) : nil
            return BenchmarkCandidateManagementRow(
                candidate: candidate,
                wins: stats.wins,
                losses: stats.losses,
                ties: stats.ties,
                winRate: winRate
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.winRate, rhs.winRate) {
            case let (.some(left), .some(right)):
                if left != right { return left > right }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            if lhs.wins != rhs.wins {
                return lhs.wins > rhs.wins
            }
            if lhs.candidate.updatedAt != rhs.candidate.updatedAt {
                return lhs.candidate.updatedAt > rhs.candidate.updatedAt
            }
            return lhs.candidate.id < rhs.candidate.id
        }

        if let selectedCandidateManagementID,
           candidateManagementRows.contains(where: { $0.id == selectedCandidateManagementID })
        {
            return
        }
        selectedCandidateManagementID = candidateManagementRows.first?.id
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

    private func reloadGenerationPairwiseState() throws {
        generationPairJudgeModel = LLMModelCatalog.resolveOrFallback(generationPairJudgeModel, for: .benchmarkJudge)
        guard selectedTask == .generation else {
            generationPairwiseRunID = nil
            generationPairwiseSummary = nil
            generationPairwiseCaseRows = []
            selectedGenerationPairwiseCaseID = nil
            clearPairwiseCaseDetail()
            return
        }

        let generationIDs = Set(generationCandidates.map(\.id))
        if let candidateAID = generationPairCandidateAID, !generationIDs.contains(candidateAID) {
            generationPairCandidateAID = nil
        }
        if let candidateBID = generationPairCandidateBID, !generationIDs.contains(candidateBID) {
            generationPairCandidateBID = nil
        }
        if generationPairCandidateAID == nil {
            generationPairCandidateAID = generationCandidates.first?.id
        }
        if generationPairCandidateBID == nil || generationPairCandidateBID == generationPairCandidateAID {
            generationPairCandidateBID = generationCandidates.first(where: { $0.id != generationPairCandidateAID })?.id
        }

        guard let candidateAID = generationPairCandidateAID,
              let candidateBID = generationPairCandidateBID
        else {
            generationPairwiseRunID = nil
            generationPairwiseSummary = nil
            generationPairwiseCaseRows = []
            selectedGenerationPairwiseCaseID = nil
            clearPairwiseCaseDetail()
            return
        }

        let selectedCanonicalPair = BenchmarkPairwiseNormalizer.canonicalize(candidateAID, candidateBID)
        let normalizedDatasetPath = normalizePath(benchmarkDatasetPath)
        let runs = try store.listRuns(limit: 2_000)
        let matching = runs.filter { run in
            guard run.kind == .generation else { return false }
            guard run.status == .completed else { return false }
            guard run.options.compareMode == .pairwise else { return false }
            guard normalizePath(run.options.sourceCasesPath) == normalizedDatasetPath else { return false }
            guard run.options.pairJudgeModel == generationPairJudgeModel.rawValue else { return false }
            if let canonical = run.options.pairCanonicalID {
                return canonical == selectedCanonicalPair
            }
            return BenchmarkPairwiseNormalizer.canonicalize(
                run.options.pairCandidateAID ?? "",
                run.options.pairCandidateBID ?? ""
            ) == selectedCanonicalPair
        }
        let latest = matching.sorted { $0.updatedAt > $1.updatedAt }.first
        generationPairwiseRunID = latest?.id
        generationPairwiseSummary = latest?.metrics.pairwiseSummary

        guard let runID = latest?.id else {
            generationPairwiseCaseRows = []
            selectedGenerationPairwiseCaseID = nil
            clearPairwiseCaseDetail()
            return
        }

        let results = try store.loadCaseResults(runID: runID)
        generationPairwiseCaseRows = results.map { result in
            BenchmarkPairwiseCaseRow(
                id: result.id,
                status: result.status,
                overallWinner: result.metrics.pairwise?.overallWinner,
                intentWinner: result.metrics.pairwise?.intentWinner,
                hallucinationWinner: result.metrics.pairwise?.hallucinationWinner,
                styleContextWinner: result.metrics.pairwise?.styleContextWinner
            )
        }
        .sorted { lhs, rhs in
            if lhs.status != rhs.status {
                let rank: [BenchmarkCaseStatus: Int] = [.error: 0, .skipped: 1, .ok: 2]
                return rank[lhs.status, default: 3] < rank[rhs.status, default: 3]
            }
            return lhs.id < rhs.id
        }

        if let selected = selectedGenerationPairwiseCaseID,
           generationPairwiseCaseRows.contains(where: { $0.id == selected })
        {
            loadGenerationPairwiseCaseDetail()
        } else {
            selectedGenerationPairwiseCaseID = generationPairwiseCaseRows.first?.id
            loadGenerationPairwiseCaseDetail()
        }
    }

    private func loadGenerationPairwiseCaseDetail() {
        guard let runID = generationPairwiseRunID,
              let caseID = selectedGenerationPairwiseCaseID
        else {
            generationPairwiseCaseDetail = nil
            isPairwiseCaseDetailPresented = false
            return
        }
        do {
            let results = try store.loadCaseResults(runID: runID)
            guard let result = results.first(where: { $0.id == caseID }) else {
                generationPairwiseCaseDetail = nil
                isPairwiseCaseDetailPresented = false
                return
            }
            let pairwise = result.metrics.pairwise
            let judgeInputMeta = readPairwiseJudgeInputMeta(runID: runID, caseID: caseID)
            generationPairwiseCaseDetail = BenchmarkPairwiseCaseDetail(
                caseID: caseID,
                status: result.status,
                overallWinner: pairwise?.overallWinner,
                intentWinner: pairwise?.intentWinner,
                hallucinationWinner: pairwise?.hallucinationWinner,
                styleContextWinner: pairwise?.styleContextWinner,
                sttText: pairwiseCaseSTTText(
                    runID: runID,
                    caseID: caseID,
                    source: result.sources.input
                ),
                overallReason: pairwise?.overallReason,
                intentReason: pairwise?.intentReason,
                hallucinationReason: pairwise?.hallucinationReason,
                styleContextReason: pairwise?.styleContextReason,
                outputA: readCaseIOText(runID: runID, caseID: caseID, fileName: "output_generation_a.txt"),
                outputB: readCaseIOText(runID: runID, caseID: caseID, fileName: "output_generation_b.txt"),
                promptA: readCaseIOText(runID: runID, caseID: caseID, fileName: "prompt_generation_a.txt"),
                promptB: readCaseIOText(runID: runID, caseID: caseID, fileName: "prompt_generation_b.txt"),
                promptPairwiseRound1: readCaseIOText(runID: runID, caseID: caseID, fileName: "prompt_pairwise_round1.txt"),
                promptPairwiseRound2: readCaseIOText(runID: runID, caseID: caseID, fileName: "prompt_pairwise_round2.txt"),
                judgeResponseRound1: readCaseIOText(runID: runID, caseID: caseID, fileName: "pairwise_round1_response.json"),
                judgeResponseRound2: readCaseIOText(runID: runID, caseID: caseID, fileName: "pairwise_round2_response.json"),
                judgeDecisionJSON: readCaseIOText(runID: runID, caseID: caseID, fileName: "pairwise_decision.json"),
                judgeError: result.status == .error ? result.reason : nil,
                judgeInputImagePath: normalizedOptionalPath(judgeInputMeta?.visionImagePath),
                judgeInputImageMissingReason: pairwiseJudgeImageMissingReason(meta: judgeInputMeta)
            )
        } catch {
            generationPairwiseCaseDetail = nil
            isPairwiseCaseDetailPresented = false
            setStatus("pairwise ケース詳細の読み込みに失敗: \(error.localizedDescription)", isError: true, errorLog: error.localizedDescription)
        }
    }

    private func pairwiseCaseSTTText(runID: String, caseID: String, source: String?) -> String {
        let ioText = readCaseIOText(runID: runID, caseID: caseID, fileName: "input_stt.txt")
        if !ioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ioText
        }
        guard let source else { return "" }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSource.isEmpty || trimmedSource == "stt_text" {
            return ""
        }
        return trimmedSource
    }

    private func readCaseIOText(runID: String, caseID: String, fileName: String) -> String {
        let ioDirectory = store.resolveCasePaths(runID: runID, caseID: caseID).ioDirectoryPath
        let path = URL(fileURLWithPath: ioDirectory, isDirectory: true).appendingPathComponent(fileName, isDirectory: false).path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        return text
    }

    private func readPairwiseJudgeInputMeta(runID: String, caseID: String) -> PairwiseJudgeInputMeta? {
        let raw = readCaseIOText(runID: runID, caseID: caseID, fileName: "pairwise_judge_input_meta.json")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(PairwiseJudgeInputMeta.self, from: data)
    }

    private func pairwiseJudgeImageMissingReason(meta: PairwiseJudgeInputMeta?) -> String? {
        guard let meta, meta.imageMissing == true else {
            return nil
        }
        let trimmedReason = (meta.imageMissingReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReason.isEmpty {
            return trimmedReason
        }
        return "judge入力画像は見つかりませんでした"
    }

    private func normalizedOptionalPath(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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

    private func refreshIntegrityCases(performAutoScan: Bool) throws {
        if performAutoScan {
            _ = try runAutoIntegrityScanIfNeeded()
        }
        integrityIssues = try loadMergedIntegrityIssues()
        try loadIntegrityCaseRows()
    }

    private func loadMergedIntegrityIssues() throws -> [BenchmarkIntegrityIssue] {
        let merged = try integrityStore.loadIssues(task: .stt) + integrityStore.loadIssues(task: .generation)
        return merged.sorted {
            if $0.excluded != $1.excluded {
                return !$0.excluded && $1.excluded
            }
            if $0.caseID != $1.caseID {
                return $0.caseID < $1.caseID
            }
            if $0.task.rawValue != $1.task.rawValue {
                return $0.task.rawValue < $1.task.rawValue
            }
            return $0.issueType < $1.issueType
        }
    }

    private func loadIntegrityCaseRows() throws {
        let allRecords = try loadAllIntegrityDatasetCaseRecords(path: benchmarkDatasetPath)
        var latestRecordByCaseID: [String: BenchmarkDatasetCaseRecord] = [:]
        var caseOrder: [String] = []
        for record in allRecords {
            if latestRecordByCaseID[record.id] == nil {
                caseOrder.append(record.id)
            }
            latestRecordByCaseID[record.id] = record
        }
        integrityRecordsByCaseID = latestRecordByCaseID

        let issuesByCase = Dictionary(grouping: integrityIssues, by: \.caseID)
        let knownCaseIDs = Set(caseOrder)

        var rows: [BenchmarkIntegrityCaseRow] = caseOrder.compactMap { caseID in
            guard let item = latestRecordByCaseID[caseID] else {
                return nil
            }
            let caseIssues = issuesByCase[caseID] ?? []
            let activeIssueCount = caseIssues.filter { !$0.excluded }.count
            return BenchmarkIntegrityCaseRow(
                id: caseID,
                sttPreview: preview(item.sttText),
                referencePreview: preview(item.normalizedReferenceText()),
                status: integrityStatusBadge(
                    activeIssueCount: activeIssueCount,
                    issueCount: caseIssues.count,
                    missingInDataset: false
                ),
                issueCount: caseIssues.count,
                activeIssueCount: activeIssueCount
            )
        }

        for (caseID, caseIssues) in issuesByCase where !knownCaseIDs.contains(caseID) {
            let activeIssueCount = caseIssues.filter { !$0.excluded }.count
            rows.append(
                BenchmarkIntegrityCaseRow(
                    id: caseID,
                    sttPreview: "-",
                    referencePreview: "-",
                    status: integrityStatusBadge(
                        activeIssueCount: activeIssueCount,
                        issueCount: caseIssues.count,
                        missingInDataset: true
                    ),
                    issueCount: caseIssues.count,
                    activeIssueCount: activeIssueCount
                )
            )
        }

        integrityCaseRows = rows.sorted(by: integrityCaseSort)

        if let currentCaseID = selectedIntegrityCaseID,
           !integrityCaseRows.contains(where: { $0.id == currentCaseID })
        {
            selectedIntegrityCaseID = integrityCaseRows.first?.id
        } else if selectedIntegrityCaseID == nil {
            selectedIntegrityCaseID = integrityCaseRows.first?.id
        }

        refreshIntegrityCaseDetailAfterReload()
    }

    private func integrityStatusBadge(
        activeIssueCount: Int,
        issueCount: Int,
        missingInDataset: Bool
    ) -> BenchmarkIntegrityStatusBadge {
        if missingInDataset {
            return .datasetMissing
        }
        if activeIssueCount > 0 {
            return .issue
        }
        if issueCount > 0 {
            return .excluded
        }
        return .ok
    }

    private func integrityCaseSort(_ lhs: BenchmarkIntegrityCaseRow, _ rhs: BenchmarkIntegrityCaseRow) -> Bool {
        let rank: [BenchmarkIntegrityStatusBadge: Int] = [
            .issue: 0,
            .datasetMissing: 1,
            .excluded: 2,
            .ok: 3,
        ]
        let lhsRank = rank[lhs.status, default: 4]
        let rhsRank = rank[rhs.status, default: 4]
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.id < rhs.id
    }

    private func buildIntegrityCaseDetail(caseID: String) -> BenchmarkIntegrityCaseDetail? {
        guard let record = integrityRecordsByCaseID[caseID] else {
            return nil
        }
        let caseIssues = integrityIssues
            .filter { $0.caseID == caseID }
            .sorted(by: integrityIssueSort)
        let status = integrityCaseRows.first(where: { $0.id == caseID })?.status
            ?? integrityStatusBadge(
                activeIssueCount: caseIssues.filter { !$0.excluded }.count,
                issueCount: caseIssues.count,
                missingInDataset: false
            )
        let issueDetails = caseIssues.map { issue in
            BenchmarkIntegrityIssueDetailItem(
                id: issue.id,
                taskLabel: benchmarkKindLabel(issue.task),
                title: integrityIssueTitle(issue),
                missingFields: issue.missingFields,
                excluded: issue.excluded
            )
        }
        return BenchmarkIntegrityCaseDetail(
            id: caseID,
            audioFilePath: normalizedOptionalPath(record.audioFile),
            visionImageFilePath: normalizedOptionalPath(record.visionImageFile),
            visionImageMimeType: normalizedOptionalPath(record.visionImageMimeType),
            sttText: record.sttText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            groundTruthText: record.groundTruthText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            outputText: record.outputText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            status: status,
            issueDetails: issueDetails
        )
    }

    private func integrityIssueSort(_ lhs: BenchmarkIntegrityIssue, _ rhs: BenchmarkIntegrityIssue) -> Bool {
        if lhs.excluded != rhs.excluded {
            return !lhs.excluded && rhs.excluded
        }
        if lhs.task.rawValue != rhs.task.rawValue {
            return lhs.task.rawValue < rhs.task.rawValue
        }
        return lhs.issueType < rhs.issueType
    }

    private func integrityIssueTitle(_ issue: BenchmarkIntegrityIssue) -> String {
        switch issue.issueType {
        case "missing_reference":
            if issue.task == .stt {
                return "参照テキストが不足しています（STT）"
            }
            return "期待出力の参照テキストが不足しています"
        case "missing_audio_file":
            return "音声ファイルが見つかりません"
        case "missing_stt_text":
            return "STT入力テキストが不足しています"
        default:
            return issue.issueType
        }
    }

    private func refreshIntegrityCaseDetailAfterReload() {
        guard isIntegrityCaseDetailPresented else {
            return
        }
        let caseID = selectedIntegrityCaseDetail?.id ?? selectedIntegrityCaseID
        guard let caseID else {
            clearIntegrityCaseDetail()
            return
        }
        guard let detail = buildIntegrityCaseDetail(caseID: caseID) else {
            clearIntegrityCaseDetail()
            return
        }
        selectedIntegrityCaseDetail = detail
        if !isIntegrityCaseEditing {
            integrityCaseDraftSTTText = detail.sttText
            integrityCaseDraftGroundTruthText = detail.groundTruthText
        }
    }

    private func runIntegrityScanAfterMutation(successPrefix: String) {
        do {
            _ = try runAutoIntegrityScanIfNeeded()
            integrityIssues = try loadMergedIntegrityIssues()
            try loadIntegrityCaseRows()
            setStatus("\(successPrefix) 不備を再計算しました。", isError: false, clearErrorLog: true)
        } catch {
            setStatus(
                "\(successPrefix) 不備の再計算に失敗: \(error.localizedDescription)",
                isError: true,
                errorLog: error.localizedDescription
            )
        }
    }

    private func runAutoIntegrityScanIfNeeded() throws -> Int {
        try Self.runAutoIntegrityScanIfNeeded(datasetPath: benchmarkDatasetPath, integrityStore: integrityStore)
    }

    nonisolated private static func runAutoIntegrityScanIfNeeded(
        datasetPath: String,
        integrityStore: BenchmarkIntegrityStore
    ) throws -> Int {
        let sourcePath = normalizePathForStorage(datasetPath)
        let allRecords = try loadIntegrityDatasetCaseRecords(path: sourcePath)
        var latestCaseByID: [String: BenchmarkIntegrityScanCase] = [:]
        for record in allRecords {
            latestCaseByID[record.id] = BenchmarkIntegrityScanCase(
                id: record.id,
                audioFile: record.audioFile,
                sttText: record.sttText,
                groundTruthText: record.groundTruthText,
                transcriptGold: record.labels?.transcriptGold,
                transcriptSilver: record.labels?.transcriptSilver
            )
        }
        let currentCases = latestCaseByID.values.sorted { $0.id < $1.id }
        let currentFingerprintMap = Dictionary(
            uniqueKeysWithValues: currentCases.map { item in
                let fingerprint = BenchmarkIntegrityScanner.fingerprint(case: item)
                return (fingerprint.caseID, fingerprint.value)
            }
        )

        let previousState = try integrityStore.loadAutoScanState()
        let hasPreviousState = previousState != nil
        let sourceChanged = previousState?.sourcePath != sourcePath
        let previousMap = previousState?.fingerprintsByCaseID ?? [:]
        let shouldReplaceAllIssues = !hasPreviousState || sourceChanged

        var changedCaseIDs: Set<String> = []
        if shouldReplaceAllIssues {
            changedCaseIDs = Set(currentFingerprintMap.keys)
        } else {
            for (caseID, fingerprint) in currentFingerprintMap {
                if previousMap[caseID] != fingerprint {
                    changedCaseIDs.insert(caseID)
                }
            }
        }

        let removedCaseIDs = Set(previousMap.keys).subtracting(currentFingerprintMap.keys)
        if changedCaseIDs.isEmpty && removedCaseIDs.isEmpty && !shouldReplaceAllIssues {
            return 0
        }

        let detectedAt = WhispTime.isoNow()
        let changedCases = currentCases.filter { changedCaseIDs.contains($0.id) }
        let scannedIssues = BenchmarkIntegrityScanner.scanIssuesForDefaultTasks(
            cases: changedCases,
            sourcePath: sourcePath,
            detectedAt: detectedAt
        )

        for task in [BenchmarkKind.stt, BenchmarkKind.generation] {
            let existing = try integrityStore.loadIssues(task: task)
            let retained: [BenchmarkIntegrityIssue]
            if shouldReplaceAllIssues {
                retained = []
            } else {
                retained = existing.filter { issue in
                    !changedCaseIDs.contains(issue.caseID) && !removedCaseIDs.contains(issue.caseID)
                }
            }
            let recalculated = scannedIssues[task] ?? []
            try integrityStore.saveIssues(task: task, issues: retained + recalculated)
        }

        try integrityStore.saveAutoScanState(
            BenchmarkIntegrityAutoScanState(
                sourcePath: sourcePath,
                fingerprintsByCaseID: currentFingerprintMap,
                lastScannedAt: detectedAt
            )
        )
        return changedCaseIDs.count + removedCaseIDs.count
    }

    private func loadAllIntegrityDatasetCaseRecords(path: String) throws -> [BenchmarkDatasetCaseRecord] {
        try Self.loadIntegrityDatasetCaseRecords(path: path)
    }

    nonisolated private static func loadIntegrityDatasetCaseRecords(path: String) throws -> [BenchmarkDatasetCaseRecord] {
        let store = BenchmarkDatasetStore()
        return try store.loadCases(path: path)
    }

    private func saveIntegrityDatasetCaseRecords(path: String, records: [BenchmarkDatasetCaseRecord]) throws {
        try datasetStore.saveCases(path: path, records: records)
    }

    private func playCaseAudio() {
        let selectedPath = selectedIntegrityCaseDetail?.audioFilePath ?? selectedCaseDetail?.audioFilePath
        guard let path = selectedPath,
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

    private func resolvedCompareWorkers() -> Int {
        let requested = compareWorkers ?? defaultCompareWorkers
        return max(1, requested)
    }

    private func clearIntegrityCaseDetail() {
        stopCaseAudioPlayback(showMessage: false)
        selectedIntegrityCaseDetail = nil
        isIntegrityCaseDetailPresented = false
        isIntegrityCaseEditing = false
        integrityCaseDraftSTTText = ""
        integrityCaseDraftGroundTruthText = ""
        isIntegrityCaseDeleteConfirmationPresented = false
    }

    private func clearPairwiseCaseDetail() {
        generationPairwiseCaseDetail = nil
        isPairwiseCaseDetailPresented = false
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

    private func boolOption(_ options: [String: String]?, key: String, defaultValue: Bool) -> Bool {
        guard let raw = options?[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else {
            return defaultValue
        }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }

    private func presentPromptCandidateModal(
        mode: PromptCandidateModalMode,
        candidateID: String,
        model: LLMModel,
        promptName: String,
        promptTemplate: String?,
        options: [String: String]?
    ) {
        promptCandidateModalMode = mode
        presentCandidateDraft(
            candidateID: candidateID,
            model: model,
            promptName: promptName,
            promptTemplate: promptTemplate,
            options: options
        )
        isPromptCandidateModalPresented = true
    }

    private func presentCandidateDraft(
        candidateID: String,
        model: LLMModel,
        promptName: String,
        promptTemplate: String?,
        options: [String: String]?
    ) {
        let template = canonicalPromptTemplate(promptTemplate ?? defaultPostProcessPromptTemplate)
        promptCandidateDraftCandidateID = candidateID
        promptCandidateDraftModel = model
        promptCandidateDraftName = promptName
        promptCandidateDraftTemplate = template.isEmpty ? defaultPostProcessPromptTemplate : template
        promptCandidateDraftRequireContext = boolOption(options, key: "require_context", defaultValue: false)
        promptCandidateDraftUseCache = boolOption(options, key: "use_cache", defaultValue: true)
        promptCandidateDraftValidationError = ""
    }

    private func resolveDefaultPromptCandidateModel(baseCandidate: BenchmarkCandidate?) -> LLMModel {
        if let raw = baseCandidate?.model,
           let parsed = LLMModelCatalog.resolveRegistered(rawValue: raw),
           LLMModelCatalog.isSelectable(parsed, for: .benchmarkPromptCandidate)
        {
            return parsed
        }
        if let configModel = try? ConfigStore().load().llmModel,
           LLMModelCatalog.isSelectable(configModel, for: .benchmarkPromptCandidate)
        {
            return configModel
        }
        return LLMModelCatalog.defaultModel(for: .benchmarkPromptCandidate)
    }

    private func makeAutoPromptCandidateID(model: LLMModel) -> String {
        let base = sanitizeCandidateID("generation-\(model.rawValue)-\(timestampToken())")
        let existing = Set(candidates.map(\.id))
        if !existing.contains(base) {
            return base
        }
        var suffix = 2
        while true {
            let next = "\(base)-\(suffix)"
            if !existing.contains(next) {
                return next
            }
            suffix += 1
        }
    }

    private func sanitizeCandidateID(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let transformed = value.unicodeScalars.map { scalar -> String in
            if allowed.contains(scalar) {
                return String(scalar)
            }
            return "-"
        }.joined()
        let compact = transformed.replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        let trimmed = compact.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return trimmed.isEmpty ? "generation-candidate" : trimmed
    }

    private func timestampToken() -> String {
        WhispTime.timestampTokenSeconds()
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
        Self.normalizePathForStorage(raw)
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
        WhispPaths.normalizeForStorage(raw)
    }

    private static let generationPromptVariables: [PromptVariableItem] = generationPromptVariableDescriptors.map { descriptor in
        PromptVariableItem(
            id: descriptor.token,
            token: descriptor.token,
            description: descriptor.description,
            sample: descriptor.sample
        )
    }

}
