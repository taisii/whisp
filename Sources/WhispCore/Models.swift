import Foundation

public struct APIKeys: Codable, Equatable, Sendable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public init(
        deepgram: String = "",
        gemini: String = "",
        openai: String = "",
        moonshot: String = ""
    ) {
        values = [:]
        self.deepgram = deepgram
        self.gemini = gemini
        self.openai = openai
        self.moonshot = moonshot
    }

    public var deepgram: String {
        get { value(for: .deepgram) }
        set { setValue(newValue, for: .deepgram) }
    }

    public var gemini: String {
        get { value(for: .gemini) }
        set { setValue(newValue, for: .gemini) }
    }

    public var openai: String {
        get { value(for: .openai) }
        set { setValue(newValue, for: .openai) }
    }

    public var moonshot: String {
        get { value(for: .moonshot) }
        set { setValue(newValue, for: .moonshot) }
    }

    public func value(for provider: LLMProviderID) -> String {
        let key = provider.rawValue
        return values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public mutating func setValue(_ rawValue: String, for provider: LLMProviderID) {
        let key = provider.rawValue
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            values.removeValue(forKey: key)
        } else {
            values[key] = trimmed
        }
    }
}

public enum STTProvider: String, Codable, Equatable, Sendable, CaseIterable {
    case deepgram
    case whisper
    case appleSpeech = "apple_speech"
}

public enum STTPresetID: String, Codable, Equatable, Sendable, CaseIterable {
    case deepgramStream = "deepgram_stream"
    case deepgramRest = "deepgram_rest"
    case appleSpeechRecognizerStream = "apple_speech_recognizer_stream"
    case appleSpeechRecognizerRest = "apple_speech_recognizer_rest"
    case appleSpeechAnalyzerStream = "apple_speech_analyzer_stream"
    case appleSpeechAnalyzerRest = "apple_speech_analyzer_rest"
    case chatgptWhisperStream = "chatgpt_whisper_stream"
}

public enum STTEngine: String, Codable, Equatable, Sendable {
    case deepgram
    case appleSpeech = "apple_speech"
    case openAIWhisper = "openai_whisper"
}

public enum STTExecutionMode: String, Codable, Equatable, Sendable {
    case stream
    case rest
}

public enum STTCredential: Equatable, Sendable {
    case apiKey(String)
    case none
}

public enum STTTransport: String, Codable, Equatable, Sendable {
    case websocket
    case rest
    case onDevice = "on_device"
}

public struct STTProviderSpec: Equatable, Sendable {
    public let id: STTProvider
    public let displayName: String
    public let supportsStreaming: Bool
    public let supportsREST: Bool
    public let preferredTransport: STTTransport
    public let isVisibleInSettings: Bool

    public init(
        id: STTProvider,
        displayName: String,
        supportsStreaming: Bool,
        supportsREST: Bool,
        preferredTransport: STTTransport,
        isVisibleInSettings: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.supportsStreaming = supportsStreaming
        self.supportsREST = supportsREST
        self.preferredTransport = preferredTransport
        self.isVisibleInSettings = isVisibleInSettings
    }
}

public struct STTPresetSpec: Equatable, Sendable {
    public let id: STTPresetID
    public let displayName: String
    public let engine: STTEngine
    public let mode: STTExecutionMode
    public let transport: STTTransport
    public let selectableInSettings: Bool

    public init(
        id: STTPresetID,
        displayName: String,
        engine: STTEngine,
        mode: STTExecutionMode,
        transport: STTTransport,
        selectableInSettings: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.mode = mode
        self.transport = transport
        self.selectableInSettings = selectableInSettings
    }
}

public enum RecordingMode: String, Codable, Equatable, Sendable {
    case toggle
    case pushToTalk = "push_to_talk"
}

