import Foundation

public enum STTProviderCatalog {
    public static let specs: [STTProviderSpec] = [
        STTProviderSpec(
            id: .deepgram,
            displayName: "Deepgram (Streaming)",
            supportsStreaming: true,
            supportsREST: true,
            preferredTransport: .websocket
        ),
        STTProviderSpec(
            id: .whisper,
            displayName: "Whisper (OpenAI)",
            supportsStreaming: true,
            supportsREST: true,
            preferredTransport: .websocket
        ),
        STTProviderSpec(
            id: .appleSpeech,
            displayName: "Apple Speech (OS内蔵)",
            supportsStreaming: true,
            supportsREST: true,
            preferredTransport: .onDevice
        ),
    ]

    public static func spec(for provider: STTProvider) -> STTProviderSpec {
        specs.first(where: { $0.id == provider })
            ?? STTProviderSpec(
                id: provider,
                displayName: provider.rawValue,
                supportsStreaming: false,
                supportsREST: true,
                preferredTransport: .rest
            )
    }

    public static func supportsStreaming(_ provider: STTProvider) -> Bool {
        spec(for: provider).supportsStreaming
    }

    public static func supportsREST(_ provider: STTProvider) -> Bool {
        spec(for: provider).supportsREST
    }

    public static func settingsSpecs() -> [STTProviderSpec] {
        specs.filter(\.isVisibleInSettings)
    }

    public static func allowedProviderRawValueText() -> String {
        specs.map { $0.id.rawValue }.joined(separator: "|")
    }
}
