import Foundation
import WhispCore

extension WhispCLI {
    static func runSTTCaseBenchmark(options: STTBenchmarkOptions) async throws {
        let config = try loadConfig()
        let key = try APIKeyResolver.sttKey(config: config, provider: .deepgram)
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

}
