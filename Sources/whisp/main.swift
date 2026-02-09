import Foundation
import WhispCore

private enum STTMode: String {
    case rest
    case stream
}

private enum EmitMode: String {
    case discard
    case stdout
    case pbcopy
}

private struct PipelineOptions {
    let path: String
    let sttMode: STTMode
    let chunkMs: Int
    let realtime: Bool
    let emitMode: EmitMode
    let contextFilePath: String?
}

private struct PipelineRunResult {
    let model: LLMModel
    let sttText: String
    let outputText: String
    let sttSource: String
    let sttSendMs: Double
    let sttFinalizeMs: Double
    let sttTotalMs: Double
    let sttAfterStopMs: Double
    let postMs: Double
    let outputMs: Double
    let totalAfterStopMs: Double
    let totalWallMs: Double
    let audioSeconds: Double
}

private struct ManualBenchmarkOptions {
    let jsonlPath: String
    let sttMode: STTMode
    let chunkMs: Int
    let realtime: Bool
    let limit: Int?
    let requireContext: Bool
}

private struct ManualBenchmarkCase: Decodable {
    let id: String
    let runID: String?
    let audioFile: String
    let sttText: String?
    let outputText: String?
    let groundTruthText: String
    let createdAt: String?
    let llmModel: String?
    let appName: String?
    let context: ContextInfo?
    let visionImageFile: String?
    let visionImageMimeType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case audioFile = "audio_file"
        case sttText = "stt_text"
        case outputText = "output_text"
        case groundTruthText = "ground_truth_text"
        case createdAt = "created_at"
        case llmModel = "llm_model"
        case appName = "app_name"
        case context
        case visionImageFile = "vision_image_file"
        case visionImageMimeType = "vision_image_mime_type"
    }
}

private struct ManualCaseEvaluation {
    let id: String
    let status: String
    let contextUsed: Bool
    let visionImageAttached: Bool
    let exactMatch: Bool
    let cer: Double
    let gtChars: Int
    let editDistance: Int
    let sttAfterStopMs: Double
    let postMs: Double
    let totalAfterStopMs: Double
}

private struct GeminiTextPart: Encodable {
    let text: String
}

private struct GeminiTextContent: Encodable {
    let role: String
    let parts: [GeminiTextPart]
}

private struct GeminiTextRequest: Encodable {
    let contents: [GeminiTextContent]
}

private struct OpenAITextMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAITextRequest: Encodable {
    let model: String
    let messages: [OpenAITextMessage]
}

