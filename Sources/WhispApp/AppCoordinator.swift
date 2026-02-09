import AppKit
import Foundation
import WhispCore

private struct RecordingRun {
    let id: String
    let startedAt: DispatchTime
}

private struct VisionContextTaskResult {
    let context: ContextInfo?
    let captureMs: Double
    let analyzeMs: Double
    let totalMs: Double
    let imageData: Data?
    let imageMimeType: String?
    let imageBytes: Int
    let imageWidth: Int
    let imageHeight: Int
    let error: String?
}

private final class StreamChunkTracker: @unchecked Sendable {
    struct DrainStats {
        let submittedChunks: Int
        let submittedBytes: Int
        let droppedChunks: Int
    }

    private let lock = NSLock()
    private var pendingTasks: [Task<Void, Never>] = []
    private var closed = false
    private var submittedChunks = 0
    private var submittedBytes = 0
    private var droppedChunks = 0

    func submit(chunk: Data, stream: DeepgramStreamingClient) {
        guard !chunk.isEmpty else { return }

        lock.lock()
        if closed {
            droppedChunks += 1
            lock.unlock()
            return
        }
        submittedChunks += 1
        submittedBytes += chunk.count
        let task = Task {
            await stream.enqueueAudioChunk(chunk)
        }
        pendingTasks.append(task)
        lock.unlock()
    }

    func close() -> [Task<Void, Never>] {
        lock.lock()
        closed = true
        let tasks = pendingTasks
        pendingTasks.removeAll(keepingCapacity: false)
        lock.unlock()
        return tasks
    }

    func stats() -> DrainStats {
        lock.lock()
        let stats = DrainStats(
            submittedChunks: submittedChunks,
            submittedBytes: submittedBytes,
            droppedChunks: droppedChunks
        )
        lock.unlock()
        return stats
    }
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
    private let deepgramClient: DeepgramClient
    private let postProcessor: PostProcessorService
    private let settingsWindowController: SettingsWindowController
    private let debugWindowController: DebugWindowController
    private let hotKeyMonitor: GlobalHotKeyMonitor
    private let debugCaptureStore: DebugCaptureStore

    private var currentRun: RecordingRun?
    private var recorder: AudioRecorder?
    private var processingTask: Task<Void, Never>?
    private var deepgramStream: DeepgramStreamingClient?
    private var streamChunkTracker: StreamChunkTracker?
    private var debugCaptureIDsByRun: [String: String] = [:]

    init() throws {
        configStore = try ConfigStore()
        usageStore = try UsageStore()
        config = try configStore.loadOrCreate()

        deepgramClient = DeepgramClient()
        postProcessor = PostProcessorService()
        settingsWindowController = SettingsWindowController()
        debugCaptureStore = .shared
        debugWindowController = DebugWindowController(store: debugCaptureStore)
        hotKeyMonitor = try GlobalHotKeyMonitor()

        try registerShortcut()
    }

