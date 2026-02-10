import Foundation
import WhispCore

extension WhispCLI {
    struct StreamOptions {
        let path: String
        let chunkMs: Int
        let realtime: Bool
    }

    static func parseStreamOptions(args: [String]) throws -> StreamOptions {
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
        var intentJudgeEnabled = true
        var intentJudgeModel: LLMModel?
        var minLabelConfidence: Double?
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
            if item == "--min-audio-seconds" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--min-audio-seconds の値が不足しています")
                }
                guard let parsed = Double(args[valueIndex]), parsed >= 0 else {
                    throw AppError.invalidArgument("--min-audio-seconds は0以上の数値で指定してください")
                }
                minAudioSeconds = parsed
                index += 2
                continue
            }
            if item == "--min-label-confidence" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--min-label-confidence の値が不足しています")
                }
                guard let parsed = Double(args[valueIndex]), (0...1).contains(parsed) else {
                    throw AppError.invalidArgument("--min-label-confidence は0〜1で指定してください")
                }
                minLabelConfidence = parsed
                index += 2
                continue
            }
            if item == "--require-context" {
                requireContext = true
                index += 1
                continue
            }
            if item == "--benchmark-log-dir" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--benchmark-log-dir の値が不足しています")
                }
                benchmarkLogDir = args[valueIndex]
                index += 2
                continue
            }
            if item == "--intent-source" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--intent-source の値が不足しています")
                }
                guard let parsed = IntentSource(rawValue: args[valueIndex]) else {
                    throw AppError.invalidArgument("--intent-source は auto|gold|silver を指定してください")
                }
                intentSource = parsed
                index += 2
                continue
            }
            if item == "--intent-judge" {
                intentJudgeEnabled = true
                index += 1
                continue
            }
            if item == "--no-intent-judge" {
                intentJudgeEnabled = false
                index += 1
                continue
            }
            if item == "--judge-model" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--judge-model の値が不足しています")
                }
                guard let parsed = LLMModel(rawValue: args[valueIndex]) else {
                    throw AppError.invalidArgument("--judge-model は有効なモデルIDを指定してください")
                }
                intentJudgeModel = parsed
                index += 2
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
            requireContext: requireContext,
            minAudioSeconds: minAudioSeconds,
            benchmarkLogDir: benchmarkLogDir,
            intentSource: intentSource,
            intentJudgeEnabled: intentJudgeEnabled,
            intentJudgeModel: intentJudgeModel,
            minLabelConfidence: minLabelConfidence
        )
    }

    static func parseVisionBenchmarkOptions(args: [String]) throws -> VisionBenchmarkOptions {
        var jsonlPath = defaultManualCasesPath()
        var limit: Int?
        var benchmarkLogDir: String?
        var useCache = true
        var index = 1

        while index < args.count {
            let item = args[index]
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
            if item == "--benchmark-log-dir" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--benchmark-log-dir の値が不足しています")
                }
                benchmarkLogDir = args[valueIndex]
                index += 2
                continue
            }
            if item == "--no-cache" {
                useCache = false
                index += 1
                continue
            }
            if item.hasPrefix("--") {
                throw AppError.invalidArgument("不明な引数: \(item)")
            }
            jsonlPath = item
            index += 1
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
        var index = 1

        while index < args.count {
            let item = args[index]
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
            if item == "--min-audio-seconds" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--min-audio-seconds の値が不足しています")
                }
                guard let parsed = Double(args[valueIndex]), parsed >= 0 else {
                    throw AppError.invalidArgument("--min-audio-seconds は0以上の数値で指定してください")
                }
                minAudioSeconds = parsed
                index += 2
                continue
            }
            if item == "--benchmark-log-dir" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--benchmark-log-dir の値が不足しています")
                }
                benchmarkLogDir = args[valueIndex]
                index += 2
                continue
            }
            if item == "--no-cache" {
                useCache = false
                index += 1
                continue
            }
            if item.hasPrefix("--") {
                throw AppError.invalidArgument("不明な引数: \(item)")
            }
            jsonlPath = item
            index += 1
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
        var index = 1

        while index < args.count {
            let item = args[index]
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
            if item == "--benchmark-log-dir" {
                let valueIndex = index + 1
                guard valueIndex < args.count else {
                    throw AppError.invalidArgument("--benchmark-log-dir の値が不足しています")
                }
                benchmarkLogDir = args[valueIndex]
                index += 2
                continue
            }
            if item == "--no-cache" {
                useCache = false
                index += 1
                continue
            }
            if item.hasPrefix("--") {
                throw AppError.invalidArgument("不明な引数: \(item)")
            }
            jsonlPath = item
            index += 1
        }

        return GenerationBenchmarkOptions(
            jsonlPath: jsonlPath,
            limit: limit,
            requireContext: requireContext,
            benchmarkLogDir: benchmarkLogDir,
            useCache: useCache
        )
    }
}
