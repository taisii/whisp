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

    static func parseVisionBenchmarkOptions(args: [String]) throws -> VisionBenchmarkOptions {
        var jsonlPath = defaultManualCasesPath()
        var limit: Int?
        var useCache = true
        var benchmarkWorkers: Int?
        var parser = ArgParser(args: args, startIndex: 1)

        while let item = parser.next() {
            if item == "--limit" {
                limit = try parsePositiveInt(try parser.value(for: "--limit"), option: "--limit")
                continue
            }
            if item == "--no-cache" {
                useCache = false
                continue
            }
            if item == "--benchmark-workers" {
                benchmarkWorkers = try parsePositiveInt(try parser.value(for: "--benchmark-workers"), option: "--benchmark-workers")
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
            useCache: useCache,
            benchmarkWorkers: benchmarkWorkers
        )
    }

    static func parseSTTBenchmarkOptions(args: [String]) throws -> STTBenchmarkOptions {
        var jsonlPath = defaultManualCasesPath()
        var sttMode: STTMode = .stream
        var chunkMs = 120
        var realtime = true
        var benchmarkWorkers: Int?
        var limit: Int?
        var minAudioSeconds = 2.0
        var useCache = true
        var sttProvider: STTProvider = .deepgram
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
            if item == "--benchmark-workers" {
                benchmarkWorkers = try parsePositiveInt(try parser.value(for: "--benchmark-workers"), option: "--benchmark-workers")
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
            if item == "--no-cache" {
                useCache = false
                continue
            }
            if item == "--stt-provider" {
                let raw = try parser.value(for: "--stt-provider")
                guard let parsed = STTProvider(rawValue: raw) else {
                    throw AppError.invalidArgument("--stt-provider は deepgram|whisper|apple_speech を指定してください")
                }
                sttProvider = parsed
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
            benchmarkWorkers: benchmarkWorkers,
            limit: limit,
            minAudioSeconds: minAudioSeconds,
            useCache: useCache,
            candidateID: nil,
            datasetHash: nil,
            runtimeOptionsHash: nil,
            evaluatorVersion: nil,
            codeVersion: nil,
            benchmarkKey: nil,
            sttProvider: sttProvider
        )
    }

    static func parseGenerationBenchmarkOptions(args: [String]) throws -> GenerationBenchmarkOptions {
        var jsonlPath = defaultManualCasesPath()
        var benchmarkWorkers: Int?
        var limit: Int?
        var requireContext = false
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
            if item == "--benchmark-workers" {
                benchmarkWorkers = try parsePositiveInt(try parser.value(for: "--benchmark-workers"), option: "--benchmark-workers")
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
                guard let parsed = LLMModelCatalog.resolveRegistered(rawValue: value),
                      LLMModelCatalog.isSelectable(parsed, for: .cliLLMEval)
                else {
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
            benchmarkWorkers: benchmarkWorkers,
            limit: limit,
            requireContext: requireContext,
            useCache: useCache,
            llmEvalEnabled: llmEvalEnabled,
            llmEvalModel: llmEvalModel,
            candidateID: nil,
            datasetHash: nil,
            runtimeOptionsHash: nil,
            evaluatorVersion: nil,
            codeVersion: nil,
            benchmarkKey: nil,
            modelOverride: nil,
            promptTemplateOverride: nil,
            promptName: nil,
            promptHash: nil,
            candidateSnapshot: nil
        )
    }

    static func parseBenchmarkCompareOptions(args: [String]) throws -> BenchmarkCompareOptions {
        var task: BenchmarkCompareFlow?
        var casesPath = defaultManualCasesPath()
        var candidateIDs: [String] = []
        var force = false
        var benchmarkWorkers: Int?
        var judgeModel: LLMModel?
        var parser = ArgParser(args: args, startIndex: 1)

        while let item = parser.next() {
            if item == "--task" {
                let raw = try parser.value(for: "--task")
                task = try parseCompareTask(raw)
                continue
            }
            if item == "--cases" {
                casesPath = try parser.value(for: "--cases")
                continue
            }
            if item == "--candidate-id" {
                candidateIDs.append(try parser.value(for: "--candidate-id"))
                continue
            }
            if item == "--force" {
                force = true
                continue
            }
            if item == "--benchmark-workers" {
                benchmarkWorkers = try parsePositiveInt(try parser.value(for: "--benchmark-workers"), option: "--benchmark-workers")
                continue
            }
            if item == "--judge-model" {
                let raw = try parser.value(for: "--judge-model")
                guard let parsed = LLMModelCatalog.resolveRegistered(rawValue: raw),
                      LLMModelCatalog.isSelectable(parsed, for: .cliJudge)
                else {
                    throw AppError.invalidArgument("--judge-model は有効なモデルIDを指定してください")
                }
                judgeModel = parsed
                continue
            }
            throw AppError.invalidArgument("不明な引数: \(item)")
        }

        guard let task else {
            throw AppError.invalidArgument("--task が必要です (stt|generation-single|generation-battle)")
        }
        switch task {
        case .stt:
            guard !candidateIDs.isEmpty else {
                throw AppError.invalidArgument("--candidate-id が1件以上必要です")
            }
            if judgeModel != nil {
                throw AppError.invalidArgument("--judge-model は generation-battle のみ利用できます")
            }
        case .generationSingle:
            guard candidateIDs.count == 1 else {
                throw AppError.invalidArgument("generation-single は --candidate-id を1件指定してください")
            }
            if judgeModel != nil {
                throw AppError.invalidArgument("--judge-model は generation-battle のみ利用できます")
            }
        case .generationBattle:
            guard candidateIDs.count == 2 else {
                throw AppError.invalidArgument("generation-battle は --candidate-id を2件指定してください")
            }
            if candidateIDs[0] == candidateIDs[1] {
                throw AppError.invalidArgument("candidate A/B は異なる ID を指定してください")
            }
        }
        return BenchmarkCompareOptions(
            task: task,
            casesPath: casesPath,
            candidateIDs: candidateIDs,
            force: force,
            benchmarkWorkers: benchmarkWorkers,
            judgeModel: judgeModel
        )
    }

    static func parseBenchmarkIntegrityScanOptions(args: [String]) throws -> BenchmarkIntegrityScanOptions {
        var task: BenchmarkKind?
        var casesPath = defaultManualCasesPath()
        var parser = ArgParser(args: args, startIndex: 1)

        while let item = parser.next() {
            if item == "--task" {
                let raw = try parser.value(for: "--task")
                task = try parseIntegrityTask(raw)
                continue
            }
            if item == "--cases" {
                casesPath = try parser.value(for: "--cases")
                continue
            }
            throw AppError.invalidArgument("不明な引数: \(item)")
        }

        guard let task else {
            throw AppError.invalidArgument("--task が必要です (stt|generation)")
        }
        return BenchmarkIntegrityScanOptions(task: task, casesPath: casesPath)
    }

    private static func parseIntegrityTask(_ raw: String) throws -> BenchmarkKind {
        guard let task = BenchmarkKind(rawValue: raw),
              task == .stt || task == .generation
        else {
            throw AppError.invalidArgument("--task は stt または generation を指定してください")
        }
        return task
    }

    private static func parseCompareTask(_ raw: String) throws -> BenchmarkCompareFlow {
        guard let task = BenchmarkCompareFlow(rawValue: raw)
        else {
            throw AppError.invalidArgument("--task は stt|generation-single|generation-battle を指定してください")
        }
        return task
    }
}
