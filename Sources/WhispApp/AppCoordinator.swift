import AppKit
import Foundation
import WhispCore

private struct RecordingRun {
    let id: String
    let startedAtDate: Date
    let appNameAtStart: String?
    let appPIDAtStart: Int32?
    let accessibilitySummarySourceAtStart: String?
    let accessibilitySummaryTask: AccessibilitySummaryTask?
    let recordingMode: String
    let model: String
    let sttProvider: String
    let sttStreaming: Bool
    let visionEnabled: Bool
    let accessibilitySummaryStarted: Bool
}

private struct AccessibilitySummaryTask {
    let sourceText: String
    let startedAtDate: Date
    let task: Task<ContextInfo?, Never>
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
        sttService = ProviderSwitchingSTTService()
        contextService = ContextService(
            accessibilityProvider: SystemAccessibilityContextProvider(),
            visionProvider: ScreenVisionContextProvider()
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
        let runID = Self.makeRunID()
        let startedAtDate = Date()
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appNameAtStart = frontmostApp?.localizedName
        let appPIDAtStart = frontmostApp?.processIdentifier
        var startedSummaryTask: AccessibilitySummaryTask?
        do {
            try validateBeforeRecording()
            let llmKey = try llmAPIKey(config: config)

            let logger = pipelineLogger(runID: runID, captureID: nil)
            let streamingSession = sttService.startStreamingSessionIfNeeded(
                config: config,
                runID: runID,
                language: languageParam(config.inputLanguage),
                logger: logger
            )
            sttStreamingSession = streamingSession
            let accessibilityAtStart = contextService.captureAccessibility(frontmostApp: frontmostApp)
            let accessibilitySummarySource = accessibilitySummarySourceText(from: accessibilityAtStart)
            let accessibilitySummaryTask = startAccessibilitySummaryTask(
                sourceText: accessibilitySummarySource,
                model: config.llmModel,
                apiKey: llmKey,
                appName: appNameAtStart,
                runID: runID
            )
            startedSummaryTask = accessibilitySummaryTask
            let run = RecordingRun(
                id: runID,
                startedAtDate: startedAtDate,
                appNameAtStart: appNameAtStart,
                appPIDAtStart: appPIDAtStart,
                accessibilitySummarySourceAtStart: normalizeSummarySource(accessibilitySummarySource),
                accessibilitySummaryTask: accessibilitySummaryTask,
                recordingMode: config.recordingMode.rawValue,
                model: config.llmModel.rawValue,
                sttProvider: config.sttProvider.rawValue,
                sttStreaming: streamingSession != nil,
                visionEnabled: config.context.visionEnabled,
                accessibilitySummaryStarted: accessibilitySummaryTask != nil
            )
            currentRun = run

            let recorder = try recordingService.startRecording(onChunk: { [weak streamingSession] chunk in
                streamingSession?.submit(chunk: chunk)
            })
            self.recorder = recorder
            transition(.startRecording)
            devLog("recording_start", runID: run.id, fields: [
                "mode": run.recordingMode,
                "model": run.model,
                "stt_provider": run.sttProvider,
                "vision_enabled": String(run.visionEnabled),
                "stt_streaming": String(run.sttStreaming),
                "accessibility_summary_started": String(run.accessibilitySummaryStarted),
                "log_file": DevLog.filePath ?? "n/a",
                "recording_started_at_ms": epochMsString(startedAtDate),
            ])
            _ = outputService.playStartSound()
        } catch {
            (currentRun?.accessibilitySummaryTask ?? startedSummaryTask)?.task.cancel()
            currentRun = nil
            sttStreamingSession = nil
            reportError("録音開始に失敗: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        let run = currentRun ?? RecordingRun(
            id: Self.makeRunID(),
            startedAtDate: Date(),
            appNameAtStart: nil,
            appPIDAtStart: nil,
            accessibilitySummarySourceAtStart: nil,
            accessibilitySummaryTask: nil,
            recordingMode: config.recordingMode.rawValue,
            model: config.llmModel.rawValue,
            sttProvider: config.sttProvider.rawValue,
            sttStreaming: sttStreamingSession != nil,
            visionEnabled: config.context.visionEnabled,
            accessibilitySummaryStarted: false
        )
        currentRun = nil

        let result = recordingService.stopRecording(recorder)
        let stoppedAtDate = Date()
        self.recorder = nil
        transition(.stopRecording)

        let recordingStopFields: [String: String] = [
            "pcm_bytes": String(result.pcmData.count),
            "sample_rate": String(result.sampleRate),
            "recording_stopped_at_ms": epochMsString(stoppedAtDate),
        ]
        devLog("recording_stop", runID: run.id, fields: recordingStopFields)

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let accessibility = contextService.captureAccessibility(frontmostApp: frontmostApp)
        let accessibilitySummarySourceAtStop = normalizeSummarySource(accessibilitySummarySourceText(from: accessibility))
        let artifacts = debugCaptureService.saveRecording(
            runID: run.id,
            recording: result,
            config: config,
            frontmostApp: frontmostApp,
            accessibility: accessibility
        )

        if let captureID = artifacts.captureID {
            let recordingLog = DebugRunLog.recording(DebugRecordingLog(
                base: makeLogBase(
                    runID: run.id,
                    captureID: captureID,
                    logType: .recording,
                    eventStartMs: epochMs(run.startedAtDate),
                    eventEndMs: epochMs(stoppedAtDate),
                    status: .ok
                ),
                mode: run.recordingMode,
                model: run.model,
                sttProvider: run.sttProvider,
                sttStreaming: run.sttStreaming,
                visionEnabled: run.visionEnabled,
                accessibilitySummaryStarted: run.accessibilitySummaryStarted,
                sampleRate: result.sampleRate,
                pcmBytes: result.pcmData.count
            ))
            debugCaptureService.appendLog(captureID: captureID, log: recordingLog)
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
                sttStreamingSession: streamingSession,
                accessibilitySummarySourceAtStop: accessibilitySummarySourceAtStop
            )
        }
    }

