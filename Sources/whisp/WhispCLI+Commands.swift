import Foundation
import WhispCore

extension WhispCLI {
    static func runSTTFile(path: String) async throws {
        let config = try loadConfig()
        let key = try deepgramAPIKey(from: config)

        let wavData = try Data(contentsOf: URL(fileURLWithPath: path))
        let audio = try parsePCM16MonoWAV(wavData)
        let client = DeepgramClient()
        let language = languageParam(config.inputLanguage)

        let startedAt = DispatchTime.now()
        let result = try await client.transcribe(
            apiKey: key,
            sampleRate: Int(audio.sampleRate),
            audio: audio.pcmBytes,
            language: language
        )
        let elapsed = elapsedMs(since: startedAt)

        print("mode: deepgram_rest")
        print("audio_seconds: \(String(format: "%.3f", audioDurationSeconds(audio: audio)))")
        print("total_ms: \(msString(elapsed))")
        print("transcript: \(result.transcript)")
        if let usage = result.usage {
            print("duration_seconds: \(usage.durationSeconds)")
            if let requestID = usage.requestID {
                print("request_id: \(requestID)")
            }
        }
    }

    static func runSTTStreamFile(path: String, chunkMs: Int, realtime: Bool) async throws {
        let config = try loadConfig()
        let key = try deepgramAPIKey(from: config)

        let wavData = try Data(contentsOf: URL(fileURLWithPath: path))
        let audio = try parsePCM16MonoWAV(wavData)
        let sampleRate = Int(audio.sampleRate)
        let language = languageParam(config.inputLanguage)
        let client = DeepgramStreamingClient()

        let chunkSamples = max(1, sampleRate * chunkMs / 1000)
        let chunkBytes = chunkSamples * MemoryLayout<Int16>.size

        let startedAt = DispatchTime.now()
        try await client.start(apiKey: key, sampleRate: sampleRate, language: language)
        let streamStartedAt = DispatchTime.now()

        var offset = 0
        while offset < audio.pcmBytes.count {
            let end = min(offset + chunkBytes, audio.pcmBytes.count)
            let chunk = audio.pcmBytes.subdata(in: offset..<end)
            await client.enqueueAudioChunk(chunk)

            if realtime {
                let frameCount = (end - offset) / MemoryLayout<Int16>.size
                let seconds = Double(frameCount) / Double(sampleRate)
                let nanoseconds = UInt64(seconds * 1_000_000_000)
                if nanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }
            }
            offset = end
        }

        let sendMs = elapsedMs(since: streamStartedAt)
        let finalizeStartedAt = DispatchTime.now()
        let result = try await client.finish()
        let finalizeMs = elapsedMs(since: finalizeStartedAt)
        let totalMs = elapsedMs(since: startedAt)

