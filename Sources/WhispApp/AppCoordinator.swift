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
    private let postProcessor: PostProcessorService
    private let sttService: STTService
    private let contextService: ContextService
    private let recordingService: RecordingService
    private let outputService: OutputService
    private let debugCaptureService: DebugCaptureService
    private let settingsWindowController: SettingsWindowController
    private let debugWindowController: DebugWindowController
    private let hotKeyMonitor: GlobalHotKeyMonitor
    private let pipelineRunner: PipelineRunner

    private var stateMachine = PipelineStateMachine()
    private var currentRun: PipelineRun?
    private var recorder: AudioRecorder?
    private var processingTask: Task<Void, Never>?
    private var sttStreamingSession: (any STTStreamingSession)?

    init(config: Config, dependencies: AppDependencies) throws {
        self.config = config
        configStore = dependencies.configStore
        postProcessor = dependencies.postProcessor
        sttService = dependencies.sttService
        contextService = dependencies.contextService
        recordingService = dependencies.recordingService
        outputService = dependencies.outputService
        debugCaptureService = dependencies.debugCaptureService
        hotKeyMonitor = dependencies.hotKeyMonitor
        settingsWindowController = SettingsWindowController()
        debugWindowController = DebugWindowController(store: .shared)
        pipelineRunner = PipelineRunner(
            usageStore: dependencies.usageStore,
            postProcessor: dependencies.postProcessor,
            sttService: dependencies.sttService,
            contextService: dependencies.contextService,
            outputService: dependencies.outputService,
            debugCaptureService: dependencies.debugCaptureService
        )

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
            self?.saveConfig(updated) ?? false
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

    private func saveConfig(_ updated: Config) -> Bool {
        do {
            try configStore.save(updated)
            config = updated
            try registerShortcut()
            return true
        } catch {
            reportError("設定保存に失敗: \(error.localizedDescription)")
            return false
        }
    }

    private func startRecording() {
        let runID = Self.makeRunID()
        let startedAtDate = Date()
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appNameAtStart = frontmostApp?.localizedName
        let appPIDAtStart = frontmostApp?.processIdentifier
        var startedSummaryTask: PipelineAccessibilitySummaryTask?
        do {
            try PreflightValidator.validate(config: config)
            let llmKey = try APIKeyResolver.llmKey(config: config, model: config.llmModel)

            let logger = pipelineLogger(runID: runID, captureID: nil)
            let streamingSession = sttService.startStreamingSessionIfNeeded(
                config: config,
                runID: runID,
                language: LanguageResolver.languageParam(config.inputLanguage),
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
            let run = PipelineRun(
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
        let run = currentRun ?? PipelineRun(
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
                base: DebugRunLogBase(
                    runID: run.id,
                    captureID: captureID,
                    logType: .recording,
                    eventStartMs: Int64((run.startedAtDate.timeIntervalSince1970 * 1000).rounded()),
                    eventEndMs: Int64((stoppedAtDate.timeIntervalSince1970 * 1000).rounded()),
                    recordedAtMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
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
        let input = PipelineRunInput(
            result: result,
            config: snapshot,
            run: run,
            artifacts: artifacts,
            sttStreamingSession: streamingSession,
            accessibilitySummarySourceAtStop: accessibilitySummarySourceAtStop
        )

        processingTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.pipelineRunner.run(context: RunContext(
                input: input,
                transition: { [weak self] event in
                    self?.transition(event)
                },
                notifyWarning: { [weak self] message in
                    self?.notifyError(message)
                }
            ))
            if case let .failed(message, _, _) = outcome {
                self.reportError(message)
                self.transition(.reset)
            }
        }
    }

    private func startAccessibilitySummaryTask(
        sourceText: String?,
        model: LLMModel,
        apiKey: String,
        appName: String?,
        runID: String
    ) -> PipelineAccessibilitySummaryTask? {
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
        return PipelineAccessibilitySummaryTask(
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

    private func transition(_ event: PipelineStateMachine.Event) {
        state = stateMachine.apply(event)
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
        if let captureID, !captureID.isEmpty {
            payload["capture_id"] = captureID
        }
        DevLog.info(event, fields: payload)
        SystemLog.app(event, fields: payload)
    }

    private static func makeRunID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
