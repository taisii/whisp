import AppKit
import Foundation
import WhispCore

private struct RecordingRun {
    let id: String
    let startedAt: DispatchTime
}

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
    private let postProcessor: PostProcessorService
    private let sttService: STTService
    private let contextService: ContextService
    private let recordingService: RecordingService
    private let outputService: OutputService
    private let debugCaptureService: DebugCaptureService
    private let settingsWindowController: SettingsWindowController
    private let debugWindowController: DebugWindowController
    private let hotKeyMonitor: GlobalHotKeyMonitor

    private var stateMachine = PipelineStateMachine()
    private var currentRun: RecordingRun?
    private var recorder: AudioRecorder?
    private var processingTask: Task<Void, Never>?
    private var sttStreamingSession: (any STTStreamingSession)?

    init() throws {
        configStore = try ConfigStore()
        usageStore = try UsageStore()
        config = try configStore.loadOrCreate()

        postProcessor = PostProcessorService()
        sttService = DeepgramSTTService()
        contextService = ContextService(
            accessibilityProvider: SystemAccessibilityContextProvider(),
            visionProvider: ScreenVisionContextProvider(postProcessor: postProcessor)
        )
        recordingService = SystemRecordingService()
        outputService = DirectInputOutputService()
        debugCaptureService = DebugCaptureService()
        settingsWindowController = SettingsWindowController()
        debugWindowController = DebugWindowController(store: .shared)
        hotKeyMonitor = try GlobalHotKeyMonitor()

        try registerShortcut()
    }

    deinit {
        processingTask?.cancel()
        sttStreamingSession = nil
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

    func openDebugWindow() {
        debugWindowController.show()
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
        let run = RecordingRun(id: Self.makeRunID(), startedAt: .now())
        currentRun = run
        do {
            try validateBeforeRecording()

            let logger = pipelineLogger(runID: run.id, captureID: nil)
            let streamingSession = sttService.startStreamingSessionIfNeeded(
                config: config,
                runID: run.id,
                language: languageParam(config.inputLanguage),
                logger: logger
            )
            sttStreamingSession = streamingSession

            let recorder = try recordingService.startRecording(onChunk: { [weak streamingSession] chunk in
                streamingSession?.submit(chunk: chunk)
            })
            self.recorder = recorder
            transition(.startRecording)
            devLog("recording_start", runID: run.id, fields: [
                "mode": config.recordingMode.rawValue,
                "model": config.llmModel.rawValue,
                "vision_enabled": String(config.context.visionEnabled),
                "stt_streaming": String(streamingSession != nil),
                "log_file": DevLog.filePath ?? "n/a",
            ])
            _ = outputService.playStartSound()
        } catch {
            currentRun = nil
            sttStreamingSession = nil
            reportError("録音開始に失敗: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        let run = currentRun ?? RecordingRun(id: Self.makeRunID(), startedAt: .now())
        currentRun = nil

        let result = recordingService.stopRecording(recorder)
        self.recorder = nil
        transition(.stopRecording)

        let recordingMs = elapsedMs(since: run.startedAt)
        devLog("recording_stop", runID: run.id, fields: [
            "recording_ms": msString(recordingMs),
            "pcm_bytes": String(result.pcmData.count),
            "sample_rate": String(result.sampleRate),
        ])

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let accessibility = contextService.captureAccessibility(frontmostApp: frontmostApp)
        let artifacts = debugCaptureService.saveRecording(
            runID: run.id,
            recording: result,
            config: config,
            frontmostApp: frontmostApp,
            accessibility: accessibility
        )

        if let captureID = artifacts.captureID {
            devLog("debug_capture_saved", runID: run.id, captureID: captureID, fields: [
                "capture_id": captureID,
                "capture_dir": artifacts.runDirectory ?? debugCaptureService.capturesDirectoryPath,
            ])
        }

        let snapshot = config
        let streamingSession = sttStreamingSession
        sttStreamingSession = nil
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.processRecording(
                result: result,
                config: snapshot,
                run: run,
                artifacts: artifacts,
                sttStreamingSession: streamingSession
            )
        }
    }

    private func processRecording(
        result: RecordingResult,
        config: Config,
        run: RecordingRun,
        artifacts: DebugRunArtifacts,
        sttStreamingSession: (any STTStreamingSession)?
    ) async {
        let pipelineStartedAt = DispatchTime.now()
        let captureID = artifacts.captureID
        let debugRunDirectory = artifacts.runDirectory
        let accessibilityContext = artifacts.accessibilityContext
        let logger = pipelineLogger(runID: run.id, captureID: captureID)

        var debugSTTText: String?
        var debugOutputText: String?

        do {
            guard !result.pcmData.isEmpty else {
                debugCaptureService.updateResult(
                    captureID: captureID,
                    sttText: nil,
                    outputText: nil,
                    status: "skipped_empty_audio"
                )
                devLog("pipeline_skip_empty_audio", runID: run.id, captureID: captureID)
                transition(.reset)
                return
            }

            var sttUsage: STTUsage?
            var llmUsage: LLMUsage?
            let sttText: String
            let processedText: String

            if config.llmModel.usesDirectAudio {
                transition(.startPostProcessing)
                let wav = buildWAVBytes(sampleRate: UInt32(result.sampleRate), pcmData: result.pcmData)
                let llmKey = try llmAPIKey(config: config)
                let llmStartedAt = DispatchTime.now()
                devLog("audio_llm_start", runID: run.id, captureID: captureID, fields: [
                    "pcm_bytes": String(result.pcmData.count),
                    "context_present": String(accessibilityContext != nil),
                ])
                let transcription = try await postProcessor.transcribeAudio(
                    model: config.llmModel,
                    apiKey: llmKey,
                    wavData: wav,
                    mimeType: "audio/wav",
                    context: accessibilityContext,
                    debugRunID: run.id,
                    debugRunDirectory: debugRunDirectory
                )
                devLog("audio_llm_done", runID: run.id, captureID: captureID, fields: [
                    "duration_ms": msString(elapsedMs(since: llmStartedAt)),
                    "output_chars": String(transcription.text.count),
                ])
                processedText = transcription.text
                sttText = transcription.text
                llmUsage = transcription.usage
            } else {
                let llmKey = try llmAPIKey(config: config)
                let visionTask = contextService.startVisionCollection(
                    config: config,
                    runID: run.id,
                    runDirectory: debugRunDirectory,
                    llmAPIKey: llmKey,
                    logger: logger
                )

                let stt = try await sttService.transcribe(
                    config: config,
                    recording: result,
                    language: languageParam(config.inputLanguage),
                    runID: run.id,
                    streamingSession: sttStreamingSession,
                    logger: logger
                )

                sttText = stt.transcript
                sttUsage = stt.usage

                if isEmptySTT(sttText) {
                    visionTask?.cancel()
                    usageStore.recordUsage(stt: sttUsage, llm: nil)
                    debugSTTText = sttText
                    debugCaptureService.updateResult(
                        captureID: captureID,
                        sttText: debugSTTText,
                        outputText: nil,
                        status: "skipped_empty_stt"
                    )
                    devLog("pipeline_skip_empty_stt", runID: run.id, captureID: captureID, fields: [
                        "stt_ms": msString(elapsedMs(since: pipelineStartedAt)),
                    ])
                    transition(.reset)
                    return
                }

                transition(.startPostProcessing)
                let appName = NSWorkspace.shared.frontmostApplication?.localizedName
                let visionResult = await contextService.resolveVisionIfReady(task: visionTask, logger: logger)
                debugCaptureService.persistVisionArtifacts(captureID: captureID, result: visionResult)
                let context = contextService.compose(accessibility: accessibilityContext, vision: visionResult?.context)

                let llmStartedAt = DispatchTime.now()
                devLog("postprocess_start", runID: run.id, captureID: captureID, fields: [
                    "model": config.llmModel.rawValue,
                    "context_present": String(context != nil),
                    "stt_chars": String(sttText.count),
                ])
                let postProcessed = try await postProcessor.postProcess(
                    model: config.llmModel,
                    apiKey: llmKey,
                    sttResult: sttText,
                    languageHint: config.inputLanguage,
                    appName: appName,
                    appPromptRules: config.appPromptRules,
                    context: context,
                    debugRunID: run.id,
                    debugRunDirectory: debugRunDirectory
                )
                devLog("postprocess_done", runID: run.id, captureID: captureID, fields: [
                    "duration_ms": msString(elapsedMs(since: llmStartedAt)),
                    "output_chars": String(postProcessed.text.count),
                ])

                processedText = postProcessed.text
                llmUsage = postProcessed.usage
            }

            debugSTTText = sttText
            debugOutputText = processedText
            usageStore.recordUsage(stt: sttUsage, llm: llmUsage)

            if isEmptySTT(processedText) {
                debugCaptureService.updateResult(
                    captureID: captureID,
                    sttText: debugSTTText,
                    outputText: debugOutputText,
                    status: "skipped_empty_output"
                )
                devLog("pipeline_skip_empty_output", runID: run.id, captureID: captureID)
                transition(.reset)
                return
            }

            transition(.startDirectInput)
            let inputStartedAt = DispatchTime.now()
            let directInputOK = outputService.sendText(processedText)
            devLog("direct_input_done", runID: run.id, captureID: captureID, fields: [
                "duration_ms": msString(elapsedMs(since: inputStartedAt)),
                "success": String(directInputOK),
                "output_chars": String(processedText.count),
            ])
            debugCaptureService.updateResult(
                captureID: captureID,
                sttText: debugSTTText,
                outputText: debugOutputText,
                status: directInputOK ? "done" : "done_input_failed"
            )
            if !directInputOK {
                notifyError("直接入力に失敗しました。アクセシビリティ権限を確認してください。")
            }

            _ = outputService.playCompletionSound()
            transition(.finish)

            try? await Task.sleep(nanoseconds: 100_000_000)
            transition(.reset)

            let pipelineMs = elapsedMs(since: pipelineStartedAt)
            let endToEndMs = elapsedMs(since: run.startedAt)
            devLog("pipeline_done", runID: run.id, captureID: captureID, fields: [
                "pipeline_ms": msString(pipelineMs),
                "end_to_end_ms": msString(endToEndMs),
                "stt_chars": String(sttText.count),
                "output_chars": String(processedText.count),
            ])
            print("[pipeline] stt chars=\(sttText.count), output chars=\(processedText.count)")
        } catch {
            debugCaptureService.updateResult(
                captureID: captureID,
                sttText: debugSTTText,
                outputText: debugOutputText,
                status: "error",
                errorMessage: error.localizedDescription
            )
            devLog("pipeline_error", runID: run.id, captureID: captureID, fields: [
                "error": error.localizedDescription,
                "elapsed_ms": msString(elapsedMs(since: pipelineStartedAt)),
            ])
            reportError("処理に失敗: \(error.localizedDescription)")
            transition(.reset)
        }
    }

    private func transition(_ event: PipelineStateMachine.Event) {
        state = stateMachine.apply(event)
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
        transition(.fail)
        print("[error] \(message)")
        onError?(message)
    }

    private func notifyError(_ message: String) {
        print("[warn] \(message)")
        onError?(message)
    }

    private func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    private func msString(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func pipelineLogger(runID: String, captureID: String?) -> PipelineEventLogger {
        { [weak self] event, fields in
            Task { @MainActor in
                self?.devLog(event, runID: runID, captureID: captureID, fields: fields)
            }
        }
    }

    private func devLog(_ event: String, runID: String, captureID: String? = nil, fields: [String: String] = [:]) {
        var payload = fields
        payload["run"] = runID
        DevLog.info(event, fields: payload)
        SystemLog.app(event, fields: payload)
        debugCaptureService.appendEvent(captureID: captureID, event: event, fields: payload)
    }

    private static func makeRunID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