        print("mode: deepgram_stream")
        print("audio_seconds: \(String(format: "%.3f", audioDurationSeconds(audio: audio)))")
        print("chunk_ms: \(chunkMs)")
        print("realtime: \(realtime)")
        print("send_ms: \(msString(sendMs))")
        print("finalize_ms: \(msString(finalizeMs))")
        print("total_ms: \(msString(totalMs))")
        print("transcript: \(result.transcript)")
        if let usage = result.usage {
            print("duration_seconds: \(usage.durationSeconds)")
            if let requestID = usage.requestID {
                print("request_id: \(requestID)")
            }
        }
    }

    static func runPipelineFile(options: PipelineOptions) async throws {
        let config = try loadConfig()
        let context = try loadContextInfo(path: options.contextFilePath)
        let run = try await executePipelineRun(config: config, options: options, context: context)
        let dominant = dominantStage(sttAfterStopMs: run.sttAfterStopMs, postMs: run.postMs, outputMs: run.outputMs)

        print("mode: full_pipeline")
        print("stt_mode: \(options.sttMode.rawValue)")
        print("model: \(run.model.rawValue)")
        print("audio_seconds: \(String(format: "%.3f", run.audioSeconds))")
        print("stt_source: \(run.sttSource)")
        print("stt_send_ms: \(msString(run.sttSendMs))")
        print("stt_finalize_ms: \(msString(run.sttFinalizeMs))")
        print("stt_total_ms: \(msString(run.sttTotalMs))")
        print("stt_after_stop_ms: \(msString(run.sttAfterStopMs))")
        print("post_ms: \(msString(run.postMs))")
        print("output_ms: \(msString(run.outputMs))")
        print("total_after_stop_ms: \(msString(run.totalAfterStopMs))")
        print("total_wall_ms: \(msString(run.totalWallMs))")
        print("dominant_stage_after_stop: \(dominant)")
        print("stt_chars: \(run.sttText.count)")
        print("output_chars: \(run.outputText.count)")
        print("context_present: \(context != nil)")
        print("context_terms_count: \(context?.visionTerms.count ?? 0)")
        print("stt_sample: \(sampleText(run.sttText))")
        print("output_sample: \(sampleText(run.outputText))")
    }

    static func runManualCaseBenchmark(options: ManualBenchmarkOptions) async throws {
        let config = try loadConfig()
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases: [ManualBenchmarkCase]
        if let limit = options.limit {
            selectedCases = Array(allCases.prefix(limit))
        } else {
            selectedCases = allCases
        }
        let logPaths = try prepareManualBenchmarkLogPaths(customDir: options.benchmarkLogDir)
        let caseLogHandle = try openWriteHandle(path: logPaths.caseRowsPath)
        defer { try? caseLogHandle.close() }

        print("mode: manual_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("stt_mode: \(options.sttMode.rawValue)")
        print("chunk_ms: \(options.chunkMs)")
        print("realtime: \(options.realtime)")
        print("require_context: \(options.requireContext)")
        print("min_audio_seconds: \(String(format: "%.2f", options.minAudioSeconds))")
        print("min_label_confidence: \(options.minLabelConfidence.map { String(format: "%.2f", $0) } ?? "none")")
        print("intent_source: \(options.intentSource.rawValue)")
        print("intent_judge: \(options.intentJudgeEnabled)")
        print("intent_judge_model: \(options.intentJudgeModel?.rawValue ?? "auto")")
        print("benchmark_log_dir: \(logPaths.baseDir)")
        print("")
        print("id\tstatus\tcontext\tvision_image\texact_match\tcer\tintent_match\tintent_score\taudio_seconds\tstt_after_stop_ms\tpost_ms\ttotal_after_stop_ms")

        var evaluations: [ManualCaseEvaluation] = []
        var skippedMissingAudio = 0
        var skippedInvalidAudio = 0
        var skippedMissingReferenceTranscript = 0
        var skippedMissingContext = 0
        var skippedTooShortAudio = 0
        var skippedLowLabelConfidence = 0
        var failedRuns = 0
        var judgeContext: (model: LLMModel, apiKey: String)?
        var judgeUnavailableReason: String?

        for item in selectedCases {
            let contextUsed = item.context != nil
            let visionImageAttached = item.visionImageFile != nil

            guard let transcriptRef = item.resolvedReferenceTranscript() else {
                skippedMissingReferenceTranscript += 1
                print("\(item.id)\tskipped_missing_reference_transcript\t\(contextUsed)\t\(visionImageAttached)\t-\t-\t-\t-\t-\t-\t-\t-")
                try appendJSONLine(
                    ManualCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_reference_transcript",
                        reason: "ground truth / transcript label がありません",
                        suitable: false,
                        audioSeconds: nil,
                        contextUsed: contextUsed,
                        visionImageAttached: visionImageAttached,
                        transcriptReferenceSource: nil,
                        exactMatch: nil,
                        cer: nil,
                        intentReferenceSource: nil,
                        intentMatch: nil,
                        intentScore: nil,
                        sttAfterStopMs: nil,
                        postMs: nil,
                        totalAfterStopMs: nil
                    ),
                    to: caseLogHandle
                )
                continue
            }

            if !FileManager.default.fileExists(atPath: item.audioFile) {
                skippedMissingAudio += 1
                print("\(item.id)\tskipped_missing_audio\t\(contextUsed)\t\(visionImageAttached)\t-\t-\t-\t-\t-\t-\t-\t-")
                try appendJSONLine(
                    ManualCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_audio",
                        reason: "audio_file が存在しません",
                        suitable: false,
                        audioSeconds: nil,
                        contextUsed: contextUsed,
                        visionImageAttached: visionImageAttached,
                        transcriptReferenceSource: transcriptRef.source,
                        exactMatch: nil,
                        cer: nil,
                        intentReferenceSource: nil,
                        intentMatch: nil,
                        intentScore: nil,
                        sttAfterStopMs: nil,
                        postMs: nil,
                        totalAfterStopMs: nil
                    ),
                    to: caseLogHandle
                )
                continue
            }

            let audioSeconds: Double
            do {
                let wavData = try Data(contentsOf: URL(fileURLWithPath: item.audioFile))
                let audio = try parsePCM16MonoWAV(wavData)
                audioSeconds = audioDurationSeconds(audio: audio)
            } catch {
                skippedInvalidAudio += 1
                print("\(item.id)\tskipped_invalid_audio\t\(contextUsed)\t\(visionImageAttached)\t-\t-\t-\t-\t-\t-\t-\t-")
                try appendJSONLine(
                    ManualCaseLogRow(
                        id: item.id,
                        status: "skipped_invalid_audio",
                        reason: error.localizedDescription,
                        suitable: false,
                        audioSeconds: nil,
                        contextUsed: contextUsed,
                        visionImageAttached: visionImageAttached,
                        transcriptReferenceSource: transcriptRef.source,
                        exactMatch: nil,
                        cer: nil,
                        intentReferenceSource: nil,
                        intentMatch: nil,
                        intentScore: nil,
                        sttAfterStopMs: nil,
                        postMs: nil,
                        totalAfterStopMs: nil
                    ),
                    to: caseLogHandle
                )
                continue
            }

            if options.requireContext && item.context == nil {
                skippedMissingContext += 1
                print("\(item.id)\tskipped_missing_context\tfalse\t\(visionImageAttached)\t-\t-\t-\t-\t\(String(format: "%.2f", audioSeconds))\t-\t-\t-")
                try appendJSONLine(
                    ManualCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_context",
                        reason: "--require-context 指定のため",
                        suitable: false,
                        audioSeconds: audioSeconds,
                        contextUsed: contextUsed,
                        visionImageAttached: visionImageAttached,
                        transcriptReferenceSource: transcriptRef.source,
                        exactMatch: nil,
                        cer: nil,
                        intentReferenceSource: nil,
                        intentMatch: nil,
                        intentScore: nil,
                        sttAfterStopMs: nil,
                        postMs: nil,
                        totalAfterStopMs: nil
                    ),
                    to: caseLogHandle
                )
                continue
            }

            if audioSeconds < options.minAudioSeconds {
                skippedTooShortAudio += 1
                print("\(item.id)\tskipped_too_short_audio\t\(contextUsed)\t\(visionImageAttached)\t-\t-\t-\t-\t\(String(format: "%.2f", audioSeconds))\t-\t-\t-")
                try appendJSONLine(
                    ManualCaseLogRow(
                        id: item.id,
                        status: "skipped_too_short_audio",
                        reason: "audio_seconds(\(String(format: "%.2f", audioSeconds))) < min_audio_seconds(\(String(format: "%.2f", options.minAudioSeconds)))",
                        suitable: false,
                        audioSeconds: audioSeconds,
                        contextUsed: contextUsed,
                        visionImageAttached: visionImageAttached,
                        transcriptReferenceSource: transcriptRef.source,
                        exactMatch: nil,
                        cer: nil,
                        intentReferenceSource: nil,
                        intentMatch: nil,
                        intentScore: nil,
                        sttAfterStopMs: nil,
                        postMs: nil,
                        totalAfterStopMs: nil
                    ),
                    to: caseLogHandle
                )
                continue
            }

            if let threshold = options.minLabelConfidence,
               let confidence = item.resolvedLabelConfidence(),
               confidence < threshold
            {
                skippedLowLabelConfidence += 1
                print("\(item.id)\tskipped_low_label_confidence\t\(contextUsed)\t\(visionImageAttached)\t-\t-\t-\t-\t\(String(format: "%.2f", audioSeconds))\t-\t-\t-")
                try appendJSONLine(
                    ManualCaseLogRow(
                        id: item.id,
                        status: "skipped_low_label_confidence",
                        reason: "label_confidence(\(String(format: "%.2f", confidence))) < min_label_confidence(\(String(format: "%.2f", threshold)))",
                        suitable: false,
                        audioSeconds: audioSeconds,
                        contextUsed: contextUsed,
                        visionImageAttached: visionImageAttached,
                        transcriptReferenceSource: transcriptRef.source,
                        exactMatch: nil,
                        cer: nil,
                        intentReferenceSource: nil,
                        intentMatch: nil,
                        intentScore: nil,
                        sttAfterStopMs: nil,
                        postMs: nil,
                        totalAfterStopMs: nil
                    ),
                    to: caseLogHandle
                )
                continue
            }

            do {
                let run = try await executePipelineRun(
                    config: config,
                    options: PipelineOptions(
                        path: item.audioFile,
                        sttMode: options.sttMode,
                        chunkMs: options.chunkMs,
                        realtime: options.realtime,
                        emitMode: .discard,
                        contextFilePath: nil
                    ),
                    context: item.context
                )

                let output = normalizedEvalText(run.outputText)
                let gtChars = Array(transcriptRef.text)
                let outChars = Array(output)
                let editDistance = levenshteinDistance(gtChars, outChars)
                let cer = Double(editDistance) / Double(max(1, gtChars.count))
                let exactMatch = output == transcriptRef.text

                let intentReference = item.resolvedReferenceIntent(source: options.intentSource)
                var intentMatch: Bool?
                var intentScore: Int?
                if options.intentJudgeEnabled, let intentReference {
                    if judgeContext == nil {
                        do {
                            judgeContext = try resolveIntentJudgeContext(
                                config: config,
                                preferredModel: options.intentJudgeModel
                            )
                        } catch {
                            judgeUnavailableReason = error.localizedDescription
                        }
                    }
                    if let judgeContext {
                        do {
                            let judge = try await runIntentJudge(
                                model: judgeContext.model,
                                apiKey: judgeContext.apiKey,
                                reference: intentReference.label,
                                hypothesisText: output
                            )
                            intentMatch = judge.match
                            intentScore = judge.score
                        } catch {
                            judgeUnavailableReason = error.localizedDescription
                        }
                    }
                }

                let row = ManualCaseEvaluation(
                    id: item.id,
                    contextUsed: contextUsed,
                    visionImageAttached: visionImageAttached,
                    exactMatch: exactMatch,
                    cer: cer,
                    gtChars: gtChars.count,
                    editDistance: editDistance,
                    sttAfterStopMs: run.sttAfterStopMs,
                    postMs: run.postMs,
                    totalAfterStopMs: run.totalAfterStopMs,
                    audioSeconds: audioSeconds,
                    transcriptSource: transcriptRef.source,
                    intentReferenceSource: intentReference?.source,
                    intentMatch: intentMatch,
                    intentScore: intentScore
                )
                evaluations.append(row)
                print("\(item.id)\tok\t\(row.contextUsed)\t\(row.visionImageAttached)\t\(row.exactMatch)\t\(String(format: "%.3f", row.cer))\t\(row.intentMatch.map { String($0) } ?? "-")\t\(row.intentScore.map(String.init) ?? "-")\t\(String(format: "%.2f", row.audioSeconds))\t\(msString(row.sttAfterStopMs))\t\(msString(row.postMs))\t\(msString(row.totalAfterStopMs))")
                try appendJSONLine(
                    ManualCaseLogRow(
                        id: item.id,
                        status: "ok",
                        reason: nil,
                        suitable: true,
                        audioSeconds: audioSeconds,
                        contextUsed: row.contextUsed,
                        visionImageAttached: row.visionImageAttached,
                        transcriptReferenceSource: row.transcriptSource,
                        exactMatch: row.exactMatch,
                        cer: row.cer,
                        intentReferenceSource: row.intentReferenceSource,
                        intentMatch: row.intentMatch,
                        intentScore: row.intentScore,
                        sttAfterStopMs: row.sttAfterStopMs,
                        postMs: row.postMs,
                        totalAfterStopMs: row.totalAfterStopMs
                    ),
                    to: caseLogHandle
                )
            } catch {
                failedRuns += 1
                print("\(item.id)\terror\t\(contextUsed)\t\(visionImageAttached)\t-\t-\t-\t-\t\(String(format: "%.2f", audioSeconds))\t-\t-\t-")
                try appendJSONLine(
                    ManualCaseLogRow(
                        id: item.id,
                        status: "error",
                        reason: error.localizedDescription,
                        suitable: true,
                        audioSeconds: audioSeconds,
                        contextUsed: contextUsed,
                        visionImageAttached: visionImageAttached,
                        transcriptReferenceSource: transcriptRef.source,
                        exactMatch: nil,
                        cer: nil,
                        intentReferenceSource: item.resolvedReferenceIntent(source: options.intentSource)?.source,
                        intentMatch: nil,
                        intentScore: nil,
                        sttAfterStopMs: nil,
                        postMs: nil,
                        totalAfterStopMs: nil
                    ),
                    to: caseLogHandle
                )
            }
        }

        let executed = evaluations.count
        let exactCount = evaluations.filter(\.exactMatch).count
        let sumCER = evaluations.reduce(0.0) { $0 + $1.cer }
        let totalEdits = evaluations.reduce(0) { $0 + $1.editDistance }
        let totalGTChars = evaluations.reduce(0) { $0 + $1.gtChars }
        let avgSttAfterStop = evaluations.reduce(0.0) { $0 + $1.sttAfterStopMs } / Double(max(1, executed))
        let avgPost = evaluations.reduce(0.0) { $0 + $1.postMs } / Double(max(1, executed))
        let avgTotalAfterStop = evaluations.reduce(0.0) { $0 + $1.totalAfterStopMs } / Double(max(1, executed))
        let exactRate = Double(exactCount) / Double(max(1, executed))
        let avgCER = sumCER / Double(max(1, executed))
        let weightedCER = Double(totalEdits) / Double(max(1, totalGTChars))
        let intentRows = evaluations.compactMap { row -> ManualCaseEvaluation? in
            if row.intentMatch == nil { return nil }
            return row
        }
        let intentEvaluatedCount = intentRows.count
        let intentMatchCount = intentRows.filter { $0.intentMatch == true }.count
        let intentScoreValues = intentRows.compactMap(\.intentScore)
        let intentMatchRate = intentEvaluatedCount > 0 ? Double(intentMatchCount) / Double(intentEvaluatedCount) : nil
        let intentAvgScore = intentScoreValues.isEmpty
            ? nil
            : Double(intentScoreValues.reduce(0, +)) / Double(intentScoreValues.count)

        let summaryLog = ManualBenchmarkSummaryLog(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            jsonlPath: options.jsonlPath,
            sttMode: options.sttMode.rawValue,
            chunkMs: options.chunkMs,
            realtime: options.realtime,
            requireContext: options.requireContext,
            minAudioSeconds: options.minAudioSeconds,
            minLabelConfidence: options.minLabelConfidence,
            intentSource: options.intentSource.rawValue,
            intentJudgeEnabled: options.intentJudgeEnabled,
            intentJudgeModel: judgeContext?.model.rawValue ?? options.intentJudgeModel?.rawValue,
            casesTotal: allCases.count,
            casesSelected: selectedCases.count,
            executedCases: executed,
            skippedMissingAudio: skippedMissingAudio,
            skippedInvalidAudio: skippedInvalidAudio,
            skippedMissingReferenceTranscript: skippedMissingReferenceTranscript,
            skippedMissingContext: skippedMissingContext,
            skippedTooShortAudio: skippedTooShortAudio,
            skippedLowLabelConfidence: skippedLowLabelConfidence,
            failedRuns: failedRuns,
            exactMatchCases: exactCount,
            exactMatchRate: exactRate,
            avgCER: avgCER,
            weightedCER: weightedCER,
            intentEvaluatedCases: intentEvaluatedCount,
            intentMatchCases: intentMatchCount,
            intentMatchRate: intentMatchRate,
            intentAvgScore: intentAvgScore,
            avgSttAfterStopMs: avgSttAfterStop,
            avgPostMs: avgPost,
            avgTotalAfterStopMs: avgTotalAfterStop
        )
        try writeJSONFile(summaryLog, path: logPaths.summaryPath)

        print("")
        print("summary")
        print("executed_cases: \(executed)")
        print("skipped_missing_audio: \(skippedMissingAudio)")
        print("skipped_invalid_audio: \(skippedInvalidAudio)")
        print("skipped_missing_reference_transcript: \(skippedMissingReferenceTranscript)")
        print("skipped_missing_context: \(skippedMissingContext)")
        print("skipped_too_short_audio: \(skippedTooShortAudio)")
        print("skipped_low_label_confidence: \(skippedLowLabelConfidence)")
        print("failed_runs: \(failedRuns)")
        print("exact_match_cases: \(exactCount)")
        print("exact_match_rate: \(String(format: "%.3f", exactRate))")
        print("avg_cer: \(String(format: "%.3f", avgCER))")
        print("weighted_cer: \(String(format: "%.3f", weightedCER))")
        print("intent_evaluated_cases: \(intentEvaluatedCount)")
        print("intent_match_cases: \(intentMatchCount)")
        if let intentMatchRate {
            print("intent_match_rate: \(String(format: "%.3f", intentMatchRate))")
        } else {
            print("intent_match_rate: n/a")
        }
        if let intentAvgScore {
            print("intent_avg_score_0_4: \(String(format: "%.3f", intentAvgScore))")
        } else {
            print("intent_avg_score_0_4: n/a")
        }
        print("avg_stt_after_stop_ms: \(msString(avgSttAfterStop))")
        print("avg_post_ms: \(msString(avgPost))")
        print("avg_total_after_stop_ms: \(msString(avgTotalAfterStop))")
        print("case_rows_log: \(logPaths.caseRowsPath)")
        print("summary_log: \(logPaths.summaryPath)")
        if let judgeUnavailableReason {
            print("intent_judge_note: \(judgeUnavailableReason)")
        }
    }

    static func runVisionCaseBenchmark(options: VisionBenchmarkOptions) async throws {
        let config = try loadConfig()
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases = options.limit.map { Array(allCases.prefix($0)) } ?? allCases
        let logPaths = try prepareComponentBenchmarkLogPaths(
            customDir: options.benchmarkLogDir,
            defaultPrefix: "whisp-visionbench",
            rowsFilename: "vision_case_rows.jsonl",
            summaryFilename: "vision_summary.json"
        )
        let rowHandle = try openWriteHandle(path: logPaths.rowsPath)
        defer { try? rowHandle.close() }

        let model: LLMModel = .gemini25FlashLite
        let apiKey = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw AppError.invalidArgument("vision benchmark には Gemini APIキーが必要です")
        }

        print("mode: vision_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("use_cache: \(options.useCache)")
        print("model: \(model.rawValue)")
        print("benchmark_log_dir: \(logPaths.baseDir)")
        print("")
        print("id\tstatus\tcached\tsummary_cer\tterms_f1\tlatency_ms")

        var executed = 0
        var skipped = 0
        var failed = 0
        var cachedHits = 0
        var summaryCERs: [Double] = []
        var termsF1s: [Double] = []
        var latencies: [Double] = []

        for item in selectedCases {
            guard let imagePath = item.visionImageFile, !imagePath.isEmpty else {
                skipped += 1
                print("\(item.id)\tskipped_missing_image\tfalse\t-\t-\t-")
                try appendJSONLine(
                    VisionCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_image",
                        reason: "vision_image_file がありません",
                        cached: false,
                        summaryCER: nil,
                        termsPrecision: nil,
                        termsRecall: nil,
                        termsF1: nil,
                        latencyMs: nil
                    ),
                    to: rowHandle
                )
                continue
            }
            guard FileManager.default.fileExists(atPath: imagePath) else {
                skipped += 1
                print("\(item.id)\tskipped_image_not_found\tfalse\t-\t-\t-")
                try appendJSONLine(
                    VisionCaseLogRow(
                        id: item.id,
                        status: "skipped_image_not_found",
                        reason: "画像ファイルが見つかりません: \(imagePath)",
                        cached: false,
                        summaryCER: nil,
                        termsPrecision: nil,
                        termsRecall: nil,
                        termsF1: nil,
                        latencyMs: nil
                    ),
                    to: rowHandle
                )
                continue
            }
            guard let ref = item.resolvedVisionReference() else {
                skipped += 1
                print("\(item.id)\tskipped_missing_reference_context\tfalse\t-\t-\t-")
                try appendJSONLine(
                    VisionCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_reference_context",
                        reason: "context.visionSummary/visionTerms がありません",
                        cached: false,
                        summaryCER: nil,
                        termsPrecision: nil,
                        termsRecall: nil,
                        termsF1: nil,
                        latencyMs: nil
                    ),
                    to: rowHandle
                )
                continue
            }

            do {
                let imageData = try Data(contentsOf: URL(fileURLWithPath: imagePath))
                let imageHash = sha256Hex(data: imageData)
                let cacheKey = sha256Hex(text: "vision-v1|\(model.rawValue)|\(imageHash)")

                let output: (summary: String, terms: [String], latencyMs: Double, cached: Bool)
                if options.useCache,
                   let cached: CachedVisionResult = loadCacheEntry(component: "vision", key: cacheKey)
                {
                    output = (cached.summary, cached.terms, cached.latencyMs, true)
                    cachedHits += 1
                } else {
                    let mimeType = inferImageMimeType(path: imagePath)
                    let startedAt = DispatchTime.now()
                    let context = try await analyzeVisionContextGemini(
                        apiKey: apiKey,
                        imageData: imageData,
                        mimeType: mimeType
                    )
                    let latency = elapsedMs(since: startedAt)
                    output = (
                        (context?.visionSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        context?.visionTerms ?? [],
                        latency,
                        false
                    )
                    if options.useCache {
                        let cache = CachedVisionResult(
                            key: cacheKey,
                            model: model.rawValue,
                            summary: output.summary,
                            terms: output.terms,
                            latencyMs: output.latencyMs,
                            createdAt: ISO8601DateFormatter().string(from: Date())
                        )
                        try saveCacheEntry(component: "vision", key: cacheKey, value: cache)
                    }
                }

                let summaryCER: Double
                if ref.summary.isEmpty, output.summary.isEmpty {
                    summaryCER = 0
                } else {
                    let left = Array(normalizedEvalText(ref.summary))
                    let right = Array(normalizedEvalText(output.summary))
                    let edit = levenshteinDistance(left, right)
                    summaryCER = Double(edit) / Double(max(1, left.count))
                }
                let termScore = termSetScore(reference: ref.terms, hypothesis: output.terms)

                executed += 1
                summaryCERs.append(summaryCER)
                termsF1s.append(termScore.f1)
                latencies.append(output.latencyMs)

                print("\(item.id)\tok\t\(output.cached)\t\(String(format: "%.3f", summaryCER))\t\(String(format: "%.3f", termScore.f1))\t\(msString(output.latencyMs))")
                try appendJSONLine(
                    VisionCaseLogRow(
                        id: item.id,
                        status: "ok",
                        reason: nil,
                        cached: output.cached,
                        summaryCER: summaryCER,
                        termsPrecision: termScore.precision,
                        termsRecall: termScore.recall,
                        termsF1: termScore.f1,
                        latencyMs: output.latencyMs
                    ),
                    to: rowHandle
                )
            } catch {
                failed += 1
                print("\(item.id)\terror\tfalse\t-\t-\t-")
                try appendJSONLine(
                    VisionCaseLogRow(
                        id: item.id,
                        status: "error",
                        reason: error.localizedDescription,
                        cached: false,
                        summaryCER: nil,
                        termsPrecision: nil,
                        termsRecall: nil,
                        termsF1: nil,
                        latencyMs: nil
                    ),
                    to: rowHandle
                )
            }
        }

        let summary = ComponentSummaryLog(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            benchmark: "vision",
            jsonlPath: options.jsonlPath,
            casesTotal: allCases.count,
            casesSelected: selectedCases.count,
            executedCases: executed,
            skippedCases: skipped,
            failedCases: failed,
            cachedHits: cachedHits,
            exactMatchRate: nil,
            avgCER: summaryCERs.isEmpty ? nil : summaryCERs.reduce(0, +) / Double(summaryCERs.count),
            weightedCER: nil,
            avgLatencyMs: latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count),
            avgAfterStopMs: nil,
            avgTermsF1: termsF1s.isEmpty ? nil : termsF1s.reduce(0, +) / Double(termsF1s.count)
        )
        try writeJSONFile(summary, path: logPaths.summaryPath)

        print("")
        print("summary")
        print("executed_cases: \(executed)")
        print("skipped_cases: \(skipped)")
        print("failed_cases: \(failed)")
        print("cached_hits: \(cachedHits)")
        print("avg_summary_cer: \(summary.avgCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("avg_terms_f1: \(summary.avgTermsF1.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("avg_latency_ms: \(summary.avgLatencyMs.map(msString) ?? "n/a")")
        print("case_rows_log: \(logPaths.rowsPath)")
        print("summary_log: \(logPaths.summaryPath)")
    }

    static func runSTTCaseBenchmark(options: STTBenchmarkOptions) async throws {
        let config = try loadConfig()
        let key = try deepgramAPIKey(from: config)
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases = options.limit.map { Array(allCases.prefix($0)) } ?? allCases
        let logPaths = try prepareComponentBenchmarkLogPaths(
            customDir: options.benchmarkLogDir,
            defaultPrefix: "whisp-sttbench-cases",
            rowsFilename: "stt_case_rows.jsonl",
            summaryFilename: "stt_summary.json"
        )
        let rowHandle = try openWriteHandle(path: logPaths.rowsPath)
        defer { try? rowHandle.close() }

        print("mode: stt_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("stt_mode: \(options.sttMode.rawValue)")
        print("chunk_ms: \(options.chunkMs)")
        print("realtime: \(options.realtime)")
        print("min_audio_seconds: \(String(format: "%.2f", options.minAudioSeconds))")
        print("use_cache: \(options.useCache)")
        print("benchmark_log_dir: \(logPaths.baseDir)")
        print("")
        print("id\tstatus\tcached\texact_match\tcer\taudio_seconds\tstt_total_ms\tstt_after_stop_ms")

        var executed = 0
        var skipped = 0
        var failed = 0
        var cachedHits = 0
        var exactCount = 0
        var cerValues: [Double] = []
        var totalEdits = 0
        var totalRefChars = 0
        var totalLatencies: [Double] = []
        var afterStopLatencies: [Double] = []

        for item in selectedCases {
            guard let reference = item.resolvedSTTReferenceTranscript() else {
                skipped += 1
                print("\(item.id)\tskipped_missing_reference\tfalse\t-\t-\t-\t-\t-")
                try appendJSONLine(
                    STTCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_reference",
                        reason: "参照transcriptがありません",
                        cached: false,
                        transcriptReferenceSource: nil,
                        exactMatch: nil,
                        cer: nil,
                        sttTotalMs: nil,
                        sttAfterStopMs: nil,
                        audioSeconds: nil
                    ),
                    to: rowHandle
                )
                continue
            }
            guard FileManager.default.fileExists(atPath: item.audioFile) else {
                skipped += 1
                print("\(item.id)\tskipped_missing_audio\tfalse\t-\t-\t-\t-\t-")
                try appendJSONLine(
                    STTCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_audio",
                        reason: "audio_file が見つかりません",
                        cached: false,
                        transcriptReferenceSource: reference.source,
                        exactMatch: nil,
                        cer: nil,
                        sttTotalMs: nil,
                        sttAfterStopMs: nil,
                        audioSeconds: nil
                    ),
                    to: rowHandle
                )
                continue
            }

            do {
                let wavData = try Data(contentsOf: URL(fileURLWithPath: item.audioFile))
                let audio = try parsePCM16MonoWAV(wavData)
                let audioSeconds = audioDurationSeconds(audio: audio)
                if audioSeconds < options.minAudioSeconds {
                    skipped += 1
                    print("\(item.id)\tskipped_too_short_audio\tfalse\t-\t-\t\(String(format: "%.2f", audioSeconds))\t-\t-")
                    try appendJSONLine(
                        STTCaseLogRow(
                            id: item.id,
                            status: "skipped_too_short_audio",
                            reason: "audio_seconds(\(String(format: "%.2f", audioSeconds))) < min_audio_seconds(\(String(format: "%.2f", options.minAudioSeconds)))",
                            cached: false,
                            transcriptReferenceSource: reference.source,
                            exactMatch: nil,
                            cer: nil,
                            sttTotalMs: nil,
                            sttAfterStopMs: nil,
                            audioSeconds: audioSeconds
                        ),
                        to: rowHandle
                    )
                    continue
                }

                let audioHash = sha256Hex(data: wavData)
                let cacheKey = sha256Hex(
                    text: "stt-v1|\(options.sttMode.rawValue)|\(options.chunkMs)|\(options.realtime)|\(config.inputLanguage)|\(audioHash)"
                )
                let sttOutput: (transcript: String, totalMs: Double, afterStopMs: Double, cached: Bool)
                if options.useCache,
                   let cached: CachedSTTResult = loadCacheEntry(component: "stt", key: cacheKey)
                {
                    sttOutput = (cached.transcript, cached.totalMs, cached.afterStopMs, true)
                    cachedHits += 1
                } else {
                    let result = try await runSTTInference(
                        apiKey: key,
                        audio: audio,
                        languageHint: config.inputLanguage,
                        mode: options.sttMode,
                        chunkMs: options.chunkMs,
                        realtime: options.realtime
                    )
                    sttOutput = (result.transcript, result.totalMs, result.afterStopMs, false)
                    if options.useCache {
                        let cache = CachedSTTResult(
                            key: cacheKey,
                            mode: options.sttMode.rawValue,
                            transcript: result.transcript,
                            totalMs: result.totalMs,
                            afterStopMs: result.afterStopMs,
                            createdAt: ISO8601DateFormatter().string(from: Date())
                        )
                        try saveCacheEntry(component: "stt", key: cacheKey, value: cache)
                    }
                }

                let refChars = Array(normalizedEvalText(reference.text))
                let hypChars = Array(normalizedEvalText(sttOutput.transcript))
                let edit = levenshteinDistance(refChars, hypChars)
                let cer = Double(edit) / Double(max(1, refChars.count))
                let exact = normalizedEvalText(reference.text) == normalizedEvalText(sttOutput.transcript)

                executed += 1
                if exact { exactCount += 1 }
                cerValues.append(cer)
                totalEdits += edit
                totalRefChars += refChars.count
                totalLatencies.append(sttOutput.totalMs)
                afterStopLatencies.append(sttOutput.afterStopMs)

                print("\(item.id)\tok\t\(sttOutput.cached)\t\(exact)\t\(String(format: "%.3f", cer))\t\(String(format: "%.2f", audioSeconds))\t\(msString(sttOutput.totalMs))\t\(msString(sttOutput.afterStopMs))")
                try appendJSONLine(
                    STTCaseLogRow(
                        id: item.id,
                        status: "ok",
                        reason: nil,
                        cached: sttOutput.cached,
                        transcriptReferenceSource: reference.source,
                        exactMatch: exact,
                        cer: cer,
                        sttTotalMs: sttOutput.totalMs,
                        sttAfterStopMs: sttOutput.afterStopMs,
                        audioSeconds: audioSeconds
                    ),
                    to: rowHandle
                )
            } catch {
                failed += 1
                print("\(item.id)\terror\tfalse\t-\t-\t-\t-\t-")
                try appendJSONLine(
                    STTCaseLogRow(
                        id: item.id,
                        status: "error",
                        reason: error.localizedDescription,
                        cached: false,
                        transcriptReferenceSource: reference.source,
                        exactMatch: nil,
                        cer: nil,
                        sttTotalMs: nil,
                        sttAfterStopMs: nil,
                        audioSeconds: nil
                    ),
                    to: rowHandle
                )
            }
        }

        let exactRate = executed > 0 ? Double(exactCount) / Double(executed) : 0
        let summary = ComponentSummaryLog(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            benchmark: "stt",
            jsonlPath: options.jsonlPath,
            casesTotal: allCases.count,
            casesSelected: selectedCases.count,
            executedCases: executed,
            skippedCases: skipped,
            failedCases: failed,
            cachedHits: cachedHits,
            exactMatchRate: exactRate,
            avgCER: cerValues.isEmpty ? nil : cerValues.reduce(0, +) / Double(cerValues.count),
            weightedCER: totalRefChars > 0 ? Double(totalEdits) / Double(totalRefChars) : nil,
            avgLatencyMs: totalLatencies.isEmpty ? nil : totalLatencies.reduce(0, +) / Double(totalLatencies.count),
            avgAfterStopMs: afterStopLatencies.isEmpty ? nil : afterStopLatencies.reduce(0, +) / Double(afterStopLatencies.count),
            avgTermsF1: nil
        )
        try writeJSONFile(summary, path: logPaths.summaryPath)

        print("")
        print("summary")
        print("executed_cases: \(executed)")
        print("skipped_cases: \(skipped)")
        print("failed_cases: \(failed)")
        print("cached_hits: \(cachedHits)")
        print("exact_match_rate: \(String(format: "%.3f", exactRate))")
        print("avg_cer: \(summary.avgCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("weighted_cer: \(summary.weightedCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("avg_stt_total_ms: \(summary.avgLatencyMs.map(msString) ?? "n/a")")
        print("avg_stt_after_stop_ms: \(summary.avgAfterStopMs.map(msString) ?? "n/a")")
        print("case_rows_log: \(logPaths.rowsPath)")
        print("summary_log: \(logPaths.summaryPath)")
    }

    static func runGenerationCaseBenchmark(options: GenerationBenchmarkOptions) async throws {
        let config = try loadConfig()
        let model = effectivePostProcessModel(config.llmModel)
        let apiKey = try llmAPIKey(config: config, model: model)
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases = options.limit.map { Array(allCases.prefix($0)) } ?? allCases
        let logPaths = try prepareComponentBenchmarkLogPaths(
            customDir: options.benchmarkLogDir,
            defaultPrefix: "whisp-generationbench",
            rowsFilename: "generation_case_rows.jsonl",
            summaryFilename: "generation_summary.json"
        )
        let rowHandle = try openWriteHandle(path: logPaths.rowsPath)
        defer { try? rowHandle.close() }

        print("mode: generation_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("model: \(model.rawValue)")
        print("require_context: \(options.requireContext)")
        print("use_cache: \(options.useCache)")
        print("benchmark_log_dir: \(logPaths.baseDir)")
        print("")
        print("id\tstatus\tcached\texact_match\tcer\tpost_ms\toutput_chars")

        var executed = 0
        var skipped = 0
        var failed = 0
        var cachedHits = 0
        var exactCount = 0
        var cerValues: [Double] = []
        var totalEdits = 0
        var totalRefChars = 0
        var postLatencies: [Double] = []

        for item in selectedCases {
            guard let input = item.resolvedGenerationInputSTT() else {
                skipped += 1
                print("\(item.id)\tskipped_missing_input_stt\tfalse\t-\t-\t-\t-")
                try appendJSONLine(
                    GenerationCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_input_stt",
                        reason: "stt入力がありません",
                        cached: false,
                        inputSource: nil,
                        referenceSource: nil,
                        exactMatch: nil,
                        cer: nil,
                        postMs: nil,
                        outputChars: nil
                    ),
                    to: rowHandle
                )
                continue
            }
            guard let reference = item.resolvedGenerationReferenceText() else {
                skipped += 1
                print("\(item.id)\tskipped_missing_reference\tfalse\t-\t-\t-\t-")
                try appendJSONLine(
                    GenerationCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_reference",
                        reason: "参照テキストがありません",
                        cached: false,
                        inputSource: input.source,
                        referenceSource: nil,
                        exactMatch: nil,
                        cer: nil,
                        postMs: nil,
                        outputChars: nil
                    ),
                    to: rowHandle
                )
                continue
            }
            if options.requireContext, item.context == nil {
                skipped += 1
                print("\(item.id)\tskipped_missing_context\tfalse\t-\t-\t-\t-")
                try appendJSONLine(
                    GenerationCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_context",
                        reason: "--require-context が指定されています",
                        cached: false,
                        inputSource: input.source,
                        referenceSource: reference.source,
                        exactMatch: nil,
                        cer: nil,
                        postMs: nil,
                        outputChars: nil
                    ),
                    to: rowHandle
                )
                continue
            }

            do {
                let contextHash = sha256Hex(text: canonicalContextString(item.context))
                let inputHash = sha256Hex(text: input.text)
                let cacheKey = sha256Hex(text: "generation-v1|\(model.rawValue)|\(config.inputLanguage)|\(inputHash)|\(contextHash)")
                let generation: (output: String, postMs: Double, cached: Bool)
                if options.useCache,
                   let cached: CachedGenerationResult = loadCacheEntry(component: "generation", key: cacheKey)
                {
                    generation = (cached.output, cached.postMs, true)
                    cachedHits += 1
                } else {
                    let startedAt = DispatchTime.now()
                    let result = try await postProcessText(
                        model: model,
                        apiKey: apiKey,
                        config: config,
                        sttText: input.text,
                        context: item.context,
                        sttMode: "generation_benchmark"
                    )
                    let postMs = elapsedMs(since: startedAt)
                    generation = (result.text, postMs, false)
                    if options.useCache {
                        let cache = CachedGenerationResult(
                            key: cacheKey,
                            model: model.rawValue,
                            output: result.text,
                            postMs: postMs,
                            createdAt: ISO8601DateFormatter().string(from: Date())
                        )
                        try saveCacheEntry(component: "generation", key: cacheKey, value: cache)
                    }
                }

                let refChars = Array(normalizedEvalText(reference.text))
                let outChars = Array(normalizedEvalText(generation.output))
                let edit = levenshteinDistance(refChars, outChars)
                let cer = Double(edit) / Double(max(1, refChars.count))
                let exact = normalizedEvalText(reference.text) == normalizedEvalText(generation.output)

                executed += 1
                if exact { exactCount += 1 }
                cerValues.append(cer)
                totalEdits += edit
                totalRefChars += refChars.count
                postLatencies.append(generation.postMs)

                print("\(item.id)\tok\t\(generation.cached)\t\(exact)\t\(String(format: "%.3f", cer))\t\(msString(generation.postMs))\t\(outChars.count)")
                try appendJSONLine(
                    GenerationCaseLogRow(
                        id: item.id,
                        status: "ok",
                        reason: nil,
                        cached: generation.cached,
                        inputSource: input.source,
                        referenceSource: reference.source,
                        exactMatch: exact,
                        cer: cer,
                        postMs: generation.postMs,
                        outputChars: outChars.count
                    ),
                    to: rowHandle
                )
            } catch {
                failed += 1
                print("\(item.id)\terror\tfalse\t-\t-\t-\t-")
                try appendJSONLine(
                    GenerationCaseLogRow(
                        id: item.id,
                        status: "error",
                        reason: error.localizedDescription,
                        cached: false,
                        inputSource: input.source,
                        referenceSource: reference.source,
                        exactMatch: nil,
                        cer: nil,
                        postMs: nil,
                        outputChars: nil
                    ),
                    to: rowHandle
                )
            }
        }

        let exactRate = executed > 0 ? Double(exactCount) / Double(executed) : 0
        let summary = ComponentSummaryLog(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            benchmark: "generation",
            jsonlPath: options.jsonlPath,
            casesTotal: allCases.count,
            casesSelected: selectedCases.count,
            executedCases: executed,
            skippedCases: skipped,
            failedCases: failed,
            cachedHits: cachedHits,
            exactMatchRate: exactRate,
            avgCER: cerValues.isEmpty ? nil : cerValues.reduce(0, +) / Double(cerValues.count),
            weightedCER: totalRefChars > 0 ? Double(totalEdits) / Double(totalRefChars) : nil,
            avgLatencyMs: postLatencies.isEmpty ? nil : postLatencies.reduce(0, +) / Double(postLatencies.count),
            avgAfterStopMs: nil,
            avgTermsF1: nil
        )
        try writeJSONFile(summary, path: logPaths.summaryPath)

        print("")
        print("summary")
        print("executed_cases: \(executed)")
        print("skipped_cases: \(skipped)")
        print("failed_cases: \(failed)")
        print("cached_hits: \(cachedHits)")
        print("exact_match_rate: \(String(format: "%.3f", exactRate))")
        print("avg_cer: \(summary.avgCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("weighted_cer: \(summary.weightedCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("avg_post_ms: \(summary.avgLatencyMs.map(msString) ?? "n/a")")
        print("case_rows_log: \(logPaths.rowsPath)")
        print("summary_log: \(logPaths.summaryPath)")
    }

    static func executePipelineRun(
        config: Config,
        options: PipelineOptions,
        context: ContextInfo?
    ) async throws -> PipelineRunResult {
        let deepgramKey = try deepgramAPIKey(from: config)
        let model = effectivePostProcessModel(config.llmModel)
        let llmKey = try llmAPIKey(config: config, model: model)

        let wavData = try Data(contentsOf: URL(fileURLWithPath: options.path))
        let audio = try parsePCM16MonoWAV(wavData)
        let sampleRate = Int(audio.sampleRate)
        let language = languageParam(config.inputLanguage)

        var sttText = ""
        var sttSource = ""
        var sttTotalMs = 0.0
        var sttAfterStopMs = 0.0
        var sttSendMs = 0.0
        var sttFinalizeMs = 0.0

        let wallStartedAt = DispatchTime.now()

        switch options.sttMode {
        case .rest:
            let sttStartedAt = DispatchTime.now()
            let result = try await DeepgramClient().transcribe(
                apiKey: deepgramKey,
                sampleRate: sampleRate,
                audio: audio.pcmBytes,
                language: language
            )
            sttText = result.transcript
            sttSource = "rest"
            sttTotalMs = elapsedMs(since: sttStartedAt)
            sttAfterStopMs = sttTotalMs
            sttFinalizeMs = sttTotalMs
        case .stream:
            let stream = DeepgramStreamingClient()
            let chunkSamples = max(1, sampleRate * options.chunkMs / 1000)
            let chunkBytes = chunkSamples * MemoryLayout<Int16>.size

            try await stream.start(apiKey: deepgramKey, sampleRate: sampleRate, language: language)
            let sendStartedAt = DispatchTime.now()
            var offset = 0
            while offset < audio.pcmBytes.count {
                let end = min(offset + chunkBytes, audio.pcmBytes.count)
                await stream.enqueueAudioChunk(audio.pcmBytes.subdata(in: offset..<end))

                if options.realtime {
                    let frameCount = (end - offset) / MemoryLayout<Int16>.size
                    let seconds = Double(frameCount) / Double(sampleRate)
                    let nanoseconds = UInt64(seconds * 1_000_000_000)
                    if nanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: nanoseconds)
                    }
                }
                offset = end
            }
            sttSendMs = elapsedMs(since: sendStartedAt)

            let finalizeStartedAt = DispatchTime.now()
            let result = try await stream.finish()
            sttFinalizeMs = elapsedMs(since: finalizeStartedAt)

            sttText = result.transcript
            sttSource = "stream"
            sttTotalMs = sttSendMs + sttFinalizeMs
            sttAfterStopMs = sttFinalizeMs
        }

        let postStartedAt = DispatchTime.now()
        let postResult = try await postProcessText(
            model: model,
            apiKey: llmKey,
            config: config,
            sttText: sttText,
            context: context,
            sttMode: options.sttMode.rawValue
        )
        let postMs = elapsedMs(since: postStartedAt)

        let outputStartedAt = DispatchTime.now()
        try emitResult(postResult.text, mode: options.emitMode)
        let outputMs = elapsedMs(since: outputStartedAt)

        let totalAfterStopMs = sttAfterStopMs + postMs + outputMs
        let totalWallMs = elapsedMs(since: wallStartedAt)
        return PipelineRunResult(
            model: model,
            sttText: sttText,
            outputText: postResult.text,
            sttSource: sttSource,
            sttSendMs: sttSendMs,
            sttFinalizeMs: sttFinalizeMs,
            sttTotalMs: sttTotalMs,
            sttAfterStopMs: sttAfterStopMs,
            postMs: postMs,
            outputMs: outputMs,
            totalAfterStopMs: totalAfterStopMs,
            totalWallMs: totalWallMs,
            audioSeconds: audioDurationSeconds(audio: audio)
        )
    }
}
