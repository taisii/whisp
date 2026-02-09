import AppKit
import Foundation
import WhispCore

@MainActor
final class AppCoordinator {
    var onStateChanged: ((PipelineState) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var state: PipelineState = .idle {
        didSet {
            onStateChanged?(state)
        }
    }

    private(set) var config: Config

    private let configStore: ConfigStore
    private let usageStore: UsageStore
    private let deepgramClient: DeepgramClient
    private let postProcessor: PostProcessorService
    private let settingsWindowController: SettingsWindowController
    private let hotKeyMonitor: GlobalHotKeyMonitor

    private var recorder: AudioRecorder?
    private var processingTask: Task<Void, Never>?
    private var visionContextTask: Task<ContextInfo?, Never>?

    init() throws {
        configStore = try ConfigStore()
        usageStore = try UsageStore()
        config = try configStore.loadOrCreate()

        deepgramClient = DeepgramClient()
        postProcessor = PostProcessorService()
        settingsWindowController = SettingsWindowController()
        hotKeyMonitor = try GlobalHotKeyMonitor()

        try registerShortcut()
    }

    deinit {
        processingTask?.cancel()
        hotKeyMonitor.unregister()
    }

    func toggleRecording() {
        if recorder == nil {
            startRecording()
        } else {
            stopRecording()
        }
    }

    func openSettings() {
        settingsWindowController.show(config: config) { [weak self] updated in
            self?.saveConfig(updated)
        }
    }

    func openMicrophoneSettings() {
        DirectInput.openMicrophoneSettings()
    }

    func openAccessibilitySettings() {
        DirectInput.openAccessibilitySettings()
    }

    func requestAccessibilityPermission(prompt: Bool = true) -> Bool {
        DirectInput.requestAccessibilityPermission(prompt: prompt)
    }

    func isAccessibilityTrusted() -> Bool {
        DirectInput.isAccessibilityTrusted()
    }

    func requestAccessibilityPermissionOnLaunch() {
        guard config.context.accessibilityEnabled else {
            return
        }
        _ = DirectInput.requestAccessibilityPermission(prompt: true)
    }

    private func registerShortcut() throws {
        try hotKeyMonitor.register(
            shortcutString: config.shortcut,
            onPressed: { [weak self] in
                Task { @MainActor in
                    self?.handleShortcutPressed()
                }
            },
            onReleased: { [weak self] in
                Task { @MainActor in
                    self?.handleShortcutReleased()
                }
            }
        )
    }

    private func handleShortcutPressed() {
        switch config.recordingMode {
        case .toggle:
            toggleRecording()
        case .pushToTalk:
            if recorder == nil {
                startRecording()
            }
        }
    }

    private func handleShortcutReleased() {
        if config.recordingMode == .pushToTalk {
            stopRecording()
        }
    }

    private func saveConfig(_ updated: Config) {
        do {
            try configStore.save(updated)
            config = updated
            try registerShortcut()
        } catch {
            reportError("設定保存に失敗: \(error.localizedDescription)")
        }
    }

    private func startRecording() {
        do {
            try validateBeforeRecording()
            let recorder = AudioRecorder()
            try recorder.start()
            self.recorder = recorder
            startVisionContextCollection(config: config)
            state = .recording
            _ = playStartSound()
        } catch {
            reportError("録音開始に失敗: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard let recorder else { return }

        let result = recorder.stop()
        self.recorder = nil
        state = .sttStreaming

        let snapshot = config
        let visionTask = visionContextTask
        visionContextTask = nil
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.processRecording(result: result, config: snapshot, visionTask: visionTask)
        }
    }

    private func processRecording(
        result: RecordingResult,
        config: Config,
        visionTask: Task<ContextInfo?, Never>?
    ) async {
        do {
            guard !result.pcmData.isEmpty else {
                state = .idle
                return
            }

            var sttUsage: STTUsage?
            var llmUsage: LLMUsage?
            let sttText: String
            let processedText: String

            if config.llmModel.usesDirectAudio {
                state = .postProcessing
                let wav = buildWAVBytes(sampleRate: UInt32(result.sampleRate), pcmData: result.pcmData)
                let key = try llmAPIKey(config: config)
                let context = await resolveVisionContext(from: visionTask)
                let transcription = try await postProcessor.transcribeAudioGemini(
                    apiKey: key,
                    wavData: wav,
                    mimeType: "audio/wav",
                    context: context
                )
                processedText = transcription.text
                sttText = transcription.text
                llmUsage = transcription.usage
            } else {
                let deepgramKey = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
                if deepgramKey.isEmpty {
                    throw AppError.invalidArgument("Deepgram APIキーが未設定です")
                }

                let stt = try await deepgramClient.transcribe(
                    apiKey: deepgramKey,
                    sampleRate: result.sampleRate,
                    audio: result.pcmData,
                    language: languageParam(config.inputLanguage)
                )

                sttText = stt.transcript
                sttUsage = stt.usage

                if isEmptySTT(sttText) {
                    usageStore.recordUsage(stt: sttUsage, llm: nil)
                    state = .idle
                    return
                }

                state = .postProcessing
                let appName = NSWorkspace.shared.frontmostApplication?.localizedName
                let key = try llmAPIKey(config: config)
                let context = await resolveVisionContext(from: visionTask)
                let result = try await postProcessor.postProcess(
                    model: config.llmModel,
                    apiKey: key,
                    sttResult: sttText,
                    languageHint: config.inputLanguage,
                    appName: appName,
                    appPromptRules: config.appPromptRules,
                    context: context
                )

                processedText = result.text
                llmUsage = result.usage
            }

            usageStore.recordUsage(stt: sttUsage, llm: llmUsage)

            if isEmptySTT(processedText) {
                state = .idle
                return
            }

            state = .directInput
            if !DirectInput.sendText(processedText) {
                reportError("直接入力に失敗しました。アクセシビリティ権限を確認してください。")
            }

            _ = playCompletionSound()
            state = .done

            try? await Task.sleep(nanoseconds: 100_000_000)
            state = .idle

            print("[pipeline] stt chars=\(sttText.count), output chars=\(processedText.count)")
        } catch {
            reportError("処理に失敗: \(error.localizedDescription)")
            state = .idle
        }
    }

    private func validateBeforeRecording() throws {
        if !config.llmModel.usesDirectAudio {
            let deepgramKey = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
            if deepgramKey.isEmpty {
                throw AppError.invalidArgument("Deepgram APIキーが未設定です")
            }
        }

        _ = try llmAPIKey(config: config)
    }

    private func llmAPIKey(config: Config) throws -> String {
        switch config.llmModel {
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            let key = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                throw AppError.invalidArgument("Gemini APIキーが未設定です")
            }
            return key
        case .gpt4oMini, .gpt5Nano:
            let key = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                throw AppError.invalidArgument("OpenAI APIキーが未設定です")
            }
            return key
        }
    }

    private func languageParam(_ value: String) -> String? {
        switch value {
        case "auto":
            return nil
        case "ja":
            return "ja"
        case "en":
            return "en"
        default:
            return nil
        }
    }

    private func reportError(_ message: String) {
        state = .error
        print("[error] \(message)")
        onError?(message)
    }

    private func startVisionContextCollection(config: Config) {
        visionContextTask?.cancel()
        guard config.context.visionEnabled else {
            visionContextTask = nil
            return
        }

        let key: String
        do {
            key = try llmAPIKey(config: config)
        } catch {
            visionContextTask = nil
            return
        }

        let model = config.llmModel
        visionContextTask = Task { @MainActor [weak self] in
            guard let self else { return nil }
            guard let imageData = ScreenCapture.capturePNG() else {
                return nil
            }
            do {
                return try await postProcessor.analyzeVisionContext(
                    model: model,
                    apiKey: key,
                    imageData: imageData,
                    mimeType: "image/png"
                )
            } catch {
                print("[vision] failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private func resolveVisionContext(from task: Task<ContextInfo?, Never>?) async -> ContextInfo? {
        guard let task else { return nil }
        return await task.value
    }
}