@main
struct WhispCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.first == "--self-check" {
            let ok = formatShortcutDisplay("Cmd+J") == "⌘ J" && !isEmptySTT("テスト")
            print(ok ? "ok" : "ng")
            exit(ok ? 0 : 1)
        }

        if args.count == 2 && args[0] == "--stt-file" {
            do {
                try await runSTTFile(path: args[1])
                exit(0)
            } catch {
                fputs("stt-check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.count >= 2 && args[0] == "--stt-stream-file" {
            do {
                let options = try parseStreamOptions(args: args)
                try await runSTTStreamFile(
                    path: options.path,
                    chunkMs: options.chunkMs,
                    realtime: options.realtime
                )
                exit(0)
            } catch {
                fputs("stt-stream-check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.count >= 2 && args[0] == "--pipeline-file" {
            do {
                let options = try parsePipelineOptions(args: args)
                try await runPipelineFile(options: options)
                exit(0)
            } catch {
                fputs("pipeline-check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.first == "--benchmark-manual-cases" {
            do {
                let options = try parseManualBenchmarkOptions(args: args)
                try await runManualCaseBenchmark(options: options)
                exit(0)
            } catch {
                fputs("manual-benchmark failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        print("whisp (Swift) ready")
        print("usage: whisp --self-check")
        print("usage: whisp --stt-file /path/to/input.wav")
        print("usage: whisp --stt-stream-file /path/to/input.wav [--chunk-ms N] [--realtime]")
        print("usage: whisp --pipeline-file /path/to/input.wav [--stt rest|stream] [--chunk-ms N] [--realtime] [--emit discard|stdout|pbcopy] [--context-file /path/to/context.json]")
        print("usage: whisp --benchmark-manual-cases [/path/to/manual_test_cases.jsonl] [--stt rest|stream] [--chunk-ms N] [--realtime|--no-realtime] [--limit N] [--require-context]")
    }

    private static func runSTTFile(path: String) async throws {
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

    private static func runSTTStreamFile(path: String, chunkMs: Int, realtime: Bool) async throws {
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

    private static func runPipelineFile(options: PipelineOptions) async throws {
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

    private static func runManualCaseBenchmark(options: ManualBenchmarkOptions) async throws {
        let config = try loadConfig()
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases: [ManualBenchmarkCase]
        if let limit = options.limit {
            selectedCases = Array(allCases.prefix(limit))
        } else {
            selectedCases = allCases
        }

        print("mode: manual_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("stt_mode: \(options.sttMode.rawValue)")
        print("chunk_ms: \(options.chunkMs)")
        print("realtime: \(options.realtime)")
        print("require_context: \(options.requireContext)")
        print("")
        print("id\tstatus\tcontext\tvision_image\texact_match\tcer\tstt_after_stop_ms\tpost_ms\ttotal_after_stop_ms")

        var evaluations: [ManualCaseEvaluation] = []
        var skippedMissingAudio = 0
        var skippedMissingGroundTruth = 0
        var skippedMissingContext = 0
        var failedRuns = 0

        for item in selectedCases {
            let groundTruth = normalizedEvalText(item.groundTruthText)
            if groundTruth.isEmpty {
                skippedMissingGroundTruth += 1
                print("\(item.id)\tskipped_missing_ground_truth\t\(item.context != nil)\t\(item.visionImageFile != nil)\t-\t-\t-\t-\t-")
                continue
            }
            if !FileManager.default.fileExists(atPath: item.audioFile) {
                skippedMissingAudio += 1
                print("\(item.id)\tskipped_missing_audio\t\(item.context != nil)\t\(item.visionImageFile != nil)\t-\t-\t-\t-\t-")
                continue
            }
            if options.requireContext && item.context == nil {
                skippedMissingContext += 1
                print("\(item.id)\tskipped_missing_context\tfalse\t\(item.visionImageFile != nil)\t-\t-\t-\t-\t-")
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
                let gtChars = Array(groundTruth)
                let outChars = Array(output)
                let editDistance = levenshteinDistance(gtChars, outChars)
                let cer = Double(editDistance) / Double(max(1, gtChars.count))
                let exactMatch = output == groundTruth

                let row = ManualCaseEvaluation(
                    id: item.id,
                    status: "ok",
                    contextUsed: item.context != nil,
                    visionImageAttached: item.visionImageFile != nil,
                    exactMatch: exactMatch,
                    cer: cer,
                    gtChars: gtChars.count,
                    editDistance: editDistance,
                    sttAfterStopMs: run.sttAfterStopMs,
                    postMs: run.postMs,
                    totalAfterStopMs: run.totalAfterStopMs
                )
                evaluations.append(row)
                print("\(item.id)\tok\t\(row.contextUsed)\t\(row.visionImageAttached)\t\(row.exactMatch)\t\(String(format: "%.3f", row.cer))\t\(msString(row.sttAfterStopMs))\t\(msString(row.postMs))\t\(msString(row.totalAfterStopMs))")
            } catch {
                failedRuns += 1
                print("\(item.id)\terror\t\(item.context != nil)\t\(item.visionImageFile != nil)\t-\t-\t-\t-\t-")
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

        print("")
        print("summary")
        print("executed_cases: \(executed)")
        print("skipped_missing_audio: \(skippedMissingAudio)")
        print("skipped_missing_ground_truth: \(skippedMissingGroundTruth)")
        print("skipped_missing_context: \(skippedMissingContext)")
        print("failed_runs: \(failedRuns)")
        print("exact_match_cases: \(exactCount)")
        print("exact_match_rate: \(String(format: "%.3f", exactRate))")
        print("avg_cer: \(String(format: "%.3f", avgCER))")
        print("weighted_cer: \(String(format: "%.3f", weightedCER))")
        print("avg_stt_after_stop_ms: \(msString(avgSttAfterStop))")
        print("avg_post_ms: \(msString(avgPost))")
        print("avg_total_after_stop_ms: \(msString(avgTotalAfterStop))")
    }

    private static func executePipelineRun(
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

    private struct StreamOptions {
        let path: String
        let chunkMs: Int
        let realtime: Bool
    }

    private static func parseStreamOptions(args: [String]) throws -> StreamOptions {
        guard args.count >= 2 else {
            throw AppError.invalidArgument("入力ファイルパスが必要です")
        }

        let path = args[1]
        var chunkMs = 120
        var realtime = false
        var index = 2

        while index < args.count {
            let item = args[index]
            if item == "--realtime" {
                realtime = true
                index += 1
                continue
            }
            if item == "--chunk-ms" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--chunk-ms の値が不足しています")
                }
                guard let parsed = Int(args[valueIndex]), parsed > 0 else {
                    throw AppError.invalidArgument("--chunk-ms は正の整数で指定してください")
                }
                chunkMs = parsed
                index += 2
                continue
            }
            if item.hasPrefix("--chunk-ms=") {
                let value = String(item.dropFirst("--chunk-ms=".count))
                guard let parsed = Int(value), parsed > 0 else {
                    throw AppError.invalidArgument("--chunk-ms は正の整数で指定してください")
                }
                chunkMs = parsed
                index += 1
                continue
            }
            throw AppError.invalidArgument("不明な引数: \(item)")
        }

        return StreamOptions(path: path, chunkMs: chunkMs, realtime: realtime)
    }

    private static func parsePipelineOptions(args: [String]) throws -> PipelineOptions {
        guard args.count >= 2 else {
            throw AppError.invalidArgument("入力ファイルパスが必要です")
        }

        let path = args[1]
        var sttMode: STTMode = .stream
        var chunkMs = 120
        var realtime = true
        var emitMode: EmitMode = .discard
        var contextFilePath: String?
        var index = 2

        while index < args.count {
            let item = args[index]
            if item == "--realtime" {
                realtime = true
                index += 1
                continue
            }
            if item == "--no-realtime" {
                realtime = false
                index += 1
                continue
            }
            if item == "--chunk-ms" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--chunk-ms の値が不足しています")
                }
                guard let parsed = Int(args[valueIndex]), parsed > 0 else {
                    throw AppError.invalidArgument("--chunk-ms は正の整数で指定してください")
                }
                chunkMs = parsed
                index += 2
                continue
            }
            if item == "--stt" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--stt の値が不足しています")
                }
                guard let parsed = STTMode(rawValue: args[valueIndex]) else {
                    throw AppError.invalidArgument("--stt は rest または stream を指定してください")
                }
                sttMode = parsed
                index += 2
                continue
            }
            if item == "--emit" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--emit の値が不足しています")
                }
                guard let parsed = EmitMode(rawValue: args[valueIndex]) else {
                    throw AppError.invalidArgument("--emit は discard/stdout/pbcopy を指定してください")
                }
                emitMode = parsed
                index += 2
                continue
            }
            if item == "--context-file" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--context-file の値が不足しています")
                }
                contextFilePath = args[valueIndex]
                index += 2
                continue
            }
            throw AppError.invalidArgument("不明な引数: \(item)")
        }

        return PipelineOptions(
            path: path,
            sttMode: sttMode,
            chunkMs: chunkMs,
            realtime: realtime,
            emitMode: emitMode,
            contextFilePath: contextFilePath
        )
    }

    private static func parseManualBenchmarkOptions(args: [String]) throws -> ManualBenchmarkOptions {
        var jsonlPath = defaultManualCasesPath()
        var sttMode: STTMode = .stream
        var chunkMs = 120
        var realtime = true
        var limit: Int?
        var requireContext = false
        var index = 1

        while index < args.count {
            let item = args[index]
            if item == "--realtime" {
                realtime = true
                index += 1
                continue
            }
            if item == "--no-realtime" {
                realtime = false
                index += 1
                continue
            }
            if item == "--chunk-ms" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--chunk-ms の値が不足しています")
                }
                guard let parsed = Int(args[valueIndex]), parsed > 0 else {
                    throw AppError.invalidArgument("--chunk-ms は正の整数で指定してください")
                }
                chunkMs = parsed
                index += 2
                continue
            }
            if item == "--stt" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--stt の値が不足しています")
                }
                guard let parsed = STTMode(rawValue: args[valueIndex]) else {
                    throw AppError.invalidArgument("--stt は rest または stream を指定してください")
                }
                sttMode = parsed
                index += 2
                continue
            }
            if item == "--limit" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--limit の値が不足しています")
                }
                guard let parsed = Int(args[valueIndex]), parsed > 0 else {
                    throw AppError.invalidArgument("--limit は正の整数で指定してください")
                }
                limit = parsed
                index += 2
                continue
            }
            if item == "--require-context" {
                requireContext = true
                index += 1
                continue
            }
            if item.hasPrefix("--") {
                throw AppError.invalidArgument("不明な引数: \(item)")
            }

            jsonlPath = item
            index += 1
        }

        return ManualBenchmarkOptions(
            jsonlPath: jsonlPath,
            sttMode: sttMode,
            chunkMs: chunkMs,
            realtime: realtime,
            limit: limit,
            requireContext: requireContext
        )
    }

    private static func loadManualBenchmarkCases(path: String) throws -> [ManualBenchmarkCase] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidArgument("manual test case path が空です")
        }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            throw AppError.invalidArgument("manual test case file が見つかりません: \(trimmed)")
        }

        let content = try String(contentsOfFile: trimmed, encoding: .utf8)
        var results: [ManualBenchmarkCase] = []
        let decoder = JSONDecoder()

        for (index, rawLine) in content.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            guard let data = line.data(using: .utf8) else {
                throw AppError.invalidArgument("JSONLの読み込みに失敗しました(line=\(index + 1))")
            }
            do {
                let item = try decoder.decode(ManualBenchmarkCase.self, from: data)
                results.append(item)
            } catch {
                throw AppError.invalidArgument("JSONLのデコードに失敗しました(line=\(index + 1)): \(error.localizedDescription)")
            }
        }
        return results
    }

    private static func loadConfig() throws -> Config {
        let configStore = try ConfigStore()
        return try configStore.loadOrCreate()
    }

    private static func deepgramAPIKey(from config: Config) throws -> String {
        let key = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AppError.invalidArgument("Deepgram APIキーが未設定です")
        }
        return key
    }

    private static func llmAPIKey(config: Config, model: LLMModel) throws -> String {
        switch model {
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            let key = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AppError.invalidArgument("Gemini APIキーが未設定です")
            }
            return key
        case .gpt4oMini, .gpt5Nano:
            let key = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AppError.invalidArgument("OpenAI APIキーが未設定です")
            }
            return key
        }
    }

    private static func effectivePostProcessModel(_ model: LLMModel) -> LLMModel {
        switch model {
        case .gemini25FlashLiteAudio:
            return .gemini25FlashLite
        default:
            return model
        }
    }

    private static func postProcessText(
        model: LLMModel,
        apiKey: String,
        config: Config,
        sttText: String,
        context: ContextInfo?,
        sttMode: String
    ) async throws -> PostProcessResult {
        let prompt = buildPrompt(
            sttResult: sttText,
            languageHint: config.inputLanguage,
            appName: nil,
            appPromptRules: config.appPromptRules,
            context: context
        )
        PromptTrace.dump(
            stage: "pipeline_benchmark_postprocess",
            model: model.rawValue,
            appName: nil,
            context: context,
            prompt: prompt,
            extra: [
                "stt_mode": sttMode,
                "stt_chars": String(sttText.count),
                "language_hint": config.inputLanguage,
            ]
        )

        switch model {
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            let body = GeminiTextRequest(contents: [
                GeminiTextContent(role: "user", parts: [GeminiTextPart(text: prompt)]),
            ])
            let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(LLMModel.gemini25FlashLite.modelName):generateContent?key=\(apiKey)"
            guard let url = URL(string: endpoint) else {
                throw AppError.invalidArgument("Gemini URL生成に失敗")
            }
            let data = try await sendJSONRequest(url: url, headers: [:], body: body)
            let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
            let text = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let usage = decoded.usageMetadata.map {
                LLMUsage(model: LLMModel.gemini25FlashLite.modelName, promptTokens: $0.promptTokenCount, completionTokens: $0.candidatesTokenCount)
            }
            return PostProcessResult(text: text, usage: usage)
        case .gpt4oMini, .gpt5Nano:
            let body = OpenAITextRequest(model: model.modelName, messages: [OpenAITextMessage(role: "user", content: prompt)])
            guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
                throw AppError.invalidArgument("OpenAI URL生成に失敗")
            }
            let headers = ["Authorization": "Bearer \(apiKey)"]
            let data = try await sendJSONRequest(url: url, headers: headers, body: body)
            let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let usage = decoded.usage.map {
                LLMUsage(model: model.modelName, promptTokens: $0.promptTokens, completionTokens: $0.completionTokens)
            }
            return PostProcessResult(text: text, usage: usage)
        }
    }

    private static func loadContextInfo(path: String?) throws -> ContextInfo? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: trimmed))
        return try JSONDecoder().decode(ContextInfo.self, from: data)
    }

    private static func defaultManualCasesPath() -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("manual_test_cases.jsonl", isDirectory: false)
            .path
    }

    private static func normalizedEvalText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func levenshteinDistance(_ left: [Character], _ right: [Character]) -> Int {
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let substitutionCost = left[i - 1] == right[j - 1] ? 0 : 1
                let deletion = previous[j] + 1
                let insertion = current[j - 1] + 1
                let substitution = previous[j - 1] + substitutionCost
                current[j] = min(deletion, insertion, substitution)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    private static func sendJSONRequest<T: Encodable>(
        url: URL,
        headers: [String: String],
        body: T
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.io("HTTPレスポンスが不正")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AppError.io("API request failed (\(http.statusCode)): \(bodyText)")
        }
        return data
    }

    private static func emitResult(_ text: String, mode: EmitMode) throws {
        switch mode {
        case .discard:
            return
        case .stdout:
            print("output: \(text)")
        case .pbcopy:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            if let data = text.data(using: .utf8) {
                pipe.fileHandleForWriting.write(data)
            }
            pipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw AppError.io("pbcopy failed")
            }
        }
    }

    private static func dominantStage(sttAfterStopMs: Double, postMs: Double, outputMs: Double) -> String {
        var stage = "stt_after_stop"
        var maxValue = sttAfterStopMs
        if postMs > maxValue {
            stage = "post"
            maxValue = postMs
        }
        if outputMs > maxValue {
            stage = "output"
        }
        return stage
    }

    private static func sampleText(_ text: String, limit: Int = 120) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else {
            return compact
        }
        return String(compact.prefix(limit)) + "..."
    }

    private static func languageParam(_ value: String) -> String? {
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

    private static func audioDurationSeconds(audio: AudioData) -> Double {
        let samples = Double(audio.pcmBytes.count) / Double(MemoryLayout<Int16>.size)
        return samples / Double(audio.sampleRate)
    }

    private static func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    private static func msString(_ ms: Double) -> String {
        String(format: "%.1f", ms)
    }
}
