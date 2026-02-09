import Foundation
import WhispCore

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

        print("whisp (Swift) ready")
        print("usage: whisp --self-check")
        print("usage: whisp --stt-file /path/to/input.wav")
    }

    @MainActor
    private static func runSTTFile(path: String) async throws {
        let configStore = try ConfigStore()
        let config = try configStore.loadOrCreate()
        let key = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AppError.invalidArgument("Deepgram APIキーが未設定です")
        }

        let wavData = try Data(contentsOf: URL(fileURLWithPath: path))
        let audio = try parsePCM16MonoWAV(wavData)
        let client = DeepgramClient()

        let language: String? = switch config.inputLanguage {
        case "auto":
            nil
        case "ja":
            "ja"
        case "en":
            "en"
        default:
            nil
        }

        let result = try await client.transcribe(
            apiKey: key,
            sampleRate: Int(audio.sampleRate),
            audio: audio.pcmBytes,
            language: language
        )

        print("transcript: \(result.transcript)")
        if let usage = result.usage {
            print("duration_seconds: \(usage.durationSeconds)")
            if let requestID = usage.requestID {
                print("request_id: \(requestID)")
            }
        }
    }
}
