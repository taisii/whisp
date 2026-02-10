import Foundation
import WhispCore

extension WhispCLI {
    enum CLICommand {
        case selfCheck
        case sttFile(path: String)
        case sttStream(options: StreamOptions)
        case pipeline(options: PipelineOptions)
        case benchmarkManual(options: ManualBenchmarkOptions)
        case benchmarkVision(options: VisionBenchmarkOptions)
        case benchmarkSTT(options: STTBenchmarkOptions)
        case benchmarkGeneration(options: GenerationBenchmarkOptions)
        case benchmarkE2E(options: ManualBenchmarkOptions)

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
            case .benchmarkManual:
                return "manual-benchmark"
            case .benchmarkVision:
                return "vision-benchmark"
            case .benchmarkSTT:
                return "stt-benchmark"
            case .benchmarkGeneration:
                return "generation-benchmark"
            case .benchmarkE2E:
                return "e2e-benchmark"
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
            case "--benchmark-manual-cases":
                return .benchmarkManual(options: try parseManualBenchmarkOptions(args: args))
            case "--benchmark-vision-cases":
                return .benchmarkVision(options: try parseVisionBenchmarkOptions(args: args))
            case "--benchmark-stt-cases":
                return .benchmarkSTT(options: try parseSTTBenchmarkOptions(args: args))
            case "--benchmark-generation-cases":
                return .benchmarkGeneration(options: try parseGenerationBenchmarkOptions(args: args))
            case "--benchmark-e2e-cases":
                let e2eArgs = ["--benchmark-manual-cases"] + Array(args.dropFirst())
                return .benchmarkE2E(options: try parseManualBenchmarkOptions(args: e2eArgs))
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
        case let .benchmarkManual(options):
            try await runManualCaseBenchmark(options: options)
        case let .benchmarkVision(options):
            try await runVisionCaseBenchmark(options: options)
        case let .benchmarkSTT(options):
            try await runSTTCaseBenchmark(options: options)
        case let .benchmarkGeneration(options):
            try await runGenerationCaseBenchmark(options: options)
        case let .benchmarkE2E(options):
            try await runManualCaseBenchmark(options: options)
        }
    }

    static func printUsage() {
        print("whisp (Swift) ready")
        print("usage: whisp --self-check")
        print("usage: whisp --stt-file /path/to/input.wav")
        print("usage: whisp --stt-stream-file /path/to/input.wav [--chunk-ms N] [--realtime]")
        print("usage: whisp --pipeline-file /path/to/input.wav [--stt rest|stream] [--chunk-ms N] [--realtime] [--emit discard|stdout|pbcopy] [--context-file /path/to/context.json]")
        print("usage: whisp --benchmark-manual-cases [/path/to/manual_test_cases.jsonl] [--stt rest|stream] [--chunk-ms N] [--realtime|--no-realtime] [--limit N] [--require-context] [--min-audio-seconds N] [--min-label-confidence N] [--intent-source auto|gold|silver] [--intent-judge|--no-intent-judge] [--judge-model gemini-2.5-flash-lite|gpt-5-nano] [--benchmark-log-dir /path/to/dir]")
        print("usage: whisp --benchmark-vision-cases [/path/to/manual_test_cases.jsonl] [--limit N] [--benchmark-log-dir /path/to/dir] [--no-cache]")
        print("usage: whisp --benchmark-stt-cases [/path/to/manual_test_cases.jsonl] [--stt rest|stream] [--chunk-ms N] [--realtime|--no-realtime] [--limit N] [--min-audio-seconds N] [--benchmark-log-dir /path/to/dir] [--no-cache]")
        print("usage: whisp --benchmark-generation-cases [/path/to/manual_test_cases.jsonl] [--limit N] [--require-context] [--benchmark-log-dir /path/to/dir] [--no-cache]")
        print("usage: whisp --benchmark-e2e-cases [/path/to/manual_test_cases.jsonl] [manual benchmark options]")
    }
}
