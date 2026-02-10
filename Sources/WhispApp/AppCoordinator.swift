import AppKit
import Foundation
import WhispCore

private struct RecordingRun {
    let id: String
    let startedAt: DispatchTime
    let startedAtDate: Date
    let appNameAtStart: String?
    let recordingStartFields: [String: String]
}

private struct PendingCaptureRunEvent {
    let event: DebugRunEventName
    let fields: [String: String]
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
    private var pendingAccessibilitySummaryTask: Task<ContextInfo?, Never>?
    private var pendingAccessibilitySummaryRunID: String?
    private var captureIDByRunID: [String: String] = [:]
    private var pendingCaptureEventsByRunID: [String: [PendingCaptureRunEvent]] = [:]

    init() throws {
        configStore = try ConfigStore()
        usageStore = try UsageStore()
        config = try configStore.loadOrCreate()

        postProcessor = PostProcessorService()
        sttService = ProviderSwitchingSTTService()
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
        pendingAccessibilitySummaryTask?.cancel()
        pendingAccessibilitySummaryTask = nil
        pendingAccessibilitySummaryRunID = nil
        captureIDByRunID.removeAll()
        pendingCaptureEventsByRunID.removeAll()
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
        let runID = Self.makeRunID()
        let startedAt: DispatchTime = .now()
        let startedAtDate = Date()
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appNameAtStart = frontmostApp?.localizedName
        let accessibilityAtStart = contextService.captureAccessibility(frontmostApp: frontmostApp)
        do {
            try validateBeforeRecording()

            let logger = pipelineLogger(runID: runID, captureID: nil)
            let streamingSession = sttService.startStreamingSessionIfNeeded(
                config: config,
                runID: runID,
                language: languageParam(config.inputLanguage),
                logger: logger
            )
            sttStreamingSession = streamingSession

            let recordingStartFields: [String: String] = [
                DebugRunEventField.mode.rawValue: config.recordingMode.rawValue,
                DebugRunEventField.model.rawValue: config.llmModel.rawValue,
                DebugRunEventField.sttProvider.rawValue: config.sttProvider.rawValue,
                "vision_enabled": String(config.context.visionEnabled),
                DebugRunEventField.sttStreaming.rawValue: String(streamingSession != nil),
                "log_file": DevLog.filePath ?? "n/a",
                DebugRunEventField.recordingStartedAtMs.rawValue: epochMsString(startedAtDate),
            ]
            let run = RecordingRun(
                id: runID,
                startedAt: startedAt,
                startedAtDate: startedAtDate,
                appNameAtStart: appNameAtStart,
                recordingStartFields: recordingStartFields
            )
            currentRun = run
            startAccessibilitySummaryTask(run: run, config: config, context: accessibilityAtStart.context)

            let recorder = try recordingService.startRecording(onChunk: { [weak streamingSession] chunk in
                streamingSession?.submit(chunk: chunk)
            })
            self.recorder = recorder
            transition(.startRecording)
            devLog(.recordingStart, runID: run.id, fields: run.recordingStartFields)
            _ = outputService.playStartSound()
        } catch {
            pendingAccessibilitySummaryTask?.cancel()
            pendingAccessibilitySummaryTask = nil
            pendingAccessibilitySummaryRunID = nil
            currentRun = nil
            sttStreamingSession = nil
            reportError("録音開始に失敗: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        let run = currentRun ?? RecordingRun(
            id: Self.makeRunID(),
            startedAt: .now(),
            startedAtDate: Date(),
            appNameAtStart: nil,
            recordingStartFields: [:]
        )
        currentRun = nil

        let result = recordingService.stopRecording(recorder)
        let stoppedAtDate = Date()
        self.recorder = nil
        transition(.stopRecording)

        let recordingMs = elapsedMs(since: run.startedAt)
        let recordingStopFields: [String: String] = [
            DebugRunEventField.recordingMs.rawValue: msString(recordingMs),
            DebugRunEventField.pcmBytes.rawValue: String(result.pcmData.count),
            DebugRunEventField.sampleRate.rawValue: String(result.sampleRate),
            DebugRunEventField.recordingStoppedAtMs.rawValue: epochMsString(stoppedAtDate),
        ]
        devLog(.recordingStop, runID: run.id, fields: recordingStopFields)

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
            captureIDByRunID[run.id] = captureID
            flushPendingCaptureEvents(runID: run.id, captureID: captureID)
            if !run.recordingStartFields.isEmpty {
                debugCaptureService.appendEvent(
                    captureID: captureID,
                    event: .recordingStart,
                    fields: run.recordingStartFields,
                    timestamp: run.startedAtDate
                )
            }
            debugCaptureService.appendEvent(
                captureID: captureID,
                event: .recordingStop,
                fields: recordingStopFields,
                timestamp: stoppedAtDate
            )
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
        let contextSummaryTask = takePendingAccessibilitySummaryTask(for: run.id)
        let logger = pipelineLogger(runID: run.id, captureID: captureID)

        var debugSTTText: String?
        var debugOutputText: String?

        do {
            guard !result.pcmData.isEmpty else {
                contextSummaryTask?.cancel()
                clearRunCaptureState(runID: run.id)
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
                let summaryContext = await resolveContextSummaryIfReady(task: contextSummaryTask)
                let context = contextService.compose(accessibility: accessibilityContext, vision: summaryContext)
                let llmStartedAt = DispatchTime.now()
                devLog(.audioLLMStart, runID: run.id, captureID: captureID, fields: [
                    DebugRunEventField.pcmBytes.rawValue: String(result.pcmData.count),
                    DebugRunEventField.contextPresent.rawValue: String(context != nil),
                ])
                let transcription = try await postProcessor.transcribeAudio(
                    model: config.llmModel,
                    apiKey: llmKey,
                    wavData: wav,
                    mimeType: "audio/wav",
                    context: context,
                    debugRunID: run.id,
                    debugRunDirectory: debugRunDirectory
                )
                devLog(.audioLLMDone, runID: run.id, captureID: captureID, fields: [
                    DebugRunEventField.durationMs.rawValue: msString(elapsedMs(since: llmStartedAt)),
                    DebugRunEventField.outputChars.rawValue: String(transcription.text.count),
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
                    contextSummaryTask?.cancel()
                    clearRunCaptureState(runID: run.id)
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
                let appName = run.appNameAtStart ?? NSWorkspace.shared.frontmostApplication?.localizedName
                let summaryContext = await resolveContextSummaryIfReady(task: contextSummaryTask)
                if contextSummaryTask != nil, summaryContext == nil {
                    devLog(.contextSummaryNotReadyContinue, runID: run.id, captureID: captureID, fields: [
                        "reason": "not_ready",
                        "prompt_context": "excluded",
                    ])
                }
                let visionResult = await contextService.resolveVisionIfReady(task: visionTask, logger: logger)
                debugCaptureService.persistVisionArtifacts(captureID: captureID, result: visionResult)
                if visionResult == nil, let visionTask {
                    persistDeferredVisionArtifacts(task: visionTask, runID: run.id, captureID: captureID)
                }
                let context = contextService.compose(accessibility: accessibilityContext, vision: summaryContext)

                let llmStartedAt = DispatchTime.now()
                devLog(.postprocessStart, runID: run.id, captureID: captureID, fields: [
                    DebugRunEventField.model.rawValue: config.llmModel.rawValue,
                    DebugRunEventField.contextPresent.rawValue: String(context != nil),
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
                devLog(.postprocessDone, runID: run.id, captureID: captureID, fields: [
                    DebugRunEventField.durationMs.rawValue: msString(elapsedMs(since: llmStartedAt)),
                    DebugRunEventField.outputChars.rawValue: String(postProcessed.text.count),
                ])

                processedText = postProcessed.text
                llmUsage = postProcessed.usage
            }

            debugSTTText = sttText
            debugOutputText = processedText
            usageStore.recordUsage(stt: sttUsage, llm: llmUsage)

            if isEmptySTT(processedText) {
                clearRunCaptureState(runID: run.id)
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
            devLog(.directInputDone, runID: run.id, captureID: captureID, fields: [
                DebugRunEventField.durationMs.rawValue: msString(elapsedMs(since: inputStartedAt)),
                "success": String(directInputOK),
                DebugRunEventField.outputChars.rawValue: String(processedText.count),
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
            devLog(.pipelineDone, runID: run.id, captureID: captureID, fields: [
                DebugRunEventField.pipelineMs.rawValue: msString(pipelineMs),
                DebugRunEventField.endToEndMs.rawValue: msString(endToEndMs),
                "stt_chars": String(sttText.count),
                DebugRunEventField.outputChars.rawValue: String(processedText.count),
            ])
            clearRunCaptureState(runID: run.id)
            print("[pipeline] stt chars=\(sttText.count), output chars=\(processedText.count)")
        } catch {
            contextSummaryTask?.cancel()
            clearRunCaptureState(runID: run.id)
            debugCaptureService.updateResult(
                captureID: captureID,
                sttText: debugSTTText,
                outputText: debugOutputText,
                status: "error",
                errorMessage: error.localizedDescription
            )
            devLog(.pipelineError, runID: run.id, captureID: captureID, fields: [
                DebugRunEventField.error.rawValue: error.localizedDescription,
                DebugRunEventField.elapsedMs.rawValue: msString(elapsedMs(since: pipelineStartedAt)),
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
            switch config.sttProvider {
            case .deepgram:
                let deepgramKey = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
                if deepgramKey.isEmpty {
                    throw AppError.invalidArgument("Deepgram APIキーが未設定です")
                }
            case .whisper:
                let openAIKey = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
                if openAIKey.isEmpty {
                    throw AppError.invalidArgument("OpenAI APIキーが未設定です（Whisper STT）")
                }
            case .appleSpeech:
                break
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

    private func epochMsString(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSince1970 * 1000)
    }

    private func startAccessibilitySummaryTask(run: RecordingRun, config: Config, context: ContextInfo?) {
        pendingAccessibilitySummaryTask?.cancel()
        pendingAccessibilitySummaryTask = nil
        pendingAccessibilitySummaryRunID = nil

        guard config.context.visionEnabled else {
            devLog(.contextSummaryDisabled, runID: run.id)
            return
        }

        guard let sourceText = accessibilitySummarySourceText(context: context) else {
            devLog(.contextSummarySkippedNoSource, runID: run.id)
            return
        }

        let llmKey: String
        let summaryModel: LLMModel = .gemini25FlashLite
        llmKey = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
        if llmKey.isEmpty {
            devLog(.contextSummarySkippedMissingKey, runID: run.id, fields: [
                DebugRunEventField.error.rawValue: "Gemini APIキーが未設定です",
            ])
            return
        }

        let requestSentAt = Date()
        logSummaryEvent(.contextSummaryStart, runID: run.id, fields: [
            DebugRunEventField.model.rawValue: summaryModel.rawValue,
            "source_chars": String(sourceText.count),
            DebugRunEventField.requestSentAtMs.rawValue: epochMsString(requestSentAt),
        ])

        let postProcessor = self.postProcessor
        let appName = run.appNameAtStart
        let runID = run.id
        pendingAccessibilitySummaryRunID = runID
        pendingAccessibilitySummaryTask = Task {
            let startedAt = DispatchTime.now()
            do {
                let summaryContext = try await postProcessor.summarizeAccessibilityContext(
                    model: summaryModel,
                    apiKey: llmKey,
                    appName: appName,
                    sourceText: sourceText,
                    debugRunID: runID,
                    debugRunDirectory: nil
                )
                let responseReceivedAt = Date()
                await MainActor.run {
                    self.logSummaryEvent(.contextSummaryDone, runID: runID, fields: [
                        DebugRunEventField.durationMs.rawValue: self.msString(self.elapsedMs(since: startedAt)),
                        DebugRunEventField.requestSentAtMs.rawValue: self.epochMsString(requestSentAt),
                        DebugRunEventField.responseReceivedAtMs.rawValue: self.epochMsString(responseReceivedAt),
                        "summary_chars": String(summaryContext?.visionSummary?.count ?? 0),
                        "terms_count": String(summaryContext?.visionTerms.count ?? 0),
                    ])
                }
                return summaryContext
            } catch {
                let responseReceivedAt = Date()
                await MainActor.run {
                    self.logSummaryEvent(.contextSummaryFailed, runID: runID, fields: [
                        DebugRunEventField.durationMs.rawValue: self.msString(self.elapsedMs(since: startedAt)),
                        DebugRunEventField.requestSentAtMs.rawValue: self.epochMsString(requestSentAt),
                        DebugRunEventField.responseReceivedAtMs.rawValue: self.epochMsString(responseReceivedAt),
                        DebugRunEventField.error.rawValue: error.localizedDescription,
                    ])
                }
                return nil
            }
        }
    }

    private func takePendingAccessibilitySummaryTask(for runID: String) -> Task<ContextInfo?, Never>? {
        guard pendingAccessibilitySummaryRunID == runID else {
            return nil
        }
        let task = pendingAccessibilitySummaryTask
        pendingAccessibilitySummaryTask = nil
        pendingAccessibilitySummaryRunID = nil
        return task
    }

    private func resolveContextSummaryIfReady(task: Task<ContextInfo?, Never>?) async -> ContextInfo? {
        guard let task else {
            return nil
        }
        return await withTaskGroup(of: ContextInfo?.self, returning: ContextInfo?.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func accessibilitySummarySourceText(context: ContextInfo?) -> String? {
        guard let context else { return nil }
        var blocks: [String] = []

        if let windowText = context.windowText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !windowText.isEmpty
        {
            blocks.append("本文:\n\(windowText)")
        }
        if let focusedText = context.accessibilityText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !focusedText.isEmpty
        {
            blocks.append("選択またはカーソル周辺:\n\(focusedText)")
        }

        guard !blocks.isEmpty else {
            return nil
        }
        return String(blocks.joined(separator: "\n\n").prefix(4000))
    }

    private func logSummaryEvent(_ event: DebugRunEventName, runID: String, fields: [String: String]) {
        devLog(event, runID: runID, fields: fields)
        var payload = fields
        payload["run"] = runID
        if let captureID = captureIDByRunID[runID] {
            debugCaptureService.appendEvent(captureID: captureID, event: event, fields: payload)
            return
        }
        guard pendingAccessibilitySummaryRunID == runID else {
            return
        }
        pendingCaptureEventsByRunID[runID, default: []].append(
            PendingCaptureRunEvent(event: event, fields: payload)
        )
    }

    private func flushPendingCaptureEvents(runID: String, captureID: String) {
        guard let events = pendingCaptureEventsByRunID.removeValue(forKey: runID) else {
            return
        }
        for item in events {
            debugCaptureService.appendEvent(captureID: captureID, event: item.event, fields: item.fields)
        }
    }

    private func clearRunCaptureState(runID: String) {
        captureIDByRunID.removeValue(forKey: runID)
        pendingCaptureEventsByRunID.removeValue(forKey: runID)
    }

    private func pipelineLogger(runID: String, captureID: String?) -> PipelineEventLogger {
        { [weak self] event, fields in
            Task { @MainActor in
                self?.devLog(event, runID: runID, captureID: captureID, fields: fields)
            }
        }
    }

    private func persistDeferredVisionArtifacts(
        task: Task<VisionContextCollectionResult, Never>,
        runID: String,
        captureID: String?
    ) {
        Task { [weak self] in
            guard let self else { return }
            let result = await task.value
            self.debugCaptureService.persistVisionArtifacts(captureID: captureID, result: result)
            self.devLog("vision_artifacts_saved_deferred", runID: runID, captureID: captureID, fields: [
                "mode": result.mode,
                "image_saved": String(result.imageData?.isEmpty == false),
                "image_bytes": String(result.imageBytes),
                "context_present": String(result.context != nil),
                "error": result.error ?? "none",
            ])
        }
    }

    private func devLog(_ event: DebugRunEventName, runID: String, captureID: String? = nil, fields: [String: String] = [:]) {
        devLog(event.rawValue, runID: runID, captureID: captureID, fields: fields)
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
