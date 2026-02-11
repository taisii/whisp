import Foundation
import WhispCore

extension WhispCLI {
    struct StreamOptions {
        let path: String
        let chunkMs: Int
        let realtime: Bool
    }

    private struct ArgParser {
        private let args: [String]
        private(set) var index: Int

        init(args: [String], startIndex: Int) {
            self.args = args
            index = startIndex
        }

        mutating func next() -> String? {
            guard index < args.count else {
                return nil
            }
            defer { index += 1 }
            return args[index]
        }

        mutating func value(for option: String) throws -> String {
            guard let raw = next() else {
                throw AppError.invalidArgument("\(option) の値が不足しています")
            }
            return raw
        }
    }

    private static func parsePositiveInt(_ raw: String, option: String) throws -> Int {
        guard let value = Int(raw), value > 0 else {
            throw AppError.invalidArgument("\(option) は正の整数で指定してください")
        }
        return value
    }

    private static func parseNonNegativeDouble(_ raw: String, option: String) throws -> Double {
        guard let value = Double(raw), value >= 0 else {
            throw AppError.invalidArgument("\(option) は0以上の数値で指定してください")
        }
        return value
    }

    static func parseStreamOptions(args: [String]) throws -> StreamOptions {
        guard args.count >= 2 else {
            throw AppError.invalidArgument("入力ファイルパスが必要です")
        }

        let path = args[1]
        var chunkMs = 120
        var realtime = false
        var parser = ArgParser(args: args, startIndex: 2)

        while let item = parser.next() {
            if item == "--realtime" {
                realtime = true
                continue
            }
            if item == "--chunk-ms" {
                chunkMs = try parsePositiveInt(try parser.value(for: "--chunk-ms"), option: "--chunk-ms")
                continue
            }
            if item.hasPrefix("--chunk-ms=") {
                let raw = String(item.dropFirst("--chunk-ms=".count))
                chunkMs = try parsePositiveInt(raw, option: "--chunk-ms")
                continue
            }
            throw AppError.invalidArgument("不明な引数: \(item)")
        }

        return StreamOptions(path: path, chunkMs: chunkMs, realtime: realtime)
    }

