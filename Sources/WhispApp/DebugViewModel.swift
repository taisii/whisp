import AppKit
import AVFoundation
import SwiftUI
import WhispCore

enum DebugRecordFilter: String, CaseIterable, Identifiable {
    case missingGroundTruth = "未入力"
    case completedGroundTruth = "入力済み"

    var id: String { rawValue }
}

@MainActor
final class DebugViewModel: ObservableObject {
    @Published var records: [DebugCaptureRecord] = []
    @Published var recordFilter: DebugRecordFilter = .missingGroundTruth
    @Published var selectedCaptureID: String?
    @Published var details: DebugCaptureDetails?
    @Published var selectedPromptIndex = 0
    @Published var groundTruthDraft = "" {
        didSet {
            hasUnsavedGroundTruthChanges = (groundTruthDraft != persistedGroundTruthText)
            if hasUnsavedGroundTruthChanges {
                groundTruthSaveMessage = ""
                groundTruthSaveIsError = false
            }
        }
    }
    @Published private(set) var hasUnsavedGroundTruthChanges = false
    @Published var groundTruthSaveMessage = ""
    @Published var groundTruthSaveIsError = false
    @Published var statusMessage = ""
    @Published var statusIsError = false
    @Published var isAudioPlaying = false

    private let store: DebugCaptureStore
    private var persistedGroundTruthText = ""
    private var audioPlayer: AVAudioPlayer?
    private var audioPollingTimer: Timer?

    init(store: DebugCaptureStore) {
        self.store = store
    }

    var filteredRecords: [DebugCaptureRecord] {
        records.filter { record in
            switch recordFilter {
            case .missingGroundTruth:
                return !hasGroundTruth(record)
            case .completedGroundTruth:
                return hasGroundTruth(record)
            }
        }
    }

    var visibleCountText: String {
        "\(filteredRecords.count) / \(records.count)"
    }

    var selectedPrompt: DebugPromptSnapshot? {
        guard let details, details.prompts.indices.contains(selectedPromptIndex) else {
            return nil
        }
        return details.prompts[selectedPromptIndex]
    }

    func refresh() {
        do {
            records = try store.listRecords(limit: 200)
            let detailLoadSucceeded = syncSelectionForCurrentFilter()
            if detailLoadSucceeded {
                setStatus("最新のデータを読み込みました。", isError: false)
            }
        } catch {
            setStatus("読み込みに失敗: \(error.localizedDescription)", isError: true)
        }
    }

    func handleFilterChanged() {
        _ = syncSelectionForCurrentFilter()
    }

    func select(captureID: String?) {
        stopAudioPlayback(showMessage: false)
        selectedCaptureID = captureID
        guard let captureID else {
            details = nil
            selectedPromptIndex = 0
            persistedGroundTruthText = ""
            groundTruthDraft = ""
            clearGroundTruthSaveFeedback()
            return
        }
        _ = loadDetails(captureID: captureID)
    }

    func saveGroundTruth() {
        guard let captureID = selectedCaptureID else { return }
        let previousGroundTruth = persistedGroundTruthText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newGroundTruth = groundTruthDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldAppendManualCaseByDefault = previousGroundTruth.isEmpty && !newGroundTruth.isEmpty

        do {
            try store.setGroundTruth(captureID: captureID, text: groundTruthDraft)
            var autoAppendError: String?
            if shouldAppendManualCaseByDefault {
                do {
                    _ = try store.appendManualTestCase(captureID: captureID)
                } catch {
                    autoAppendError = error.localizedDescription
                }
            }

            records = (try? store.listRecords(limit: 200)) ?? records
            _ = loadDetails(captureID: captureID)
            if hasGroundTruth(details?.record), recordFilter == .missingGroundTruth {
                _ = syncSelectionForCurrentFilter()
            }

            if let autoAppendError {
                let message = "正解テキストを保存しましたが、テストケース追加に失敗: \(autoAppendError)"
                setStatus(message, isError: true)
                setGroundTruthSaveFeedback(message, isError: true)
            } else if shouldAppendManualCaseByDefault {
                setStatus("正解テキストを保存し、テストケースへ自動追加しました。", isError: false)
                setGroundTruthSaveFeedback("正解テキストを保存し、テストケースへ自動追加しました。", isError: false)
            } else {
                setStatus("正解テキストを保存しました。", isError: false)
                setGroundTruthSaveFeedback("正解テキストを保存しました。", isError: false)
            }
        } catch {
            setStatus("正解テキスト保存に失敗: \(error.localizedDescription)", isError: true)
            setGroundTruthSaveFeedback("正解テキスト保存に失敗: \(error.localizedDescription)", isError: true)
        }
    }

    func appendManualTestCase() {
        guard let captureID = selectedCaptureID else { return }
        do {
            let path = try store.appendManualTestCase(captureID: captureID)
            setStatus("テストケースに追加しました: \(path)", isError: false)
        } catch {
            setStatus("テストケース追加に失敗: \(error.localizedDescription)", isError: true)
        }
    }

