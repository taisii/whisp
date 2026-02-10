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

public enum RecordingMode: String, Codable, Equatable, Sendable {
    case toggle
    case pushToTalk = "push_to_talk"
}

public enum LLMModel: String, Codable, Equatable, Sendable {
    case gemini25FlashLite = "gemini-2.5-flash-lite"
    case gemini25FlashLiteAudio = "gemini-2.5-flash-lite-audio"
    case gpt4oMini = "gpt-4o-mini"
    case gpt5Nano = "gpt-5-nano"

    public var modelName: String {
        switch self {
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

    public init(visionEnabled: Bool = true) {
        self.visionEnabled = visionEnabled
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var apiKeys: APIKeys
    public var shortcut: String
    public var inputLanguage: String
    public var recordingMode: RecordingMode
    public var appPromptRules: [AppPromptRule]
    public var llmModel: LLMModel
    public var context: ContextConfig

    public init(
        apiKeys: APIKeys = APIKeys(),
        shortcut: String = "Cmd+J",
        inputLanguage: String = "ja",
        recordingMode: RecordingMode = .toggle,
        appPromptRules: [AppPromptRule] = [],
        llmModel: LLMModel = .gemini25FlashLite,
        context: ContextConfig = ContextConfig()
    ) {
        self.apiKeys = apiKeys
        self.shortcut = shortcut
        self.inputLanguage = inputLanguage
        self.recordingMode = recordingMode
        self.appPromptRules = appPromptRules
        self.llmModel = llmModel
        self.context = context
    }
}

public struct STTUsage: Equatable, Sendable {
    public var durationSeconds: Double
    public var requestID: String?

    public init(durationSeconds: Double, requestID: String?) {
        self.durationSeconds = durationSeconds
        self.requestID = requestID
    }
}

public struct LLMUsage: Equatable, Sendable {
    public var model: String
    public var promptTokens: Int
    public var completionTokens: Int

    public init(model: String, promptTokens: Int, completionTokens: Int) {
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public struct DailyUsage: Codable, Equatable, Sendable {
    public var date: String
    public var deepgramSeconds: Double
    public var deepgramRequests: Int
    public var geminiPromptTokens: Int
    public var geminiCompletionTokens: Int
    public var geminiRequests: Int
    public var openaiPromptTokens: Int
    public var openaiCompletionTokens: Int
    public var openaiRequests: Int

    public init(
        date: String,
        deepgramSeconds: Double = 0,
        deepgramRequests: Int = 0,
        geminiPromptTokens: Int = 0,
        geminiCompletionTokens: Int = 0,
        geminiRequests: Int = 0,
        openaiPromptTokens: Int = 0,
        openaiCompletionTokens: Int = 0,
        openaiRequests: Int = 0
    ) {
        self.date = date
        self.deepgramSeconds = deepgramSeconds
        self.deepgramRequests = deepgramRequests
        self.geminiPromptTokens = geminiPromptTokens
        self.geminiCompletionTokens = geminiCompletionTokens
        self.geminiRequests = geminiRequests
        self.openaiPromptTokens = openaiPromptTokens
        self.openaiCompletionTokens = openaiCompletionTokens
        self.openaiRequests = openaiRequests
    }
}
