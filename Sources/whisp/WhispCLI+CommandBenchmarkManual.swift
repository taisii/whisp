import Foundation
import WhispCore

extension WhispCLI {
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
        print("llm_eval: \(options.llmEvalEnabled)")
        print("llm_eval_model: \(options.llmEvalModel?.rawValue ?? "auto")")
        print("benchmark_log_dir: \(logPaths.baseDir)")
        print("")
        print("id\tstatus\tcontext\tvision_image\texact_match\tcer\tintent_match\tintent_score\tintent_preservation\thallucination_rate\taudio_seconds\tstt_total_ms\tstt_after_stop_ms\tpost_ms\ttotal_after_stop_ms")

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
        var llmEvalContext: (model: LLMModel, apiKey: String)?
        var llmEvalUnavailableReason: String?
        var llmEvalErrorCases = 0

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
                            judgeContext = try APIKeyResolver.resolveIntentJudgeContext(
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

                var intentPreservationScore: Double?
                var hallucinationScore: Double?
                var hallucinationRate: Double?
                var llmEvalError: String?
                if options.llmEvalEnabled {
                    if llmEvalContext == nil, llmEvalUnavailableReason == nil {
                        do {
                            llmEvalContext = try APIKeyResolver.resolveIntentJudgeContext(
                                config: config,
                                preferredModel: options.llmEvalModel
                            )
                        } catch {
                            llmEvalUnavailableReason = error.localizedDescription
                        }
                    }
                    if let llmEvalContext {
                        do {
                            let evaluation = try await runLLMEvaluation(
                                model: llmEvalContext.model,
                                apiKey: llmEvalContext.apiKey,
                                referenceText: transcriptRef.text,
                                hypothesisText: output,
                                context: item.context
                            )
                            intentPreservationScore = evaluation.intentPreservationScore
                            hallucinationScore = evaluation.hallucinationScore
                            hallucinationRate = evaluation.hallucinationRate
                        } catch {
                            llmEvalError = error.localizedDescription
                            llmEvalErrorCases += 1
                        }
                    } else if let reason = llmEvalUnavailableReason {
                        llmEvalError = reason
                        llmEvalErrorCases += 1
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
                    sttTotalMs: run.sttTotalMs,
                    sttAfterStopMs: run.sttAfterStopMs,
                    postMs: run.postMs,
                    totalAfterStopMs: run.totalAfterStopMs,
                    audioSeconds: audioSeconds,
                    transcriptSource: transcriptRef.source,
                    intentReferenceSource: intentReference?.source,
                    intentMatch: intentMatch,
                    intentScore: intentScore,
                    intentPreservationScore: intentPreservationScore,
                    hallucinationScore: hallucinationScore,
                    hallucinationRate: hallucinationRate,
                    llmEvalError: llmEvalError
                )
                evaluations.append(row)
                print("\(item.id)\tok\t\(row.contextUsed)\t\(row.visionImageAttached)\t\(row.exactMatch)\t\(String(format: "%.3f", row.cer))\t\(row.intentMatch.map { String($0) } ?? "-")\t\(row.intentScore.map(String.init) ?? "-")\t\(row.intentPreservationScore.map { String(format: "%.3f", $0) } ?? "-")\t\(row.hallucinationRate.map { String(format: "%.3f", $0) } ?? "-")\t\(String(format: "%.2f", row.audioSeconds))\t\(msString(row.sttTotalMs))\t\(msString(row.sttAfterStopMs))\t\(msString(row.postMs))\t\(msString(row.totalAfterStopMs))")
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
                        intentPreservationScore: row.intentPreservationScore,
                        hallucinationScore: row.hallucinationScore,
                        hallucinationRate: row.hallucinationRate,
                        llmEvalError: row.llmEvalError,
                        sttTotalMs: row.sttTotalMs,
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
        let sttTotalDistribution = latencyDistribution(values: evaluations.map(\.sttTotalMs))
        let sttAfterStopDistribution = latencyDistribution(values: evaluations.map(\.sttAfterStopMs))
        let postDistribution = latencyDistribution(values: evaluations.map(\.postMs))
        let totalAfterStopDistribution = latencyDistribution(values: evaluations.map(\.totalAfterStopMs))
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
        let llmEvalRows = evaluations.filter {
            $0.intentPreservationScore != nil || $0.hallucinationScore != nil || $0.hallucinationRate != nil
        }
        let llmEvalEvaluatedCases = llmEvalRows.count
        let intentPreservationScore = llmEvalRows.compactMap(\.intentPreservationScore)
        let hallucinationScore = llmEvalRows.compactMap(\.hallucinationScore)
        let hallucinationRate = llmEvalRows.compactMap(\.hallucinationRate)

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
            llmEvalEnabled: options.llmEvalEnabled,
            llmEvalModel: llmEvalContext?.model.rawValue ?? options.llmEvalModel?.rawValue,
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
            llmEvalEvaluatedCases: llmEvalEvaluatedCases,
            llmEvalErrorCases: llmEvalErrorCases,
            intentPreservationScore: intentPreservationScore.isEmpty ? nil : intentPreservationScore.reduce(0, +) / Double(intentPreservationScore.count),
            hallucinationScore: hallucinationScore.isEmpty ? nil : hallucinationScore.reduce(0, +) / Double(hallucinationScore.count),
            hallucinationRate: hallucinationRate.isEmpty ? nil : hallucinationRate.reduce(0, +) / Double(hallucinationRate.count),
            sttTotalMs: sttTotalDistribution,
            sttAfterStopMs: sttAfterStopDistribution,
            postMs: postDistribution,
            totalAfterStopMs: totalAfterStopDistribution
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
        if let sttTotal = summaryLog.sttTotalMs {
            print("stt_total_ms: avg=\(sttTotal.avg.map(msString) ?? "n/a") p50=\(sttTotal.p50.map(msString) ?? "n/a") p95=\(sttTotal.p95.map(msString) ?? "n/a") p99=\(sttTotal.p99.map(msString) ?? "n/a")")
        } else {
            print("stt_total_ms: n/a")
        }
        if let sttAfterStop = summaryLog.sttAfterStopMs {
            print("stt_after_stop_ms: avg=\(sttAfterStop.avg.map(msString) ?? "n/a") p50=\(sttAfterStop.p50.map(msString) ?? "n/a") p95=\(sttAfterStop.p95.map(msString) ?? "n/a") p99=\(sttAfterStop.p99.map(msString) ?? "n/a")")
        } else {
            print("stt_after_stop_ms: n/a")
        }
        if let post = summaryLog.postMs {
            print("post_ms: avg=\(post.avg.map(msString) ?? "n/a") p50=\(post.p50.map(msString) ?? "n/a") p95=\(post.p95.map(msString) ?? "n/a") p99=\(post.p99.map(msString) ?? "n/a")")
        } else {
            print("post_ms: n/a")
        }
        if let total = summaryLog.totalAfterStopMs {
            print("total_after_stop_ms: avg=\(total.avg.map(msString) ?? "n/a") p50=\(total.p50.map(msString) ?? "n/a") p95=\(total.p95.map(msString) ?? "n/a") p99=\(total.p99.map(msString) ?? "n/a")")
        } else {
            print("total_after_stop_ms: n/a")
        }
        print("llm_eval_evaluated_cases: \(summaryLog.llmEvalEvaluatedCases)")
        print("llm_eval_error_cases: \(summaryLog.llmEvalErrorCases)")
        print("intent_preservation_score: \(summaryLog.intentPreservationScore.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("hallucination_score: \(summaryLog.hallucinationScore.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("hallucination_rate: \(summaryLog.hallucinationRate.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("case_rows_log: \(logPaths.caseRowsPath)")
        print("summary_log: \(logPaths.summaryPath)")
        if let judgeUnavailableReason {
            print("intent_judge_note: \(judgeUnavailableReason)")
        }
        if let llmEvalUnavailableReason {
            print("llm_eval_note: \(llmEvalUnavailableReason)")
        }

        _ = importLegacyBenchmarkLogs(
            kind: .e2e,
            rowsPath: logPaths.caseRowsPath,
            summaryPath: logPaths.summaryPath,
            logDirectoryPath: logPaths.baseDir,
            options: BenchmarkRunOptions(
                sourceCasesPath: options.jsonlPath,
                sttMode: options.sttMode.rawValue,
                chunkMs: options.chunkMs,
                realtime: options.realtime,
                requireContext: options.requireContext,
                minAudioSeconds: options.minAudioSeconds,
                minLabelConfidence: options.minLabelConfidence,
                intentSource: options.intentSource.rawValue,
                intentJudgeEnabled: options.intentJudgeEnabled,
                intentJudgeModel: options.intentJudgeModel?.rawValue,
                llmEvalEnabled: options.llmEvalEnabled,
                llmEvalModel: llmEvalContext?.model.rawValue ?? options.llmEvalModel?.rawValue,
                caseLimit: options.limit
            )
        )
    }

}
