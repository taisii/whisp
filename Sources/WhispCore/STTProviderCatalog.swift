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
            appleModel: .recognizer,
            mode: .stream,
            transport: .onDevice
        ),
        STTPresetSpec(
            id: .appleSpeechRecognizerRest,
            displayName: "Apple Speech Recognizer (REST)",
            engine: .appleSpeech,
            appleModel: .recognizer,
            mode: .rest,
            transport: .onDevice
        ),
        STTPresetSpec(
            id: .appleSpeechTranscriberStream,
            displayName: "Apple Speech Transcriber (Streaming)",
            engine: .appleSpeech,
            appleModel: .speechTranscriber,
            mode: .stream,
            transport: .onDevice
        ),
        STTPresetSpec(
            id: .appleSpeechTranscriberRest,
            displayName: "Apple Speech Transcriber (REST)",
            engine: .appleSpeech,
            appleModel: .speechTranscriber,
            mode: .rest,
            transport: .onDevice
        ),
        STTPresetSpec(
            id: .appleDictationTranscriberStream,
            displayName: "Apple Dictation Transcriber (Streaming)",
            engine: .appleSpeech,
            appleModel: .dictationTranscriber,
            mode: .stream,
            transport: .onDevice
        ),
        STTPresetSpec(
            id: .appleDictationTranscriberRest,
            displayName: "Apple Dictation Transcriber (REST)",
            engine: .appleSpeech,
            appleModel: .dictationTranscriber,
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
                appleModel: nil,
                mode: .stream,
                transport: .websocket,
                selectableInSettings: false
            )
    }

    public static func isAvailableOnCurrentPlatform(_ preset: STTPresetID) -> Bool {
        supportsCurrentPlatform(spec(for: preset))
    }

    public static func availableSpecsForCurrentPlatform() -> [STTPresetSpec] {
        specs.filter(supportsCurrentPlatform)
    }

    public static func settingsSpecs() -> [STTPresetSpec] {
        availableSpecsForCurrentPlatform()
            .filter(\.selectableInSettings)
    }

    public static func allowedPresetRawValueText() -> String {
        availableSpecsForCurrentPlatform()
            .map { $0.id.rawValue }
            .joined(separator: "|")
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

    public static func targetInputSampleRate(for preset: STTPresetID) -> Int {
        switch preset {
        case .chatgptWhisperStream:
            return 24_000
        case .deepgramStream,
             .deepgramRest,
             .appleSpeechRecognizerStream,
             .appleSpeechRecognizerRest,
             .appleSpeechTranscriberStream,
             .appleSpeechTranscriberRest,
             .appleDictationTranscriberStream,
             .appleDictationTranscriberRest:
            return 16_000
        }
    }

    private static func supportsCurrentPlatform(_ spec: STTPresetSpec) -> Bool {
        guard spec.engine == .appleSpeech else {
            return true
        }
        guard let model = spec.appleModel else {
            return true
        }
        switch model {
        case .recognizer:
            return true
        case .speechTranscriber, .dictationTranscriber:
#if os(macOS)
            if #available(macOS 26.0, *) {
                return true
            }
            return false
#else
            return false
#endif
        }
    }
}