public struct LLMProviderID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        self.rawValue = trimmed
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(uncheckedRawValue: String) {
        self.rawValue = uncheckedRawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "llm provider id is empty")
        }
        self.rawValue = trimmed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct LLMModelID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        self.rawValue = trimmed
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(uncheckedRawValue: String) {
        self.rawValue = uncheckedRawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "llm model id is empty")
        }
        self.rawValue = trimmed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public typealias LLMModel = LLMModelID

public extension LLMModelID {
    static let gemini3FlashPreview = LLMModelID(uncheckedRawValue: "gemini-3-flash-preview")
    static let gemini25FlashLite = LLMModelID(uncheckedRawValue: "gemini-2.5-flash-lite")
    static let gemini25FlashLiteAudio = LLMModelID(uncheckedRawValue: "gemini-2.5-flash-lite-audio")
    static let kimiK25 = LLMModelID(uncheckedRawValue: "kimi-k2.5")
    static let gpt4oMini = LLMModelID(uncheckedRawValue: "gpt-4o-mini")
    static let gpt5Nano = LLMModelID(uncheckedRawValue: "gpt-5-nano")

    var modelName: String {
        LLMModelCatalog.spec(for: self)?.apiModelName ?? rawValue
    }

    var usesDirectAudio: Bool {
        LLMModelCatalog.supports(.supportsDirectAudioInput, model: self)
    }
}

public struct AppPromptRule: Codable, Equatable, Sendable {
    public var appName: String
    public var template: String

    public init(appName: String = "", template: String = "") {
        self.appName = appName
        self.template = template
    }
}

public struct ContextConfig: Codable, Equatable, Sendable {
    public var visionEnabled: Bool
    public var visionMode: VisionContextMode

    public init(visionEnabled: Bool = true, visionMode: VisionContextMode = .saveOnly) {
        self.visionEnabled = visionEnabled
        self.visionMode = visionMode
    }
}

public enum VisionContextMode: String, Codable, Equatable, Sendable, CaseIterable {
    case saveOnly = "save_only"
    case ocr
}

public struct STTSegmentationConfig: Codable, Equatable, Sendable {
    public var silenceMs: Int
    public var maxSegmentMs: Int
    public var preRollMs: Int
    public var livePreviewEnabled: Bool

    public init(
        silenceMs: Int = 700,
        maxSegmentMs: Int = 25_000,
        preRollMs: Int = 250,
        livePreviewEnabled: Bool = false
    ) {
        self.silenceMs = silenceMs
        self.maxSegmentMs = maxSegmentMs
        self.preRollMs = preRollMs
        self.livePreviewEnabled = livePreviewEnabled
    }
}

public struct STTCommittedSegment: Codable, Equatable, Sendable {
    public let index: Int
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
    public let reason: String

    public init(
        index: Int,
        startMs: Int64,
        endMs: Int64,
        text: String,
        reason: String
    ) {
        self.index = index
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.reason = reason
    }
}