    static func parsePipelineOptions(args: [String]) throws -> PipelineOptions {
        guard args.count >= 2 else {
            throw AppError.invalidArgument("入力ファイルパスが必要です")
        }

        let path = args[1]
        var sttMode: STTMode = .stream
        var chunkMs = 120
        var realtime = true
        var emitMode: EmitMode = .discard
        var contextFilePath: String?
        var parser = ArgParser(args: args, startIndex: 2)

        while let item = parser.next() {
            if item == "--realtime" {
                realtime = true
                continue
            }
            if item == "--no-realtime" {
                realtime = false
                continue
            }
            if item == "--chunk-ms" {
                chunkMs = try parsePositiveInt(try parser.value(for: "--chunk-ms"), option: "--chunk-ms")
                continue
            }
            if item == "--stt" {
                let value = try parser.value(for: "--stt")
                guard let parsed = STTMode(rawValue: value) else {
                    throw AppError.invalidArgument("--stt は rest または stream を指定してください")
                }
                sttMode = parsed
                continue
            }
            if item == "--emit" {
                let value = try parser.value(for: "--emit")
                guard let parsed = EmitMode(rawValue: value) else {
                    throw AppError.invalidArgument("--emit は discard/stdout/pbcopy を指定してください")
                }
                emitMode = parsed
                continue
            }
            if item == "--context-file" {
                contextFilePath = try parser.value(for: "--context-file")
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

    static func parseManualBenchmarkOptions(args: [String]) throws -> ManualBenchmarkOptions {
        var jsonlPath = defaultManualCasesPath()
        var sttMode: STTMode = .stream
        var chunkMs = 120
        var realtime = true
        var limit: Int?
        var requireContext = false
        var minAudioSeconds = 2.0
        var benchmarkLogDir: String?
        var intentSource: IntentSource = .auto
        var intentJudgeEnabled = false
        var intentJudgeModel: LLMModel?
        var llmEvalEnabled = false
        var llmEvalModel: LLMModel?
        var minLabelConfidence: Double?
        var parser = ArgParser(args: args, startIndex: 1)

        while let item = parser.next() {
            if item == "--realtime" {
                realtime = true
                continue
            }
            if item == "--no-realtime" {
                realtime = false
                continue
            }
            if item == "--chunk-ms" {
                chunkMs = try parsePositiveInt(try parser.value(for: "--chunk-ms"), option: "--chunk-ms")
                continue
            }
            if item == "--stt" {
                let value = try parser.value(for: "--stt")
                guard let parsed = STTMode(rawValue: value) else {
                    throw AppError.invalidArgument("--stt は rest または stream を指定してください")
                }
                sttMode = parsed
                continue
            }
            if item == "--limit" {
                limit = try parsePositiveInt(try parser.value(for: "--limit"), option: "--limit")
                continue
            }
            if item == "--min-audio-seconds" {
                minAudioSeconds = try parseNonNegativeDouble(try parser.value(for: "--min-audio-seconds"), option: "--min-audio-seconds")
                continue
            }
            if item == "--min-label-confidence" {
                let raw = try parser.value(for: "--min-label-confidence")
                guard let parsed = Double(raw), (0 ... 1).contains(parsed) else {
                    throw AppError.invalidArgument("--min-label-confidence は0〜1で指定してください")
                }
                minLabelConfidence = parsed
                continue
            }
            if item == "--require-context" {
                requireContext = true
                continue
            }
            if item == "--benchmark-log-dir" {
                benchmarkLogDir = try parser.value(for: "--benchmark-log-dir")
                continue
            }
            if item == "--intent-source" {
                let value = try parser.value(for: "--intent-source")
                guard let parsed = IntentSource(rawValue: value) else {
                    throw AppError.invalidArgument("--intent-source は auto|gold|silver を指定してください")
                }
                intentSource = parsed
                continue
            }
            if item == "--intent-judge" {
                intentJudgeEnabled = true
                continue
            }
            if item == "--no-intent-judge" {
                intentJudgeEnabled = false
                continue
            }
            if item == "--judge-model" {
                let value = try parser.value(for: "--judge-model")
                guard let parsed = LLMModel(rawValue: value) else {
                    throw AppError.invalidArgument("--judge-model は有効なモデルIDを指定してください")
                }
                intentJudgeModel = parsed
                continue
            }
            if item == "--llm-eval" {
                llmEvalEnabled = true
                continue
            }
            if item == "--no-llm-eval" {
                llmEvalEnabled = false
                continue
            }
            if item == "--llm-eval-model" {
                let value = try parser.value(for: "--llm-eval-model")
                guard let parsed = LLMModel(rawValue: value) else {
                    throw AppError.invalidArgument("--llm-eval-model は有効なモデルIDを指定してください")
                }
                llmEvalModel = parsed
                continue
            }
            if item.hasPrefix("--") {
                throw AppError.invalidArgument("不明な引数: \(item)")
            }

            jsonlPath = item
        }

        return ManualBenchmarkOptions(
            jsonlPath: jsonlPath,
            sttMode: sttMode,
            chunkMs: chunkMs,
            realtime: realtime,
            limit: limit,
            requireContext: requireContext,
            minAudioSeconds: minAudioSeconds,
            benchmarkLogDir: benchmarkLogDir,
            intentSource: intentSource,
            intentJudgeEnabled: intentJudgeEnabled,
            intentJudgeModel: intentJudgeModel,
            llmEvalEnabled: llmEvalEnabled,
            llmEvalModel: llmEvalModel,
            minLabelConfidence: minLabelConfidence
        )
    }

    static func parseVisionBenchmarkOptions(args: [String]) throws -> VisionBenchmarkOptions {
        var jsonlPath = defaultManualCasesPath()
        var limit: Int?
        var benchmarkLogDir: String?
        var useCache = true
        var parser = ArgParser(args: args, startIndex: 1)

        while let item = parser.next() {
            if item == "--limit" {
                limit = try parsePositiveInt(try parser.value(for: "--limit"), option: "--limit")
                continue
            }
            if item == "--benchmark-log-dir" {
                benchmarkLogDir = try parser.value(for: "--benchmark-log-dir")
                continue
            }
            if item == "--no-cache" {
                useCache = false
                continue
            }
            if item.hasPrefix("--") {
                throw AppError.invalidArgument("不明な引数: \(item)")
            }
            jsonlPath = item
        }

        return VisionBenchmarkOptions(
            jsonlPath: jsonlPath,
            limit: limit,
            benchmarkLogDir: benchmarkLogDir,
            useCache: useCache
        )
    }

    static func parseSTTBenchmarkOptions(args: [String]) throws -> STTBenchmarkOptions {
        var jsonlPath = defaultManualCasesPath()
        var sttMode: STTMode = .stream
        var chunkMs = 120
        var realtime = true
        var limit: Int?
        var minAudioSeconds = 2.0
        var benchmarkLogDir: String?
        var useCache = true
        var parser = ArgParser(args: args, startIndex: 1)

        while let item = parser.next() {
            if item == "--stt" {
                let value = try parser.value(for: "--stt")
                guard let parsed = STTMode(rawValue: value) else {
                    throw AppError.invalidArgument("--stt は rest または stream を指定してください")
                }
                sttMode = parsed
                continue
            }
            if item == "--chunk-ms" {
                chunkMs = try parsePositiveInt(try parser.value(for: "--chunk-ms"), option: "--chunk-ms")
                continue
            }
            if item == "--realtime" {
                realtime = true
                continue
            }
            if item == "--no-realtime" {
                realtime = false
                continue
            }
            if item == "--limit" {
                limit = try parsePositiveInt(try parser.value(for: "--limit"), option: "--limit")
                continue
            }
            if item == "--min-audio-seconds" {
                minAudioSeconds = try parseNonNegativeDouble(try parser.value(for: "--min-audio-seconds"), option: "--min-audio-seconds")
                continue
            }
            if item == "--benchmark-log-dir" {
                benchmarkLogDir = try parser.value(for: "--benchmark-log-dir")
                continue
            }
            if item == "--no-cache" {
                useCache = false
                continue
            }
            if item.hasPrefix("--") {
                throw AppError.invalidArgument("不明な引数: \(item)")
            }
            jsonlPath = item
        }

        return STTBenchmarkOptions(
            jsonlPath: jsonlPath,
            sttMode: sttMode,
            chunkMs: chunkMs,
            realtime: realtime,
            limit: limit,
            minAudioSeconds: minAudioSeconds,
            benchmarkLogDir: benchmarkLogDir,
            useCache: useCache
        )
    }

    static func parseGenerationBenchmarkOptions(args: [String]) throws -> GenerationBenchmarkOptions {
        var jsonlPath = defaultManualCasesPath()
        var limit: Int?
        var requireContext = false
        var benchmarkLogDir: String?
        var useCache = true
        var llmEvalEnabled = false
        var llmEvalModel: LLMModel?
        var parser = ArgParser(args: args, startIndex: 1)

        while let item = parser.next() {
            if item == "--limit" {
                limit = try parsePositiveInt(try parser.value(for: "--limit"), option: "--limit")
                continue
            }
            if item == "--require-context" {
                requireContext = true
                continue
            }
            if item == "--benchmark-log-dir" {
                benchmarkLogDir = try parser.value(for: "--benchmark-log-dir")
                continue
            }
            if item == "--no-cache" {
                useCache = false
                continue
            }
            if item == "--llm-eval" {
                llmEvalEnabled = true
                continue
            }
            if item == "--no-llm-eval" {
                llmEvalEnabled = false
                continue
            }
            if item == "--llm-eval-model" {
                let value = try parser.value(for: "--llm-eval-model")
                guard let parsed = LLMModel(rawValue: value) else {
                    throw AppError.invalidArgument("--llm-eval-model は有効なモデルIDを指定してください")
                }
                llmEvalModel = parsed
                continue
            }
            if item.hasPrefix("--") {
                throw AppError.invalidArgument("不明な引数: \(item)")
            }
            jsonlPath = item
        }

        return GenerationBenchmarkOptions(
            jsonlPath: jsonlPath,
            limit: limit,
            requireContext: requireContext,
            benchmarkLogDir: benchmarkLogDir,
            useCache: useCache,
            llmEvalEnabled: llmEvalEnabled,
            llmEvalModel: llmEvalModel
        )
    }
}
