import Foundation

public enum APIKeyResolver {
    public static func sttKey(config: Config, provider: STTProvider) throws -> String {
        switch provider {
        case .deepgram:
            let key = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AppError.invalidArgument("Deepgram APIキーが未設定です")
            }
            return key
        case .whisper:
            let key = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AppError.invalidArgument("OpenAI APIキーが未設定です（Whisper STT）")
            }
            return key
        case .appleSpeech:
            return ""
        }
    }

    public static func llmKey(config: Config, model: LLMModel) throws -> String {
        switch model {
        case .gemini3FlashPreview, .gemini25FlashLite, .gemini25FlashLiteAudio:
            let key = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AppError.invalidArgument("Gemini APIキーが未設定です")
            }
            return key
        case .gpt4oMini, .gpt5Nano:
            let key = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AppError.invalidArgument("OpenAI APIキーが未設定です")
            }
            return key
        }
    }

    public static func effectivePostProcessModel(_ model: LLMModel) -> LLMModel {
        switch model {
        case .gemini25FlashLiteAudio:
            return .gemini25FlashLite
        default:
            return model
        }
    }

    public static func supportsVision(model: LLMModel) -> Bool {
        switch model {
        case .gemini3FlashPreview, .gemini25FlashLite, .gpt4oMini:
            return true
        case .gemini25FlashLiteAudio, .gpt5Nano:
            return false
        }
    }

    public static func resolveIntentJudgeContext(
        config: Config,
        preferredModel: LLMModel?,
        requiresVision: Bool = false
    ) throws -> (model: LLMModel, apiKey: String) {
        if let preferredModel {
            if requiresVision, !supportsVision(model: preferredModel) {
                throw AppError.invalidArgument(
                    "judge model \(preferredModel.rawValue) は画像入力に未対応です。--judge-model は gpt-4o-mini / gemini-3-flash-preview / gemini-2.5-flash-lite を指定してください"
                )
            }
            let model = effectivePostProcessModel(preferredModel)
            return (model, try llmKey(config: config, model: model))
        }

        if requiresVision {
            let openAIKey = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
            if !openAIKey.isEmpty {
                return (.gpt4oMini, openAIKey)
            }

            let geminiKey = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
            if !geminiKey.isEmpty {
                return (.gemini25FlashLite, geminiKey)
            }

            throw AppError.invalidArgument("画像対応の intent judge 用APIキーが未設定です（openai または gemini）")
        }

        let openAIKey = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
        if !openAIKey.isEmpty {
            return (.gpt5Nano, openAIKey)
        }

        let geminiKey = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
        if !geminiKey.isEmpty {
            return (.gemini25FlashLite, geminiKey)
        }

        throw AppError.invalidArgument("intent judge 用のAPIキーが未設定です（openai または gemini）")
    }
}
