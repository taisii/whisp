import AppKit
import Foundation
import WhispCore

@MainActor
final class PipelineRunner {
    private let usageStore: UsageStore
    private let postProcessor: PostProcessorService
    private let sttService: STTService
    private let contextService: ContextService
    private let outputService: OutputService
    private let debugCaptureService: DebugCaptureService
    private let runtimeStatsStore: RuntimeStatsStore

    init(
        usageStore: UsageStore,
        postProcessor: PostProcessorService,
        sttService: STTService,
        contextService: ContextService,
        outputService: OutputService,
        debugCaptureService: DebugCaptureService,
        runtimeStatsStore: RuntimeStatsStore
    ) {
        self.usageStore = usageStore
        self.postProcessor = postProcessor
        self.sttService = sttService
        self.contextService = contextService
        self.outputService = outputService
        self.debugCaptureService = debugCaptureService
        self.runtimeStatsStore = runtimeStatsStore
    }

    func run(context: RunContext) async -> PipelineOutcome {
        await run(
            input: context.input,
            transition: context.transition,
            notifyWarning: context.notifyWarning
        )
    }

    private func run(
        input: PipelineRunInput,
        transition: @escaping (PipelineStateMachine.Event) -> Void,
        notifyWarning: @escaping (String) -> Void
    ) async -> PipelineOutcome {
        let pipelineStartedAtDate = Date()
        let pipelineStartedAtMs = epochMs(pipelineStartedAtDate)
        let captureID = input.artifacts.captureID
        let debugRunDirectory = input.artifacts.runDirectory
        let accessibilityContext = input.artifacts.accessibilityContext
        let logger = pipelineLogger(runID: input.run.id, captureID: captureID)
        let resolvedGeneration = GenerationPrimaryConfigResolver.resolve(config: input.config)
        devLog("pipeline_start", runID: input.run.id, captureID: captureID, fields: [
            "request_sent_at_ms": epochMsString(pipelineStartedAtDate),
        ])

        let shouldApplyAccessibilitySummary = shouldApplyAccessibilitySummary(
            startSource: input.run.accessibilitySummarySourceAtStart,
            stopSource: input.accessibilitySummarySourceAtStop
        )
        let summaryTask = input.run.accessibilitySummaryTask
        var contextSummaryLog: DebugRunLog?
        var accessibilitySummary: ContextInfo?
        if let summaryTask, !shouldApplyAccessibilitySummary {
            summaryTask.task.cancel()
            if let captureID {
                contextSummaryLog = makeContextSummaryLog(
                    run: input.run,
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
            guard !input.result.pcmData.isEmpty else {
                if let summaryTask, shouldApplyAccessibilitySummary, contextSummaryLog == nil {
                    summaryTask.task.cancel()
                    if let captureID {
                        contextSummaryLog = makeContextSummaryLog(
                            run: input.run,
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
                    status: "skipped",
                    skipReason: PipelineSkipReason.emptyAudio.rawValue
                )
                devLog("pipeline_skip_empty_audio", runID: input.run.id, captureID: captureID)
                if let captureID {
                    appendStructuredLogs(captureID: captureID, logs: [contextSummaryLog])
                    let cancelledPipeline = DebugRunLog.pipeline(DebugPipelineLog(
                        base: makeLogBase(
                            runID: input.run.id,
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
                recordRuntimeStats(
                    input: input,
                    outcome: .skipped,
                    contextSummaryLog: contextSummaryLog,
                    sttLog: sttLog,
                    visionLog: visionLog,
                    postProcessLog: postProcessLog,
                    directInputLog: directInputLog,
                    endedAt: Date()
                )
                transition(.reset)
                return .skipped(reason: .emptyAudio, sttText: nil, outputText: nil)
            }

            var sttUsage: STTUsage?
            var llmUsage: LLMUsage?
            let sttText: String
            let processedText: String

            if resolvedGeneration.model.usesDirectAudio {
                transition(.startPostProcessing)
                let wav = buildWAVBytes(sampleRate: UInt32(input.result.sampleRate), pcmData: input.result.pcmData)
                let llmKey = try APIKeyResolver.llmKey(config: input.config, model: resolvedGeneration.model)
                if let summaryTask, shouldApplyAccessibilitySummary, contextSummaryLog == nil {
                    let summaryResolution = await resolveAccessibilitySummaryIfReady(task: summaryTask.task)
                    if summaryResolution.ready {
                        accessibilitySummary = summaryResolution.summary
                        if let captureID {
                            let status: DebugLogStatus = accessibilitySummary == nil ? .error : .ok
                            contextSummaryLog = makeContextSummaryLog(
                                run: input.run,
                                captureID: captureID,
                                task: summaryTask,
                                endedAt: summaryResolution.completedAtDate ?? Date(),
                                status: status,
                                summary: accessibilitySummary,
                                error: accessibilitySummary == nil ? "summary_unavailable" : nil
                            )
                        }
                    } else {
                        summaryTask.task.cancel()
                        if let captureID {
                            contextSummaryLog = makeContextSummaryLog(
                                run: input.run,
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
                debugCaptureService.updateContext(captureID: captureID, context: context)
                if resolvedGeneration.requireContext && !hasUsableContext(context) {
                    notifyWarning("Generation主設定(require_context=true)ですが、コンテキスト未取得のため実行を継続します。")
                    devLog("generation_require_context_missing", runID: input.run.id, captureID: captureID)
                }
                let llmStartedAtDate = Date()
                let llmStartedAtMs = epochMs(llmStartedAtDate)
                devLog("audio_llm_start", runID: input.run.id, captureID: captureID, fields: [
                    "pcm_bytes": String(input.result.pcmData.count),
                    "context_present": String(context != nil),
                    "request_sent_at_ms": epochMsString(llmStartedAtDate),
                ])
                let transcription = try await postProcessor.transcribeAudio(
                    model: resolvedGeneration.model,
                    apiKey: llmKey,
                    wavData: wav,
                    mimeType: "audio/wav",
                    context: context,
                    debugRunID: input.run.id,
                    debugRunDirectory: debugRunDirectory
                )
                let llmResponseAt = Date()
                let llmResponseAtMs = epochMs(llmResponseAt)
                devLog("audio_llm_done", runID: input.run.id, captureID: captureID, fields: [
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
                            runID: input.run.id,
                            captureID: captureID,
                            logType: .postprocess,
                            eventStartMs: llmStartedAtMs,
                            eventEndMs: llmResponseAtMs,
                            status: .ok
                        ),
                        model: resolvedGeneration.model.rawValue,
                        contextPresent: context != nil,
                        sttChars: 0,
                        outputChars: processedText.count,
                        kind: .audioTranscribe
                    ))
                }
            } else {
                let llmKey = try APIKeyResolver.llmKey(config: input.config, model: resolvedGeneration.model)
                let visionStartedAtDate = Date()
                let visionTask = contextService.startVisionCollection(
                    config: input.config,
                    runID: input.run.id,
                    preferredWindowOwnerPID: input.run.appPIDAtStart,
                    runDirectory: debugRunDirectory,
                    logger: logger
                )
                if visionTask == nil, let captureID {
                    let now = Date()
                    visionLog = .vision(DebugVisionLog(
                        base: makeLogBase(
                            runID: input.run.id,
                            captureID: captureID,
                            logType: .vision,
                            eventStartMs: epochMs(visionStartedAtDate),
                            eventEndMs: epochMs(now),
                            status: .cancelled
                        ),
                        model: resolvedGeneration.model.rawValue,
                        mode: input.config.context.visionMode.rawValue,
                        contextPresent: false,
                        imageBytes: 0,
                        imageWidth: 0,
                        imageHeight: 0,
                        error: "vision_disabled"
                    ))
                }

                let stt = try await sttService.transcribe(
                    config: input.config,
                    recording: input.result,
                    language: LanguageResolver.languageParam(input.config.inputLanguage),
                    runID: input.run.id,
                    streamingSession: input.sttStreamingSession,
                    logger: logger
                )

                sttText = stt.transcript
                sttUsage = stt.usage
                sttChars = sttText.count
                if let captureID {
                    sttLog = .stt(DebugSTTLog(
                        base: makeLogBase(
                            runID: input.run.id,
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
                                run: input.run,
                                captureID: captureID,
                                task: summaryTask,
                                endedAt: summaryResolution.completedAtDate ?? Date(),
                                status: status,
                                summary: accessibilitySummary,
                                error: accessibilitySummary == nil ? "summary_unavailable" : nil
                            )
                        }
                    } else {
                        summaryTask.task.cancel()
                        if let captureID {
                            contextSummaryLog = makeContextSummaryLog(
                                run: input.run,
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
                        status: "skipped",
                        skipReason: PipelineSkipReason.emptySTT.rawValue,
                        metrics: DebugRunMetrics(
                            sttChars: sttChars,
                            outputChars: 0
                        )
                    )
                    devLog("pipeline_skip_empty_stt", runID: input.run.id, captureID: captureID)
                    if let captureID {
                        if visionTask != nil, visionLog == nil {
                            let cancelledAt = Date()
                            visionLog = .vision(DebugVisionLog(
                                base: makeLogBase(
                                    runID: input.run.id,
                                    captureID: captureID,
                                    logType: .vision,
                                    eventStartMs: epochMs(visionStartedAtDate),
                                    eventEndMs: epochMs(cancelledAt),
                                    status: .cancelled
                                ),
                                model: resolvedGeneration.model.rawValue,
                                mode: input.config.context.visionMode.rawValue,
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
                                runID: input.run.id,
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
                    recordRuntimeStats(
                        input: input,
                        outcome: .skipped,
                        contextSummaryLog: contextSummaryLog,
                        sttLog: sttLog,
                        visionLog: visionLog,
                        postProcessLog: postProcessLog,
                        directInputLog: directInputLog,
                        endedAt: Date()
                    )
                    transition(.reset)
                    return .skipped(reason: .emptySTT, sttText: sttText, outputText: nil)
                }

                transition(.startPostProcessing)
                let appName = input.run.appNameAtStart ?? NSWorkspace.shared.frontmostApplication?.localizedName
                let visionResult = await contextService.resolveVisionIfReady(task: visionTask, logger: logger)
                debugCaptureService.persistVisionArtifacts(captureID: captureID, result: visionResult)
                if visionResult == nil, let visionTask {
                    persistDeferredVisionArtifacts(task: visionTask, runID: input.run.id, captureID: captureID)
                }
                if let captureID, visionLog == nil, let visionResult {
                    let visionCompletedAt = Date()
                    visionLog = .vision(DebugVisionLog(
                        base: makeLogBase(
                            runID: input.run.id,
                            captureID: captureID,
                            logType: .vision,
                            eventStartMs: epochMs(visionStartedAtDate),
                            eventEndMs: epochMs(visionCompletedAt),
                            status: visionResult.error == nil ? .ok : .error
                        ),
                        model: resolvedGeneration.model.rawValue,
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
                debugCaptureService.updateContext(captureID: captureID, context: context)
                if resolvedGeneration.requireContext && !hasUsableContext(context) {
                    notifyWarning("Generation主設定(require_context=true)ですが、コンテキスト未取得のため実行を継続します。")
                    devLog("generation_require_context_missing", runID: input.run.id, captureID: captureID)
                }

                let llmStartedAtDate = Date()
                let llmStartedAtMs = epochMs(llmStartedAtDate)
                devLog("postprocess_start", runID: input.run.id, captureID: captureID, fields: [
                    "model": resolvedGeneration.model.rawValue,
                    "context_present": String(context != nil),
                    "stt_chars": String(sttText.count),
                    "request_sent_at_ms": epochMsString(llmStartedAtDate),
                ])
                let postProcessed = try await postProcessor.postProcess(
                    model: resolvedGeneration.model,
                    apiKey: llmKey,
                    sttResult: sttText,
                    languageHint: input.config.inputLanguage,
                    appName: appName,
                    appPromptRules: input.config.appPromptRules,
                    context: context,
                    templateOverride: resolvedGeneration.promptTemplateOverride,
                    debugRunID: input.run.id,
                    debugRunDirectory: debugRunDirectory
                )
                let llmResponseAt = Date()
                let llmResponseAtMs = epochMs(llmResponseAt)
                devLog("postprocess_done", runID: input.run.id, captureID: captureID, fields: [
                    "output_chars": String(postProcessed.text.count),
                    "response_received_at_ms": epochMsString(llmResponseAt),
                ])

                processedText = postProcessed.text
                llmUsage = postProcessed.usage
                outputChars = processedText.count
                if let captureID {
                    postProcessLog = .postprocess(DebugPostProcessLog(
                        base: makeLogBase(
                            runID: input.run.id,
                            captureID: captureID,
                            logType: .postprocess,
                            eventStartMs: llmStartedAtMs,
                            eventEndMs: llmResponseAtMs,
                            status: .ok
                        ),
                        model: resolvedGeneration.model.rawValue,
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
                    status: "skipped",
                    skipReason: PipelineSkipReason.emptyOutput.rawValue,
                    metrics: DebugRunMetrics(
                        sttChars: sttChars,
                        outputChars: outputChars
                    )
                )
                devLog("pipeline_skip_empty_output", runID: input.run.id, captureID: captureID)
                if let captureID {
                    appendStructuredLogs(captureID: captureID, logs: [contextSummaryLog, sttLog, visionLog, postProcessLog])
                    let cancelledPipeline = DebugRunLog.pipeline(DebugPipelineLog(
                        base: makeLogBase(
                            runID: input.run.id,
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
                recordRuntimeStats(
                    input: input,
                    outcome: .skipped,
                    contextSummaryLog: contextSummaryLog,
                    sttLog: sttLog,
                    visionLog: visionLog,
                    postProcessLog: postProcessLog,
                    directInputLog: directInputLog,
                    endedAt: Date()
                )
                transition(.reset)
                return .skipped(reason: .emptyOutput, sttText: sttText, outputText: processedText)
            }

            transition(.startDirectInput)
            let inputStartedAtDate = Date()
            let inputStartedAtMs = epochMs(inputStartedAtDate)
            devLog("direct_input_start", runID: input.run.id, captureID: captureID, fields: [
                "request_sent_at_ms": epochMsString(inputStartedAtDate),
            ])
            let directInputOK = outputService.sendText(processedText)
            let inputDoneAtDate = Date()
            let inputDoneAtMs = epochMs(inputDoneAtDate)
            devLog("direct_input_done", runID: input.run.id, captureID: captureID, fields: [
                "success": String(directInputOK),
                "output_chars": String(processedText.count),
                "response_received_at_ms": epochMsString(inputDoneAtDate),
            ])
            if let captureID {
                directInputLog = .directInput(DebugDirectInputLog(
                    base: makeLogBase(
                        runID: input.run.id,
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
                status: directInputOK ? "completed" : "completed_with_output_error",
                metrics: DebugRunMetrics(
                    sttChars: sttChars,
                    outputChars: outputChars
                )
            )
            if !directInputOK {
                notifyWarning("直接入力に失敗しました。アクセシビリティ権限を確認してください。")
            }

            _ = outputService.playCompletionSound()
            transition(.finish)

            try? await Task.sleep(nanoseconds: 100_000_000)
            transition(.reset)

            let pipelineDoneAtDate = Date()
            let pipelineDoneAtMs = epochMs(pipelineDoneAtDate)
            devLog("pipeline_done", runID: input.run.id, captureID: captureID, fields: [
                "stt_chars": String(sttText.count),
                "output_chars": String(processedText.count),
                "response_received_at_ms": epochMsString(pipelineDoneAtDate),
            ])
            if let captureID {
                appendStructuredLogs(captureID: captureID, logs: [contextSummaryLog, sttLog, visionLog, postProcessLog, directInputLog])
                let pipelineLog = DebugRunLog.pipeline(DebugPipelineLog(
                    base: makeLogBase(
                        runID: input.run.id,
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
            recordRuntimeStats(
                input: input,
                outcome: .completed,
                contextSummaryLog: contextSummaryLog,
                sttLog: sttLog,
                visionLog: visionLog,
                postProcessLog: postProcessLog,
                directInputLog: directInputLog,
                endedAt: pipelineDoneAtDate
            )
            print("[pipeline] stt chars=\(sttText.count), output chars=\(processedText.count)")
            return .completed(sttText: sttText, outputText: processedText, directInputSucceeded: directInputOK)
        } catch {
            if let summaryTask, shouldApplyAccessibilitySummary, contextSummaryLog == nil {
                summaryTask.task.cancel()
                if let captureID {
                    contextSummaryLog = makeContextSummaryLog(
                        run: input.run,
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
                status: "failed",
                failureStage: "pipeline",
                metrics: DebugRunMetrics(
                    sttChars: sttChars,
                    outputChars: outputChars
                ),
                errorMessage: error.localizedDescription
            )
            let pipelineErrorAt = Date()
            devLog("pipeline_error", runID: input.run.id, captureID: captureID, fields: [
                "error": error.localizedDescription,
                "response_received_at_ms": epochMsString(pipelineErrorAt),
            ])
            if let captureID {
                appendStructuredLogs(captureID: captureID, logs: [contextSummaryLog, sttLog, visionLog, postProcessLog, directInputLog])
                let pipelineLog = DebugRunLog.pipeline(DebugPipelineLog(
                    base: makeLogBase(
                        runID: input.run.id,
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
            recordRuntimeStats(
                input: input,
                outcome: .failed,
                contextSummaryLog: contextSummaryLog,
                sttLog: sttLog,
                visionLog: visionLog,
                postProcessLog: postProcessLog,
                directInputLog: directInputLog,
                endedAt: pipelineErrorAt
            )
            return .failed(
                message: "処理に失敗: \(error.localizedDescription)",
                sttText: debugSTTText,
                outputText: debugOutputText
            )
        }
    }

    private func epochMsString(_ date: Date) -> String {
        WhispTime.epochMsString(date)
    }

    private func epochMs(_ date: Date = Date()) -> Int64 {
        WhispTime.epochMs(date)
    }

    private func pipelineLogger(runID: String, captureID: String?) -> PipelineEventLogger {
        { [weak self] event, fields in
            Task { @MainActor in
                self?.devLog(event, runID: runID, captureID: captureID, fields: fields)
            }
        }
    }

    private func shouldApplyAccessibilitySummary(startSource: String?, stopSource: String?) -> Bool {
        guard let startSource, let stopSource else { return false }
        return startSource == stopSource
    }

    private func hasUsableContext(_ context: ContextInfo?) -> Bool {
        guard let context else {
            return false
        }
        return !context.isEmpty
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
        run: PipelineRun,
        captureID: String,
        task: PipelineAccessibilitySummaryTask,
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

    private func resolveAccessibilitySummaryIfReady(
        task: Task<PipelineAccessibilitySummaryResult, Never>
    ) async -> (ready: Bool, summary: ContextInfo?, completedAtDate: Date?) {
        let resolution = await TaskReadiness.awaitIfReady(task: task)
        guard resolution.ready, let value = resolution.value else {
            return (false, nil, nil)
        }
        return (true, value.summary, value.completedAtDate)
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

    private func recordRuntimeStats(
        input: PipelineRunInput,
        outcome: RuntimeStatsOutcome,
        contextSummaryLog: DebugRunLog?,
        sttLog: DebugRunLog?,
        visionLog: DebugRunLog?,
        postProcessLog: DebugRunLog?,
        directInputLog: DebugRunLog?,
        endedAt: Date
    ) {
        let totalAfterStopMs = max(0, endedAt.timeIntervalSince(input.recordingStoppedAtDate) * 1000)
        let entry = RuntimeStatsEntry(
            recordedAt: endedAt,
            outcome: outcome,
            sttMs: durationMs(from: sttLog),
            postMs: durationMs(from: postProcessLog),
            visionMs: durationMs(from: contextSummaryLog) ?? durationMs(from: visionLog),
            directInputMs: durationMs(from: directInputLog),
            totalAfterStopMs: totalAfterStopMs
        )

        do {
            try runtimeStatsStore.record(entry: entry)
        } catch {
            devLog("runtime_stats_record_failed", runID: input.run.id, captureID: input.artifacts.captureID, fields: [
                "error": error.localizedDescription,
            ])
        }
    }

    private func durationMs(from log: DebugRunLog?) -> Double? {
        guard let log else { return nil }
        let duration = Double(log.base.eventEndMs - log.base.eventStartMs)
        return duration >= 0 ? duration : nil
    }
}
