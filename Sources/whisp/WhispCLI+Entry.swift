import Foundation
import WhispCore

extension WhispCLI {
    enum CLICommand {
        case selfCheck
        case sttFile(path: String)
        case sttStream(options: StreamOptions)
        case pipeline(options: PipelineOptions)

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
        }
    }

    static func printUsage() {
        print("whisp (Swift) ready")
        print("usage: whisp --self-check")
        print("usage: whisp --stt-file /path/to/input.wav")
        print("usage: whisp --stt-stream-file /path/to/input.wav [--chunk-ms N] [--realtime]")
        print("usage: whisp --pipeline-file /path/to/input.wav [--stt-preset \(STTPresetCatalog.allowedPresetRawValueText())] [--chunk-ms N] [--realtime] [--emit discard|stdout|pbcopy] [--context-file /path/to/context.json]")
    }
}