    func deleteSelectedCapture() {
        guard let captureID = selectedCaptureID else { return }
        do {
            stopAudioPlayback(showMessage: false)
            try store.deleteCapture(captureID: captureID)
            records = (try? store.listRecords(limit: 200)) ?? records
            _ = syncSelectionForCurrentFilter()
            setStatus("ログを削除しました。", isError: false)
        } catch {
            setStatus("ログ削除に失敗: \(error.localizedDescription)", isError: true)
        }
    }

    func revealAudioFile() {
        guard let path = details?.record.audioFilePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func revealVisionImageFile() {
        guard let path = details?.record.visionImageFilePath, !path.isEmpty else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func revealRunDirectory() {
        guard let path = details?.record.runDirectoryPath, !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func revealEventsFile() {
        guard let path = details?.record.eventsFilePath, !path.isEmpty else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func toggleAudioPlayback() {
        if isAudioPlaying {
            stopAudioPlayback()
            return
        }
        playAudio()
    }

    func copyGroundTruth() {
        copyTextToPasteboard(groundTruthDraft, successMessage: "正解テキストをコピーしました。")
    }

    func copySTTText() {
        copyTextToPasteboard(details?.record.sttText ?? "", successMessage: "STT結果をコピーしました。")
    }

    func copyOutputText() {
        copyTextToPasteboard(details?.record.outputText ?? "", successMessage: "最終出力をコピーしました。")
    }

    private func copyTextToPasteboard(_ text: String, successMessage: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        setStatus(successMessage, isError: false)
    }

    func pasteGroundTruth() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else {
            setStatus("クリップボードにテキストがありません。", isError: true)
            return
        }
        groundTruthDraft = text
        setStatus("正解テキストを貼り付けました。", isError: false)
        setGroundTruthSaveFeedback("正解欄を更新しました。保存してください。", isError: false)
    }

    func applyOutputAsGroundTruth() {
        guard let outputText = details?.record.outputText else {
            setStatus("最終出力がありません。", isError: true)
            return
        }
        guard !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus("最終出力が空のため反映できません。", isError: true)
            return
        }
        groundTruthDraft = outputText
        setStatus("最終出力を正解欄に反映しました。", isError: false)
        setGroundTruthSaveFeedback("最終出力を反映しました。保存してください。", isError: false)
    }

    func openPromptsDirectory() {
        let path = details?.record.promptsDirectoryPath ?? store.promptsDirectoryPath
        let url = URL(fileURLWithPath: path, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    private func loadDetails(captureID: String) -> Bool {
        do {
            details = try store.loadDetails(captureID: captureID)
            selectedPromptIndex = 0
            let groundTruth = details?.record.groundTruthText ?? ""
            persistedGroundTruthText = groundTruth
            groundTruthDraft = groundTruth
            clearGroundTruthSaveFeedback()
            return true
        } catch {
            details = nil
            selectedPromptIndex = 0
            persistedGroundTruthText = ""
            groundTruthDraft = ""
            clearGroundTruthSaveFeedback()
            setStatus("詳細読み込みに失敗: \(error.localizedDescription)", isError: true)
            return false
        }
    }

    @discardableResult
    private func syncSelectionForCurrentFilter() -> Bool {
        let visibleRecords = filteredRecords
        if let selectedCaptureID, visibleRecords.contains(where: { $0.id == selectedCaptureID }) {
            return loadDetails(captureID: selectedCaptureID)
        }
        if let first = visibleRecords.first {
            selectedCaptureID = first.id
            return loadDetails(captureID: first.id)
        }

        selectedCaptureID = nil
        details = nil
        selectedPromptIndex = 0
        persistedGroundTruthText = ""
        groundTruthDraft = ""
        clearGroundTruthSaveFeedback()
        return true
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func setGroundTruthSaveFeedback(_ message: String, isError: Bool) {
        groundTruthSaveMessage = message
        groundTruthSaveIsError = isError
    }

    private func clearGroundTruthSaveFeedback() {
        groundTruthSaveMessage = ""
        groundTruthSaveIsError = false
    }

    private func hasGroundTruth(_ record: DebugCaptureRecord?) -> Bool {
        guard let text = record?.groundTruthText else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func playAudio() {
        guard let path = details?.record.audioFilePath else {
            setStatus("録音ファイルが見つかりません。", isError: true)
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            stopAudioPlayback(showMessage: false)
            audioPlayer = player
            player.prepareToPlay()
            guard player.play() else {
                throw AppError.io("再生開始に失敗しました")
            }

            isAudioPlaying = true
            startAudioPolling()
            setStatus("録音を再生中です。", isError: false)
        } catch {
            stopAudioPlayback(showMessage: false)
            setStatus("録音の再生に失敗: \(error.localizedDescription)", isError: true)
        }
    }

    private func stopAudioPlayback(showMessage: Bool = true) {
        audioPlayer?.stop()
        audioPlayer = nil
        audioPollingTimer?.invalidate()
        audioPollingTimer = nil
        isAudioPlaying = false
        if showMessage {
            setStatus("録音の再生を停止しました。", isError: false)
        }
    }

    private func startAudioPolling() {
        audioPollingTimer?.invalidate()
        audioPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let audioPlayer = self.audioPlayer else {
                    self.stopAudioPlayback(showMessage: false)
                    return
                }
                if !audioPlayer.isPlaying {
                    self.stopAudioPlayback(showMessage: false)
                }
            }
        }
    }
}
