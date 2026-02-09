import Foundation

public struct ParsedGeminiArgs: Equatable, Sendable {
    public let apiKey: String
    public let audioPath: String?

    public init(apiKey: String, audioPath: String?) {
        self.apiKey = apiKey
        self.audioPath = audioPath
    }
}

public func parseGeminiArguments(args: [String], envAPIKey: String?) throws -> ParsedGeminiArgs {
    switch args.count {
    case 0:
        guard let envAPIKey else {
            throw AppError.invalidArgument("GEMINI_API_KEYが必要です")
        }
        return ParsedGeminiArgs(apiKey: envAPIKey, audioPath: nil)
    case 1:
        if let envAPIKey {
            return ParsedGeminiArgs(apiKey: envAPIKey, audioPath: args[0])
        }
        return ParsedGeminiArgs(apiKey: args[0], audioPath: nil)
    default:
        return ParsedGeminiArgs(apiKey: args[0], audioPath: args[1])
    }
}

public func mimeTypeFromPath(_ path: String) throws -> String {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    switch ext {
    case "wav": return "audio/wav"
    case "mp3": return "audio/mpeg"
    case "aiff", "aif": return "audio/aiff"
    case "aac": return "audio/aac"
    case "ogg": return "audio/ogg"
    case "flac": return "audio/flac"
    default:
        throw AppError.invalidArgument("対応フォーマット: wav/mp3/aiff/aac/ogg/flac")
    }
}