public struct VADInterval: Codable, Equatable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public let kind: String

    public init(startMs: Int64, endMs: Int64, kind: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.kind = kind
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var apiKeys: APIKeys
    public var shortcut: String
    public var inputLanguage: String
    public var recordingMode: RecordingMode
    public var sttPreset: STTPresetID
    public var sttSegmentation: STTSegmentationConfig
    public var appPromptRules: [AppPromptRule]
    public var llmModel: LLMModel
    public var context: ContextConfig
    public var generationPrimary: GenerationPrimarySelection?

    enum CodingKeys: String, CodingKey {
        case apiKeys
        case shortcut
        case inputLanguage
        case recordingMode
        case sttPreset
        case sttSegmentation
        case appPromptRules
        case llmModel
        case context
        case generationPrimary
    }

    public init(
        apiKeys: APIKeys = APIKeys(),
        shortcut: String = "Cmd+J",
        inputLanguage: String = "ja",
        recordingMode: RecordingMode = .toggle,
        sttPreset: STTPresetID = .deepgramStream,
        sttSegmentation: STTSegmentationConfig = STTSegmentationConfig(),
        appPromptRules: [AppPromptRule] = [],
        llmModel: LLMModel = .gemini25FlashLite,
        context: ContextConfig = ContextConfig(),
        generationPrimary: GenerationPrimarySelection? = nil
    ) {
        self.apiKeys = apiKeys
        self.shortcut = shortcut
        self.inputLanguage = inputLanguage
        self.recordingMode = recordingMode
        self.sttPreset = sttPreset
        self.sttSegmentation = sttSegmentation
        self.appPromptRules = appPromptRules
        self.llmModel = llmModel
        self.context = context
        self.generationPrimary = generationPrimary
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKeys = try container.decode(APIKeys.self, forKey: .apiKeys)
        shortcut = try container.decode(String.self, forKey: .shortcut)
        inputLanguage = try container.decode(String.self, forKey: .inputLanguage)
        recordingMode = try container.decode(RecordingMode.self, forKey: .recordingMode)
        sttPreset = try container.decode(STTPresetID.self, forKey: .sttPreset)
        sttSegmentation = try container.decodeIfPresent(STTSegmentationConfig.self, forKey: .sttSegmentation)
            ?? STTSegmentationConfig()
        appPromptRules = try container.decode([AppPromptRule].self, forKey: .appPromptRules)
        llmModel = try container.decode(LLMModel.self, forKey: .llmModel)
        context = try container.decode(ContextConfig.self, forKey: .context)
        generationPrimary = try container.decodeIfPresent(GenerationPrimarySelection.self, forKey: .generationPrimary)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apiKeys, forKey: .apiKeys)
        try container.encode(shortcut, forKey: .shortcut)
        try container.encode(inputLanguage, forKey: .inputLanguage)
        try container.encode(recordingMode, forKey: .recordingMode)
        try container.encode(sttPreset, forKey: .sttPreset)
        try container.encode(sttSegmentation, forKey: .sttSegmentation)
        try container.encode(appPromptRules, forKey: .appPromptRules)
        try container.encode(llmModel, forKey: .llmModel)
        try container.encode(context, forKey: .context)
        try container.encodeIfPresent(generationPrimary, forKey: .generationPrimary)
    }
}

public struct STTUsage: Equatable, Sendable {
    public var durationSeconds: Double
    public var requestID: String?
    public var provider: String

    public init(durationSeconds: Double, requestID: String?, provider: String) {
        self.durationSeconds = durationSeconds
        self.requestID = requestID
        self.provider = provider
    }
}

public struct LLMUsage: Equatable, Sendable {
    public var model: String
    public var promptTokens: Int
    public var completionTokens: Int
    public var provider: String

    public init(model: String, promptTokens: Int, completionTokens: Int, provider: String? = nil) {
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.provider = provider ?? Self.inferProvider(from: model)
    }

    private static func inferProvider(from model: String) -> String {
        let normalized = model.lowercased()
        if normalized.contains("gemini") {
            return "gemini"
        }
        if normalized.contains("kimi") || normalized.contains("moonshot") {
            return "moonshot"
        }
        if normalized.contains("gpt") || normalized.contains("openai") {
            return "openai"
        }
        return "unknown"
    }
}

public struct STTProviderUsage: Codable, Equatable, Sendable {
    public var durationSeconds: Double
    public var requests: Int

    public init(durationSeconds: Double = 0, requests: Int = 0) {
        self.durationSeconds = durationSeconds
        self.requests = requests
    }
}

public struct LLMProviderUsage: Codable, Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var requests: Int

    public init(promptTokens: Int = 0, completionTokens: Int = 0, requests: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.requests = requests
    }
}

public struct DailyUsage: Codable, Equatable, Sendable {
    public var date: String
    public var stt: [String: STTProviderUsage]
    public var llm: [String: LLMProviderUsage]

    public init(
        date: String,
        stt: [String: STTProviderUsage] = [:],
        llm: [String: LLMProviderUsage] = [:]
    ) {
        self.date = date
        self.stt = stt
        self.llm = llm
    }
}
