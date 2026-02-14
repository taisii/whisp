import Foundation

public enum STTPresetCatalog {
    public static let specs: [STTPresetSpec] = [
        STTPresetSpec(
            id: .deepgramStream,
            displayName: "Deepgram (Streaming)",
            engine: .deepgram,
            mode: .stream,
            transport: .websocket
        ),
        STTPresetSpec(
            id: .deepgramRest,
            displayName: "Deepgram (REST)",
            engine: .deepgram,
            mode: .rest,
            transport: .rest
        ),
        STTPresetSpec(
            id: .appleSpeechRecognizerStream,
            displayName: "Apple Speech Recognizer (Streaming)",
            engine: .appleSpeech,
            mode: .stream,
            transport: .onDevice
        ),
        STTPresetSpec(
            id: .appleSpeechRecognizerRest,
            displayName: "Apple Speech Recognizer (REST)",
            engine: .appleSpeech,
            mode: .rest,
            transport: .onDevice
        ),
        STTPresetSpec(
            id: .appleSpeechAnalyzerStream,
            displayName: "Apple Speech Analyzer (Streaming)",
            engine: .appleSpeech,
            mode: .stream,
            transport: .onDevice
        ),
        STTPresetSpec(
            id: .appleSpeechAnalyzerRest,
            displayName: "Apple Speech Analyzer (REST)",
            engine: .appleSpeech,
            mode: .rest,
            transport: .onDevice
        ),
        STTPresetSpec(
            id: .chatgptWhisperStream,
            displayName: "ChatGPT Whisper (Streaming)",
            engine: .openAIWhisper,
            mode: .stream,
            transport: .websocket
        ),
    ]

    public static func spec(for preset: STTPresetID) -> STTPresetSpec {
        specs.first(where: { $0.id == preset })
            ?? STTPresetSpec(
                id: preset,
                displayName: preset.rawValue,
                engine: .deepgram,
                mode: .stream,
                transport: .websocket,
                selectableInSettings: false
            )
    }

    public static func settingsSpecs() -> [STTPresetSpec] {
        specs.filter(\.selectableInSettings)
    }

    public static func allowedPresetRawValueText() -> String {
        specs.map { $0.id.rawValue }.joined(separator: "|")
    }

    public static func providerID(for preset: STTPresetID) -> String {
        preset.rawValue
    }

    public static func supportsStreaming(_ preset: STTPresetID) -> Bool {
        spec(for: preset).mode == .stream
    }

    public static func supportsREST(_ preset: STTPresetID) -> Bool {
        spec(for: preset).mode == .rest
    }
}