    deinit {
        processingTask?.cancel()
        deepgramStream = nil
        streamChunkTracker = nil
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
        let run = RecordingRun(id: Self.makeRunID(), startedAt: .now())
        currentRun = run
        do {
            try validateBeforeRecording()
            let stream = prepareDeepgramStreamIfNeeded(config: config, runID: run.id)
            deepgramStream = stream
            let chunkTracker = stream.map { _ in StreamChunkTracker() }
            streamChunkTracker = chunkTracker
            let recorder = AudioRecorder(onChunk: { [weak stream, weak chunkTracker] chunk in
                guard let stream, let chunkTracker else { return }
                chunkTracker.submit(chunk: chunk, stream: stream)
            })
            try recorder.start()
            self.recorder = recorder
            state = .recording
            devLog("recording_start", runID: run.id, fields: [
                "mode": config.recordingMode.rawValue,
                "model": config.llmModel.rawValue,
                "vision_enabled": String(config.context.visionEnabled),
                "stt_streaming": String(stream != nil),
                "log_file": DevLog.filePath ?? "n/a",
            ])
            _ = playStartSound()
        } catch {
            currentRun = nil
            deepgramStream = nil
            streamChunkTracker = nil
            reportError("録音開始に失敗: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        let run = currentRun ?? RecordingRun(id: Self.makeRunID(), startedAt: .now())
        currentRun = nil

        let result = recorder.stop()
        self.recorder = nil
        state = .sttStreaming

        let recordingMs = elapsedMs(since: run.startedAt)
        devLog("recording_stop", runID: run.id, fields: [
            "recording_ms": msString(recordingMs),
            "pcm_bytes": String(result.pcmData.count),
            "sample_rate": String(result.sampleRate),
        ])
        saveDebugRecording(result: result, config: config, runID: run.id)

        let snapshot = config
        let stream = deepgramStream
        let chunkTracker = streamChunkTracker
        deepgramStream = nil
        streamChunkTracker = nil
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.processRecording(
                result: result,
                config: snapshot,
                run: run,
                stream: stream,
                chunkTracker: chunkTracker
            )
        }
    }

    private func processRecording(
        result: RecordingResult,
        config: Config,
        run: RecordingRun,
        stream: DeepgramStreamingClient?,
        chunkTracker: StreamChunkTracker?
    ) async {
        let pipelineStartedAt = DispatchTime.now()
        let captureID = debugCaptureIDsByRun[run.id]
        defer {
            debugCaptureIDsByRun.removeValue(forKey: run.id)
        }

        var debugSTTText: String?
        var debugOutputText: String?

        do {
            guard !result.pcmData.isEmpty else {
                updateDebugCapture(
                    captureID: captureID,
                    sttText: nil,
                    outputText: nil,
                    status: "skipped_empty_audio"
                )
                devLog("pipeline_skip_empty_audio", runID: run.id)
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
                let llmStartedAt = DispatchTime.now()
                devLog("audio_llm_start", runID: run.id, fields: [
                    "pcm_bytes": String(result.pcmData.count),
                    "context_present": String(false),
                ])
                let transcription = try await postProcessor.transcribeAudioGemini(
                    apiKey: key,
                    wavData: wav,
                    mimeType: "audio/wav",
                    context: nil,
                    debugRunID: run.id
                )
                devLog("audio_llm_done", runID: run.id, fields: [
                    "duration_ms": msString(elapsedMs(since: llmStartedAt)),
                    "output_chars": String(transcription.text.count),
                ])
                processedText = transcription.text
                sttText = transcription.text
                llmUsage = transcription.usage
            } else {
                let deepgramKey = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
                if deepgramKey.isEmpty {
                    throw AppError.invalidArgument("Deepgram APIキーが未設定です")
                }
                let visionTask = startVisionContextCollection(config: config, runID: run.id)

                let stt: (transcript: String, usage: STTUsage?)
                if let stream {
                    if let chunkTracker {
                        let drainStartedAt = DispatchTime.now()
                        let tasks = chunkTracker.close()
                        for task in tasks {
                            await task.value
                        }
                        let stats = chunkTracker.stats()
                        let drainMs = elapsedMs(since: drainStartedAt)
                        devLog("stt_stream_chunks_drained", runID: run.id, fields: [
                            "duration_ms": msString(drainMs),
                            "submitted_chunks": String(stats.submittedChunks),
                            "submitted_bytes": String(stats.submittedBytes),
                            "dropped_chunks": String(stats.droppedChunks),
                        ])
                        SystemLog.stt("app_stream_chunks_drained", fields: [
                            "run": run.id,
                            "duration_ms": msString(drainMs),
                            "submitted_chunks": String(stats.submittedChunks),
                            "submitted_bytes": String(stats.submittedBytes),
                            "dropped_chunks": String(stats.droppedChunks),
                        ])
                    }
                    let streamFinalizeStartedAt = DispatchTime.now()
                    devLog("stt_stream_finalize_start", runID: run.id)
                    do {
                        stt = try await stream.finish()
                        devLog("stt_stream_finalize_done", runID: run.id, fields: [
                            "duration_ms": msString(elapsedMs(since: streamFinalizeStartedAt)),
                            "text_chars": String(stt.transcript.count),
                        ])
                    } catch {
                        devLog("stt_stream_failed_fallback_rest", runID: run.id, fields: [
                            "error": error.localizedDescription,
                        ])
                        let sttStartedAt = DispatchTime.now()
                        stt = try await deepgramClient.transcribe(
                            apiKey: deepgramKey,
                            sampleRate: result.sampleRate,
                            audio: result.pcmData,
                            language: languageParam(config.inputLanguage)
                        )
                        devLog("stt_done", runID: run.id, fields: [
                            "source": "rest_fallback",
                            "duration_ms": msString(elapsedMs(since: sttStartedAt)),
                            "text_chars": String(stt.transcript.count),
                        ])
                    }
                } else {
                    let sttStartedAt = DispatchTime.now()
                    devLog("stt_start", runID: run.id, fields: [
                        "sample_rate": String(result.sampleRate),
                        "audio_bytes": String(result.pcmData.count),
                    ])
                    stt = try await deepgramClient.transcribe(
                        apiKey: deepgramKey,
                        sampleRate: result.sampleRate,
                        audio: result.pcmData,
                        language: languageParam(config.inputLanguage)
                    )
                    devLog("stt_done", runID: run.id, fields: [
                        "source": "rest",
                        "duration_ms": msString(elapsedMs(since: sttStartedAt)),
                        "text_chars": String(stt.transcript.count),
                    ])
                }

                sttText = stt.transcript
                sttUsage = stt.usage

                if isEmptySTT(sttText) {
                    visionTask?.cancel()
                    usageStore.recordUsage(stt: sttUsage, llm: nil)
                    debugSTTText = sttText
                    updateDebugCapture(
                        captureID: captureID,
                        sttText: debugSTTText,
                        outputText: nil,
                        status: "skipped_empty_stt"
                    )
                    devLog("pipeline_skip_empty_stt", runID: run.id, fields: [
                        "stt_ms": msString(elapsedMs(since: pipelineStartedAt)),
                    ])
                    state = .idle
                    return
                }

                state = .postProcessing
                let appName = NSWorkspace.shared.frontmostApplication?.localizedName
                let key = try llmAPIKey(config: config)
                let visionResult = await resolveVisionContextIfReady(from: visionTask, runID: run.id)
                persistVisionArtifacts(captureID: captureID, result: visionResult)
                let context = visionResult?.context
                let llmStartedAt = DispatchTime.now()
                devLog("postprocess_start", runID: run.id, fields: [
                    "model": config.llmModel.rawValue,
                    "context_present": String(context != nil),
                    "stt_chars": String(sttText.count),
                ])
                let result = try await postProcessor.postProcess(
                    model: config.llmModel,
                    apiKey: key,
                    sttResult: sttText,
                    languageHint: config.inputLanguage,
                    appName: appName,
                    appPromptRules: config.appPromptRules,
                    context: context,
                    debugRunID: run.id
                )
                devLog("postprocess_done", runID: run.id, fields: [
                    "duration_ms": msString(elapsedMs(since: llmStartedAt)),
                    "output_chars": String(result.text.count),
                ])

                processedText = result.text
                llmUsage = result.usage
            }

            debugSTTText = sttText
            debugOutputText = processedText
            usageStore.recordUsage(stt: sttUsage, llm: llmUsage)

            if isEmptySTT(processedText) {
                updateDebugCapture(
                    captureID: captureID,
                    sttText: debugSTTText,
                    outputText: debugOutputText,
                    status: "skipped_empty_output"
                )
                devLog("pipeline_skip_empty_output", runID: run.id)
                state = .idle
                return
            }

            state = .directInput
            let inputStartedAt = DispatchTime.now()
            let directInputOK = DirectInput.sendText(processedText)
            devLog("direct_input_done", runID: run.id, fields: [
                "duration_ms": msString(elapsedMs(since: inputStartedAt)),
                "success": String(directInputOK),
                "output_chars": String(processedText.count),
            ])
            updateDebugCapture(
                captureID: captureID,
                sttText: debugSTTText,
                outputText: debugOutputText,
                status: directInputOK ? "done" : "done_input_failed"
            )
            if !directInputOK {
                reportError("直接入力に失敗しました。アクセシビリティ権限を確認してください。")
            }

            _ = playCompletionSound()
            state = .done

            try? await Task.sleep(nanoseconds: 100_000_000)
            state = .idle

            let pipelineMs = elapsedMs(since: pipelineStartedAt)
            let endToEndMs = elapsedMs(since: run.startedAt)
            devLog("pipeline_done", runID: run.id, fields: [
                "pipeline_ms": msString(pipelineMs),
                "end_to_end_ms": msString(endToEndMs),
                "stt_chars": String(sttText.count),
                "output_chars": String(processedText.count),
            ])
            print("[pipeline] stt chars=\(sttText.count), output chars=\(processedText.count)")
        } catch {
            updateDebugCapture(
                captureID: captureID,
                sttText: debugSTTText,
                outputText: debugOutputText,
                status: "error",
                errorMessage: error.localizedDescription
            )
            devLog("pipeline_error", runID: run.id, fields: [
                "error": error.localizedDescription,
                "elapsed_ms": msString(elapsedMs(since: pipelineStartedAt)),
            ])
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

    private func startVisionContextCollection(config: Config, runID: String) -> Task<VisionContextTaskResult, Never>? {
        guard config.context.visionEnabled else {
            devLog("vision_disabled", runID: runID)
            return nil
        }

        let key: String
        do {
            key = try llmAPIKey(config: config)
        } catch {
            devLog("vision_skipped_missing_key", runID: runID)
            return nil
        }

        let model = config.llmModel
        devLog("vision_start", runID: runID, fields: [
            "model": model.rawValue,
        ])
        return Task { @MainActor [weak self] in
            guard let self else {
                return VisionContextTaskResult(
                    context: nil,
                    captureMs: 0,
                    analyzeMs: 0,
                    totalMs: 0,
                    imageData: nil,
                    imageMimeType: nil,
                    imageBytes: 0,
                    imageWidth: 0,
                    imageHeight: 0,
                    error: "coordinator_deallocated"
                )
            }
            let visionStartedAt = DispatchTime.now()
            let captureStartedAt = DispatchTime.now()
            guard let image = ScreenCapture.captureOptimizedImage(maxDimension: 1280, jpegQuality: 0.6) else {
                return VisionContextTaskResult(
                    context: nil,
                    captureMs: self.elapsedMs(since: captureStartedAt),
                    analyzeMs: 0,
                    totalMs: self.elapsedMs(since: visionStartedAt),
                    imageData: nil,
                    imageMimeType: nil,
                    imageBytes: 0,
                    imageWidth: 0,
                    imageHeight: 0,
                    error: "capture_failed"
                )
            }
            let captureMs = self.elapsedMs(since: captureStartedAt)
            do {
                let analyzeStartedAt = DispatchTime.now()
                let context = try await postProcessor.analyzeVisionContext(
                    model: model,
                    apiKey: key,
                    imageData: image.data,
                    mimeType: image.mimeType,
                    debugRunID: runID
                )
                return VisionContextTaskResult(
                    context: context,
                    captureMs: captureMs,
                    analyzeMs: self.elapsedMs(since: analyzeStartedAt),
                    totalMs: self.elapsedMs(since: visionStartedAt),
                    imageData: image.data,
                    imageMimeType: image.mimeType,
                    imageBytes: image.data.count,
                    imageWidth: image.width,
                    imageHeight: image.height,
                    error: nil
                )
            } catch {
                return VisionContextTaskResult(
                    context: nil,
                    captureMs: captureMs,
                    analyzeMs: 0,
                    totalMs: self.elapsedMs(since: visionStartedAt),
                    imageData: image.data,
                    imageMimeType: image.mimeType,
                    imageBytes: image.data.count,
                    imageWidth: image.width,
                    imageHeight: image.height,
                    error: error.localizedDescription
                )
            }
        }
    }

    private func resolveVisionContextIfReady(from task: Task<VisionContextTaskResult, Never>?, runID: String) async -> VisionContextTaskResult? {
        guard let task else {
            return nil
        }
        let waitStartedAt = DispatchTime.now()
        let maybeResult = await withTaskGroup(of: VisionContextTaskResult?.self, returning: VisionContextTaskResult?.self) { group in
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
        guard let result = maybeResult else {
            task.cancel()
            devLog("vision_skipped_not_ready", runID: runID, fields: [
                "wait_ms": msString(elapsedMs(since: waitStartedAt)),
            ])
            return nil
        }
        devLog("vision_done", runID: runID, fields: [
            "wait_ms": msString(elapsedMs(since: waitStartedAt)),
            "capture_ms": msString(result.captureMs),
            "analyze_ms": msString(result.analyzeMs),
            "total_ms": msString(result.totalMs),
            "image_bytes": String(result.imageBytes),
            "image_wh": "\(result.imageWidth)x\(result.imageHeight)",
            "context_present": String(result.context != nil),
            "error": result.error ?? "none",
        ])
        return result
    }

    private func persistVisionArtifacts(captureID: String?, result: VisionContextTaskResult?) {
        guard let captureID, let result else { return }
        do {
            try debugCaptureStore.saveVisionArtifacts(
                captureID: captureID,
                context: result.context,
                imageData: result.imageData,
                imageMimeType: result.imageMimeType
            )
        } catch {
            DevLog.info("debug_capture_vision_artifacts_save_failed", fields: [
                "capture_id": captureID,
                "error": error.localizedDescription,
            ])
        }
    }

    private func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    private func msString(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func devLog(_ event: String, runID: String, fields: [String: String] = [:]) {
        var payload = fields
        payload["run"] = runID
        DevLog.info(event, fields: payload)
        SystemLog.app(event, fields: payload)
    }

    private static func makeRunID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private func saveDebugRecording(result: RecordingResult, config: Config, runID: String) {
        guard !result.pcmData.isEmpty else {
            return
        }
        do {
            let captureID = try debugCaptureStore.saveRecording(
                runID: runID,
                sampleRate: result.sampleRate,
                pcmData: result.pcmData,
                llmModel: config.llmModel.rawValue,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName
            )
            debugCaptureIDsByRun[runID] = captureID
            devLog("debug_capture_saved", runID: runID, fields: [
                "capture_id": captureID,
                "capture_dir": debugCaptureStore.capturesDirectoryPath,
            ])
        } catch {
            devLog("debug_capture_save_failed", runID: runID, fields: [
                "error": error.localizedDescription,
            ])
        }
    }

    private func updateDebugCapture(
        captureID: String?,
        sttText: String?,
        outputText: String?,
        status: String,
        errorMessage: String? = nil
    ) {
        guard let captureID else { return }
        do {
            try debugCaptureStore.updateResult(
                captureID: captureID,
                sttText: sttText,
                outputText: outputText,
                status: status,
                errorMessage: errorMessage
            )
        } catch {
            DevLog.info("debug_capture_update_failed", fields: [
                "capture_id": captureID,
                "status": status,
                "error": error.localizedDescription,
            ])
        }
    }

    private func prepareDeepgramStreamIfNeeded(config: Config, runID: String) -> DeepgramStreamingClient? {
        guard !config.llmModel.usesDirectAudio else {
            return nil
        }
        let deepgramKey = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deepgramKey.isEmpty else {
            return nil
        }

        let stream = DeepgramStreamingClient()
        let language = languageParam(config.inputLanguage)
        Task {
            do {
                try await stream.start(
                    apiKey: deepgramKey,
                    sampleRate: AudioRecorder.targetSampleRate,
                    language: language
                )
                devLog("stt_stream_connected", runID: runID, fields: [
                    "sample_rate": String(AudioRecorder.targetSampleRate),
                    "language": language ?? "auto",
                ])
            } catch {
                devLog("stt_stream_connect_failed", runID: runID, fields: [
                    "error": error.localizedDescription,
                ])
            }
        }
        return stream
    }
}
