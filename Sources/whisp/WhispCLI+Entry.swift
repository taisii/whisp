import Foundation
import WhispCore

extension WhispCLI {
    enum CLICommand {
        case selfCheck
        case sttFile(path: String)
        case sttStream(options: StreamOptions)
        case pipeline(options: PipelineOptions)
        case benchmarkVision(options: VisionBenchmarkOptions)
        case benchmarkSTT(options: STTBenchmarkOptions)
        case benchmarkGeneration(options: GenerationBenchmarkOptions)
        case benchmarkCompare(options: BenchmarkCompareOptions)
        case benchmarkListCandidates
        case benchmarkScanIntegrity(options: BenchmarkIntegrityScanOptions)

        var errorLabel: String {
            switch self {
            case .selfCheck:
                return "self-check"
            case .sttFile:
                return "stt-check"
            case .sttStream:
                return "stt-stream-check"
            case .pipeline:
                return "pipeline-check"
            case .benchmarkVision:
                return "vision-benchmark"
            case .benchmarkSTT:
                return "stt-benchmark"
            case .benchmarkGeneration:
                return "generation-benchmark"
            case .benchmarkCompare:
                return "benchmark-compare"
            case .benchmarkListCandidates:
                return "benchmark-list-candidates"
            case .benchmarkScanIntegrity:
                return "benchmark-scan-integrity"
            }
        }

        static func parse(arguments args: [String]) throws -> CLICommand? {
            guard let first = args.first else {
                return nil
            }

            switch first {
            case "--self-check":
                return .selfCheck
            case "--stt-file":
                guard args.count == 2 else {
                    throw AppError.invalidArgument("入力ファイルパスが必要です")
                }
                return .sttFile(path: args[1])
            case "--stt-stream-file":
                guard args.count >= 2 else {
                    throw AppError.invalidArgument("入力ファイルパスが必要です")
                }
                return .sttStream(options: try parseStreamOptions(args: args))
            case "--pipeline-file":
                guard args.count >= 2 else {
                    throw AppError.invalidArgument("入力ファイルパスが必要です")
                }
                return .pipeline(options: try parsePipelineOptions(args: args))
            case "--benchmark-vision-cases":
                return .benchmarkVision(options: try parseVisionBenchmarkOptions(args: args))
            case "--benchmark-stt-cases":
                return .benchmarkSTT(options: try parseSTTBenchmarkOptions(args: args))
            case "--benchmark-generation-cases":
                return .benchmarkGeneration(options: try parseGenerationBenchmarkOptions(args: args))
            case "--benchmark-compare":
                return .benchmarkCompare(options: try parseBenchmarkCompareOptions(args: args))
            case "--benchmark-list-candidates":
                return .benchmarkListCandidates
            case "--benchmark-scan-integrity":
                return .benchmarkScanIntegrity(options: try parseBenchmarkIntegrityScanOptions(args: args))
            default:
                return nil
            }
        }
    }

    static func run(arguments args: [String]) async {
        do {
            guard let command = try CLICommand.parse(arguments: args) else {
                printUsage()
                return
            }
            try await execute(command)
            exit(0)
        } catch {
            if let command = try? CLICommand.parse(arguments: args) {
                fputs("\(command.errorLabel) failed: \(error.localizedDescription)\n", stderr)
            } else {
                fputs("command failed: \(error.localizedDescription)\n", stderr)
            }
            exit(1)
        }
    }

    static func execute(_ command: CLICommand) async throws {
        switch command {
        case .selfCheck:
            let ok = formatShortcutDisplay("Cmd+J") == "⌘ J" && !isEmptySTT("テスト")
            print(ok ? "ok" : "ng")
            if !ok {
                throw AppError.invalidArgument("self-check failed")
            }
        case let .sttFile(path):
            try await runSTTFile(path: path)
        case let .sttStream(options):
            try await runSTTStreamFile(path: options.path, chunkMs: options.chunkMs, realtime: options.realtime)
        case let .pipeline(options):
            try await runPipelineFile(options: options)
        case let .benchmarkVision(options):
            try await runVisionCaseBenchmark(options: options)
        case let .benchmarkSTT(options):
            try await runSTTCaseBenchmark(options: options)
        case let .benchmarkGeneration(options):
            try await runGenerationCaseBenchmark(options: options)
        case let .benchmarkCompare(options):
            try await runBenchmarkCompare(options: options)
        case .benchmarkListCandidates:
            try runBenchmarkListCandidates()
        case let .benchmarkScanIntegrity(options):
            try runBenchmarkIntegrityScan(options: options)
        }
    }

    static func printUsage() {
        let llmEvalModels = LLMModelCatalog.allowedModelRawValueText(for: .cliLLMEval)
        let judgeModels = LLMModelCatalog.allowedModelRawValueText(for: .cliJudge)
        print("whisp (Swift) ready")
        print("usage: whisp --self-check")
        print("usage: whisp --stt-file /path/to/input.wav")
        print("usage: whisp --stt-stream-file /path/to/input.wav [--chunk-ms N] [--realtime]")
        print("usage: whisp --pipeline-file /path/to/input.wav [--stt-preset \(STTPresetCatalog.allowedPresetRawValueText())] [--chunk-ms N] [--realtime] [--emit discard|stdout|pbcopy] [--context-file /path/to/context.json]")
        print("usage: whisp --benchmark-vision-cases [/path/to/manual_test_cases.jsonl] [--benchmark-workers N] [--limit N] [--no-cache]")
        print("usage: whisp --benchmark-stt-cases [/path/to/manual_test_cases.jsonl] [--stt-preset \(STTPresetCatalog.allowedPresetRawValueText())] [--chunk-ms N] [--silence-ms N] [--max-segment-ms N] [--pre-roll-ms N] [--benchmark-workers N] [--realtime|--no-realtime] [--limit N] [--min-audio-seconds N] [--no-cache]")
        print("usage: whisp --benchmark-generation-cases [/path/to/manual_test_cases.jsonl] [--benchmark-workers N] [--limit N] [--require-context] [--llm-eval|--no-llm-eval] [--llm-eval-model \(llmEvalModels)] [--no-cache]")
        print("usage: whisp --benchmark-compare --task stt --cases /path/to/manual_test_cases.jsonl --candidate-id <id> [--candidate-id <id>] [--benchmark-workers N] [--force]")
        print("usage: whisp --benchmark-compare --task generation-single --cases /path/to/manual_test_cases.jsonl --candidate-id <id> [--benchmark-workers N] [--force]")
        print("usage: whisp --benchmark-compare --task generation-battle --cases /path/to/manual_test_cases.jsonl --candidate-id <A> --candidate-id <B> [--judge-model \(judgeModels)] [--benchmark-workers N] [--force]")
        print("usage: whisp --benchmark-list-candidates")
        print("usage: whisp --benchmark-scan-integrity --task stt|generation --cases /path/to/manual_test_cases.jsonl")
    }
}
