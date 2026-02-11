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
                caseLimit: options.limit
            )
        )
    }

}
