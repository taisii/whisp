import Foundation

public struct APIKeys: Codable, Equatable, Sendable {
    public var deepgram: String
    public var gemini: String
    public var openai: String

    public init(deepgram: String = "", gemini: String = "", openai: String = "") {
        self.deepgram = deepgram
        self.gemini = gemini
        self.openai = openai
    }
}

public enum STTProvider: String, Codable, Equatable, Sendable, CaseIterable {
    case deepgram
    case whisper
    case appleSpeech = "apple_speech"
}

public enum RecordingMode: String, Codable, Equatable, Sendable {
    case toggle
    case pushToTalk = "push_to_talk"
}

public enum LLMModel: String, Codable, Equatable, Sendable {
    case gemini3FlashPreview = "gemini-3-flash-preview"
    case gemini25FlashLite = "gemini-2.5-flash-lite"
    case gemini25FlashLiteAudio = "gemini-2.5-flash-lite-audio"
    case gpt4oMini = "gpt-4o-mini"
    case gpt5Nano = "gpt-5-nano"

    public var modelName: String {
        switch self {
        case .gemini3FlashPreview:
            return "gemini-3-flash-preview"
        case .gemini25FlashLite:
            return "gemini-2.5-flash-lite"
        case .gemini25FlashLiteAudio:
            return "gemini-2.5-flash-lite"
        case .gpt4oMini:
            return "gpt-4o-mini"
        case .gpt5Nano:
            return "gpt-5-nano"
        }
    }

    public var usesDirectAudio: Bool {
        self == .gemini25FlashLiteAudio
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

public struct Config: Codable, Equatable, Sendable {
    public var apiKeys: APIKeys
    public var shortcut: String
    public var inputLanguage: String
    public var recordingMode: RecordingMode
    public var sttProvider: STTProvider
    public var appPromptRules: [AppPromptRule]
    public var llmModel: LLMModel
    public var context: ContextConfig

    public init(
        apiKeys: APIKeys = APIKeys(),
        shortcut: String = "Cmd+J",
        inputLanguage: String = "ja",
        recordingMode: RecordingMode = .toggle,
        sttProvider: STTProvider = .deepgram,
        appPromptRules: [AppPromptRule] = [],
        llmModel: LLMModel = .gemini25FlashLite,
        context: ContextConfig = ContextConfig()
    ) {
        self.apiKeys = apiKeys
        self.shortcut = shortcut
        self.inputLanguage = inputLanguage
        self.recordingMode = recordingMode
        self.sttProvider = sttProvider
        self.appPromptRules = appPromptRules
        self.llmModel = llmModel
        self.context = context
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