    private func processRecording(
        result: RecordingResult,
        config: Config,
        run: RecordingRun,
        artifacts: DebugRunArtifacts,
        sttStreamingSession: (any STTStreamingSession)?,
        accessibilitySummarySourceAtStop: String?
    ) async {
        let pipelineStartedAtDate = Date()
        let pipelineStartedAtMs = epochMs(pipelineStartedAtDate)
        let captureID = artifacts.captureID
        let debugRunDirectory = artifacts.runDirectory
        let accessibilityContext = artifacts.accessibilityContext
        let logger = pipelineLogger(runID: run.id, captureID: captureID)
        devLog("pipeline_start", runID: run.id, captureID: captureID, fields: [
            "request_sent_at_ms": epochMsString(pipelineStartedAtDate),
        ])

        let shouldApplyAccessibilitySummary = shouldApplyAccessibilitySummary(
            startSource: run.accessibilitySummarySourceAtStart,
            stopSource: accessibilitySummarySourceAtStop
        )
        let summaryTask = run.accessibilitySummaryTask
        var contextSummaryLog: DebugRunLog?
        var accessibilitySummary: ContextInfo?
        if let summaryTask, !shouldApplyAccessibilitySummary {
            summaryTask.task.cancel()
            if let captureID {
                contextSummaryLog = makeContextSummaryLog(
                    run: run,
                    captureID: captureID,
                    task: summaryTask,
                    endedAt: Date(),
                    status: .cancelled,
                    summary: nil,
                    error: "source_changed"
                )
            }
        }

        var debugSTTText: String?
        var debugOutputText: String?
        var sttLog: DebugRunLog?
        var visionLog: DebugRunLog?
        var postProcessLog: DebugRunLog?
        var directInputLog: DebugRunLog?
        var sttChars = 0
        var outputChars = 0

        do {
            guard !result.pcmData.isEmpty else {
                if let summaryTask, shouldApplyAccessibilitySummary, contextSummaryLog == nil {
                    summaryTask.task.cancel()
                    if let captureID {
                        contextSummaryLog = makeContextSummaryLog(
                            run: run,
                            captureID: captureID,
                            task: summaryTask,
                            endedAt: Date(),
                            status: .cancelled,
                            summary: nil,
                            error: "cancelled_empty_audio"
                        )
                    }
                }
                debugCaptureService.updateResult(
                    captureID: captureID,
                    sttText: nil,
                    outputText: nil,
                    status: "skipped_empty_audio"
                )
                devLog("pipeline_skip_empty_audio", runID: run.id, captureID: captureID)
                if let captureID {
                    appendStructuredLogs(captureID: captureID, logs: [contextSummaryLog])
                    let cancelledPipeline = DebugRunLog.pipeline(DebugPipelineLog(
                        base: makeLogBase(
                            runID: run.id,
                            captureID: captureID,
                            logType: .pipeline,
                            eventStartMs: pipelineStartedAtMs,
                            eventEndMs: epochMs(),
                            status: .cancelled
                        ),
                        sttChars: 0,
                        outputChars: 0,
                        error: nil
                    ))
                    debugCaptureService.appendLog(captureID: captureID, log: cancelledPipeline)
                }
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
                if let summaryTask, shouldApplyAccessibilitySummary, contextSummaryLog == nil {
                    let summaryResolution = await resolveAccessibilitySummaryIfReady(task: summaryTask.task)
                    if summaryResolution.ready {
                        accessibilitySummary = summaryResolution.summary
                        if let captureID {
                            let status: DebugLogStatus = accessibilitySummary == nil ? .error : .ok
                            contextSummaryLog = makeContextSummaryLog(
                                run: run,
                                captureID: captureID,
                                task: summaryTask,
                                endedAt: Date(),
                                status: status,
                                summary: accessibilitySummary,
                                error: accessibilitySummary == nil ? "summary_unavailable" : nil
                            )
                        }
                    } else {
                        summaryTask.task.cancel()
                        if let captureID {
                            contextSummaryLog = makeContextSummaryLog(
                                run: run,
                                captureID: captureID,
                                task: summaryTask,
                                endedAt: Date(),
                                status: .cancelled,
                                summary: nil,
                                error: "cancelled_audio_llm_start"
                            )
                        }
                    }
                }
                let context = applyAccessibilitySummary(
                    base: accessibilityContext,
                    summary: accessibilitySummary
                )
                let llmStartedAtDate = Date()
                let llmStartedAtMs = epochMs(llmStartedAtDate)
                devLog("audio_llm_start", runID: run.id, captureID: captureID, fields: [
                    "pcm_bytes": String(result.pcmData.count),
                    "context_present": String(context != nil),
                    "request_sent_at_ms": epochMsString(llmStartedAtDate),
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
                let llmResponseAt = Date()
                let llmResponseAtMs = epochMs(llmResponseAt)
                devLog("audio_llm_done", runID: run.id, captureID: captureID, fields: [
                    "output_chars": String(transcription.text.count),
                    "response_received_at_ms": epochMsString(llmResponseAt),
                ])
                processedText = transcription.text
                sttText = transcription.text
                llmUsage = transcription.usage
                sttChars = sttText.count
                outputChars = processedText.count
                if let captureID {
                    postProcessLog = .postprocess(DebugPostProcessLog(
                        base: makeLogBase(
                            runID: run.id,
                            captureID: captureID,
                            logType: .postprocess,
                            eventStartMs: llmStartedAtMs,
                            eventEndMs: llmResponseAtMs,
                            status: .ok
                        ),
                        model: config.llmModel.rawValue,
                        contextPresent: context != nil,
                        sttChars: 0,
                        outputChars: processedText.count,
                        kind: .audioTranscribe
                    ))
                }
            } else {
                let llmKey = try llmAPIKey(config: config)
                let visionStartedAtDate = Date()
                let visionTask = contextService.startVisionCollection(
                    config: config,
                    runID: run.id,
                    preferredWindowOwnerPID: run.appPIDAtStart,
                    runDirectory: debugRunDirectory,
                    logger: logger
                )
                if visionTask == nil, let captureID {
                    let now = Date()
                    visionLog = .vision(DebugVisionLog(
                        base: makeLogBase(
                            runID: run.id,
                            captureID: captureID,
                            logType: .vision,
                            eventStartMs: epochMs(visionStartedAtDate),
                            eventEndMs: epochMs(now),
                            status: .cancelled
                        ),
                        model: config.llmModel.rawValue,
                        mode: config.context.visionMode.rawValue,
                        contextPresent: false,
                        imageBytes: 0,
                        imageWidth: 0,
                        imageHeight: 0,
                        error: "vision_disabled"
                    ))
                }

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
                sttChars = sttText.count
                if let captureID {
                    sttLog = .stt(DebugSTTLog(
                        base: makeLogBase(
                            runID: run.id,
                            captureID: captureID,
                            logType: .stt,
                            eventStartMs: stt.trace.mainSpan.eventStartMs,
                            eventEndMs: stt.trace.mainSpan.eventEndMs,
                            status: stt.trace.mainSpan.status
                        ),
                        provider: stt.trace.provider,
                        route: stt.trace.route,
                        source: stt.trace.mainSpan.source,
                        textChars: stt.trace.mainSpan.textChars,
                        sampleRate: stt.trace.mainSpan.sampleRate,
                        audioBytes: stt.trace.mainSpan.audioBytes,
                        attempts: stt.trace.attempts
                    ))
                }
                if let summaryTask, shouldApplyAccessibilitySummary, contextSummaryLog == nil {
                    let summaryResolution = await resolveAccessibilitySummaryIfReady(task: summaryTask.task)
                    if summaryResolution.ready {
                        accessibilitySummary = summaryResolution.summary
                        if let captureID {
                            let status: DebugLogStatus = accessibilitySummary == nil ? .error : .ok
                            contextSummaryLog = makeContextSummaryLog(
                                run: run,
                                captureID: captureID,
                                task: summaryTask,
                                endedAt: Date(),
                                status: status,
                                summary: accessibilitySummary,
                                error: accessibilitySummary == nil ? "summary_unavailable" : nil
                            )
                        }
                    } else {
                        summaryTask.task.cancel()
                        if let captureID {
                            contextSummaryLog = makeContextSummaryLog(
                                run: run,
                                captureID: captureID,
                                task: summaryTask,
                                endedAt: Date(),
                                status: .cancelled,
                                summary: nil,
                                error: "cancelled_stt_done"
                            )
                        }
                    }
                }

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
                    devLog("pipeline_skip_empty_stt", runID: run.id, captureID: captureID)
                    if let captureID {
                        if visionTask != nil, visionLog == nil {
                            let cancelledAt = Date()
                            visionLog = .vision(DebugVisionLog(
                                base: makeLogBase(
                                    runID: run.id,
                                    captureID: captureID,
                                    logType: .vision,
                                    eventStartMs: epochMs(visionStartedAtDate),
                                    eventEndMs: epochMs(cancelledAt),
                                    status: .cancelled
                                ),
                                model: config.llmModel.rawValue,
                                mode: config.context.visionMode.rawValue,
                                contextPresent: false,
                                imageBytes: 0,
                                imageWidth: 0,
                                imageHeight: 0,
                                error: "cancelled_empty_stt"
                            ))
                        }
                        appendStructuredLogs(captureID: captureID, logs: [contextSummaryLog, sttLog, visionLog])
                        let cancelledPipeline = DebugRunLog.pipeline(DebugPipelineLog(
                            base: makeLogBase(
                                runID: run.id,
                                captureID: captureID,
                                logType: .pipeline,
                                eventStartMs: pipelineStartedAtMs,
                                eventEndMs: epochMs(),
                                status: .cancelled
                            ),
                            sttChars: sttChars,
                            outputChars: 0,
                            error: nil
                        ))
                        debugCaptureService.appendLog(captureID: captureID, log: cancelledPipeline)
                    }
                    transition(.reset)
                    return
                }

                transition(.startPostProcessing)
                let appName = run.appNameAtStart ?? NSWorkspace.shared.frontmostApplication?.localizedName
                let visionResult = await contextService.resolveVisionIfReady(task: visionTask, logger: logger)
                debugCaptureService.persistVisionArtifacts(captureID: captureID, result: visionResult)
                if visionResult == nil, let visionTask {
                    persistDeferredVisionArtifacts(task: visionTask, runID: run.id, captureID: captureID)
                }
                if let captureID, visionLog == nil, let visionResult {
                    let visionCompletedAt = Date()
                    visionLog = .vision(DebugVisionLog(
                        base: makeLogBase(
                            runID: run.id,
                            captureID: captureID,
                            logType: .vision,
                            eventStartMs: epochMs(visionStartedAtDate),
                            eventEndMs: epochMs(visionCompletedAt),
                            status: visionResult.error == nil ? .ok : .error
                        ),
                        model: config.llmModel.rawValue,
                        mode: visionResult.mode,
                        contextPresent: visionResult.context != nil,
                        imageBytes: visionResult.imageBytes,
                        imageWidth: visionResult.imageWidth,
                        imageHeight: visionResult.imageHeight,
                        error: visionResult.error
                    ))
                }
                let composedContext = contextService.compose(accessibility: accessibilityContext, vision: visionResult?.context)
                let context = applyAccessibilitySummary(
                    base: composedContext,
                    summary: accessibilitySummary
                )

                let llmStartedAtDate = Date()
                let llmStartedAtMs = epochMs(llmStartedAtDate)
                devLog("postprocess_start", runID: run.id, captureID: captureID, fields: [
                    "model": config.llmModel.rawValue,
                    "context_present": String(context != nil),
                    "stt_chars": String(sttText.count),
                    "request_sent_at_ms": epochMsString(llmStartedAtDate),
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
                let llmResponseAt = Date()
                let llmResponseAtMs = epochMs(llmResponseAt)
                devLog("postprocess_done", runID: run.id, captureID: captureID, fields: [
                    "output_chars": String(postProcessed.text.count),
                    "response_received_at_ms": epochMsString(llmResponseAt),
                ])

                processedText = postProcessed.text
                llmUsage = postProcessed.usage
                outputChars = processedText.count
                if let captureID {
                    postProcessLog = .postprocess(DebugPostProcessLog(
                        base: makeLogBase(
                            runID: run.id,
                            captureID: captureID,
                            logType: .postprocess,
                            eventStartMs: llmStartedAtMs,
                            eventEndMs: llmResponseAtMs,
                            status: .ok
                        ),
                        model: config.llmModel.rawValue,
                        contextPresent: context != nil,
                        sttChars: sttText.count,
                        outputChars: postProcessed.text.count,
                        kind: .textPostprocess
                    ))
                }
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
                if let captureID {
                    appendStructuredLogs(captureID: captureID, logs: [contextSummaryLog, sttLog, visionLog, postProcessLog])
                    let cancelledPipeline = DebugRunLog.pipeline(DebugPipelineLog(
                        base: makeLogBase(
                            runID: run.id,
                            captureID: captureID,
                            logType: .pipeline,
                            eventStartMs: pipelineStartedAtMs,
                            eventEndMs: epochMs(),
                            status: .cancelled
                        ),
                        sttChars: sttChars,
                        outputChars: outputChars,
                        error: nil
                    ))
                    debugCaptureService.appendLog(captureID: captureID, log: cancelledPipeline)
                }
                transition(.reset)
                return
            }

            transition(.startDirectInput)
            let inputStartedAtDate = Date()
            let inputStartedAtMs = epochMs(inputStartedAtDate)
            devLog("direct_input_start", runID: run.id, captureID: captureID, fields: [
                "request_sent_at_ms": epochMsString(inputStartedAtDate),
            ])
            let directInputOK = outputService.sendText(processedText)
            let inputDoneAtDate = Date()
            let inputDoneAtMs = epochMs(inputDoneAtDate)
            devLog("direct_input_done", runID: run.id, captureID: captureID, fields: [
                "success": String(directInputOK),
                "output_chars": String(processedText.count),
                "response_received_at_ms": epochMsString(inputDoneAtDate),
            ])
            if let captureID {
                directInputLog = .directInput(DebugDirectInputLog(
                    base: makeLogBase(
                        runID: run.id,
                        captureID: captureID,
                        logType: .directInput,
                        eventStartMs: inputStartedAtMs,
                        eventEndMs: inputDoneAtMs,
                        status: directInputOK ? .ok : .error
                    ),
                    success: directInputOK,
                    outputChars: processedText.count
                ))
            }
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

            let pipelineDoneAtDate = Date()
            let pipelineDoneAtMs = epochMs(pipelineDoneAtDate)
            devLog("pipeline_done", runID: run.id, captureID: captureID, fields: [
                "stt_chars": String(sttText.count),
                "output_chars": String(processedText.count),
                "response_received_at_ms": epochMsString(pipelineDoneAtDate),
            ])
            if let captureID {
                appendStructuredLogs(captureID: captureID, logs: [contextSummaryLog, sttLog, visionLog, postProcessLog, directInputLog])
                let pipelineLog = DebugRunLog.pipeline(DebugPipelineLog(
                    base: makeLogBase(
                        runID: run.id,
                        captureID: captureID,
                        logType: .pipeline,
                        eventStartMs: pipelineStartedAtMs,
                        eventEndMs: pipelineDoneAtMs,
                        status: directInputOK ? .ok : .error
                    ),
                    sttChars: sttChars,
                    outputChars: outputChars,
                    error: directInputOK ? nil : "direct_input_failed"
                ))
                debugCaptureService.appendLog(captureID: captureID, log: pipelineLog)
            }
            print("[pipeline] stt chars=\(sttText.count), output chars=\(processedText.count)")
        } catch {
            if let summaryTask, shouldApplyAccessibilitySummary, contextSummaryLog == nil {
                summaryTask.task.cancel()
                if let captureID {
                    contextSummaryLog = makeContextSummaryLog(
                        run: run,
                        captureID: captureID,
                        task: summaryTask,
                        endedAt: Date(),
                        status: .cancelled,
                        summary: nil,
                        error: "cancelled_pipeline_error"
                    )
                }
            }
            debugCaptureService.updateResult(
                captureID: captureID,
                sttText: debugSTTText,
                outputText: debugOutputText,
                status: "error",
                errorMessage: error.localizedDescription
            )
            let pipelineErrorAt = Date()
            devLog("pipeline_error", runID: run.id, captureID: captureID, fields: [
                "error": error.localizedDescription,
                "response_received_at_ms": epochMsString(pipelineErrorAt),
            ])
            if let captureID {
                appendStructuredLogs(captureID: captureID, logs: [contextSummaryLog, sttLog, visionLog, postProcessLog, directInputLog])
                let pipelineLog = DebugRunLog.pipeline(DebugPipelineLog(
                    base: makeLogBase(
                        runID: run.id,
                        captureID: captureID,
                        logType: .pipeline,
                        eventStartMs: pipelineStartedAtMs,
                        eventEndMs: epochMs(pipelineErrorAt),
                        status: .error
                    ),
                    sttChars: sttChars,
                    outputChars: outputChars,
                    error: error.localizedDescription
                ))
                debugCaptureService.appendLog(captureID: captureID, log: pipelineLog)
            }
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

    private func epochMsString(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSince1970 * 1000)
    }

    private func epochMs(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func pipelineLogger(runID: String, captureID: String?) -> PipelineEventLogger {
        { [weak self] event, fields in
            Task { @MainActor in
                self?.devLog(event, runID: runID, captureID: captureID, fields: fields)
            }
        }
    }

    private func startAccessibilitySummaryTask(
        sourceText: String?,
        model: LLMModel,
        apiKey: String,
        appName: String?,
        runID: String
    ) -> AccessibilitySummaryTask? {
        guard let sourceText = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceText.isEmpty else {
            return nil
        }

        let startedAtDate = Date()
        let postProcessor = postProcessor
        let task = Task {
            do {
                return try await postProcessor.summarizeAccessibilityContext(
                    model: model,
                    apiKey: apiKey,
                    appName: appName,
                    sourceText: sourceText,
                    debugRunID: runID,
                    debugRunDirectory: nil
                )
            } catch {
                return nil
            }
        }
        return AccessibilitySummaryTask(
            sourceText: sourceText,
            startedAtDate: startedAtDate,
            task: task
        )
    }

    private func accessibilitySummarySourceText(from capture: AccessibilityContextCapture?) -> String? {
        if let text = capture?.snapshot.windowText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return String(text.suffix(1000))
        }
        if let text = capture?.context?.windowText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return String(text.suffix(1000))
        }
        return nil
    }

    private func normalizeSummarySource(_ source: String?) -> String? {
        guard let source else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }

    private func shouldApplyAccessibilitySummary(startSource: String?, stopSource: String?) -> Bool {
        guard let startSource, let stopSource else { return false }
        return startSource == stopSource
    }

    private func applyAccessibilitySummary(base: ContextInfo?, summary: ContextInfo?) -> ContextInfo? {
        guard let summary else { return base }
        let summaryText = summary.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryTerms = summary.visionTerms

        if var merged = base {
            if let summaryText, !summaryText.isEmpty {
                let existing = merged.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
                merged.visionSummary = mergeSummaryTexts(existing, summaryText)
            }
            if !summaryTerms.isEmpty {
                merged.visionTerms = mergeTerms(merged.visionTerms, summaryTerms)
            }
            return merged
        }

        guard (summaryText?.isEmpty == false) || !summaryTerms.isEmpty else {
            return nil
        }
        return ContextInfo(
            visionSummary: summaryText,
            visionTerms: summaryTerms
        )
    }

    private func mergeSummaryTexts(_ base: String?, _ addition: String) -> String {
        guard let base = base, !base.isEmpty else { return addition }
        if base == addition {
            return base
        }
        return "\(base) / \(addition)"
    }

    private func mergeTerms(_ base: [String], _ addition: [String]) -> [String] {
        var seen = Set(base)
        var merged = base
        for term in addition where !term.isEmpty {
            if seen.insert(term).inserted {
                merged.append(term)
            }
        }
        return merged
    }

    private func devLog(_ event: String, runID: String, captureID: String? = nil, fields: [String: String] = [:]) {
        var payload = fields
        payload["run"] = runID
        if let captureID, !captureID.isEmpty {
            payload["capture_id"] = captureID
        }
        DevLog.info(event, fields: payload)
        SystemLog.app(event, fields: payload)
    }

    private func makeContextSummaryLog(
        run: RecordingRun,
        captureID: String,
        task: AccessibilitySummaryTask,
        endedAt: Date,
        status: DebugLogStatus,
        summary: ContextInfo?,
        error: String?
    ) -> DebugRunLog {
        .contextSummary(DebugContextSummaryLog(
            base: makeLogBase(
                runID: run.id,
                captureID: captureID,
                logType: .contextSummary,
                eventStartMs: epochMs(task.startedAtDate),
                eventEndMs: epochMs(endedAt),
                status: status
            ),
            source: "accessibility",
            appName: run.appNameAtStart,
            sourceChars: task.sourceText.count,
            summaryChars: summary?.visionSummary?.count ?? 0,
            termsCount: summary?.visionTerms.count ?? 0,
            error: error
        ))
    }

    private func resolveAccessibilitySummaryIfReady(task: Task<ContextInfo?, Never>) async -> (ready: Bool, summary: ContextInfo?) {
        await withTaskGroup(of: (Bool, ContextInfo?).self, returning: (Bool, ContextInfo?).self) { group in
            group.addTask {
                (true, await task.value)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000)
                return (false, nil)
            }
            let first = await group.next() ?? (false, nil)
            group.cancelAll()
            return first
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
                "context_present": String(result.context != nil),
                "mode": result.mode,
                "error": result.error ?? "none",
            ])
        }
    }

    private func makeLogBase(
        runID: String,
        captureID: String?,
        logType: DebugLogType,
        eventStartMs: Int64,
        eventEndMs: Int64,
        status: DebugLogStatus
    ) -> DebugRunLogBase {
        DebugRunLogBase(
            runID: runID,
            captureID: captureID,
            logType: logType,
            eventStartMs: eventStartMs,
            eventEndMs: eventEndMs,
            recordedAtMs: epochMs(),
            status: status
        )
    }

    private func appendStructuredLogs(captureID: String, logs: [DebugRunLog?]) {
        for log in logs.compactMap({ $0 }) {
            debugCaptureService.appendLog(captureID: captureID, log: log)
        }
    }

    private static func makeRunID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
