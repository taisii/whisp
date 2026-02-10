import Foundation
import WhispCore

extension WhispCLI {
    static func run(arguments args: [String]) async {
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

        if args.first == "--benchmark-vision-cases" {
            do {
                let options = try parseVisionBenchmarkOptions(args: args)
                try await runVisionCaseBenchmark(options: options)
                exit(0)
            } catch {
                fputs("vision-benchmark failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.first == "--benchmark-stt-cases" {
            do {
                let options = try parseSTTBenchmarkOptions(args: args)
                try await runSTTCaseBenchmark(options: options)
                exit(0)
            } catch {
                fputs("stt-benchmark failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.first == "--benchmark-generation-cases" {
            do {
                let options = try parseGenerationBenchmarkOptions(args: args)
                try await runGenerationCaseBenchmark(options: options)
                exit(0)
            } catch {
                fputs("generation-benchmark failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.first == "--benchmark-e2e-cases" {
            do {
                let options = try parseManualBenchmarkOptions(args: [ "--benchmark-manual-cases" ] + Array(args.dropFirst()))
                try await runManualCaseBenchmark(options: options)
                exit(0)
            } catch {
                fputs("e2e-benchmark failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        printUsage()
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
