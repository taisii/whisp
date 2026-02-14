import Foundation

public enum APIKeyResolver {
    public static func sttCredential(config: Config, provider: STTProvider) throws -> STTCredential {
        switch provider {
        case .deepgram:
            return .apiKey(try resolveDeepgramKey(config))
        case .whisper:
            return .apiKey(try resolveOpenAIKeyForWhisper(config))
        case .appleSpeech:
            return .none
        }
    }

    @available(*, deprecated, message: "Use sttCredential(config:provider:) instead.")
    public static func sttKey(config: Config, provider: STTProvider) throws -> String {
        switch try sttCredential(config: config, provider: provider) {
        case let .apiKey(value):
            return value
        case .none:
            return ""
        }
    }

    public static func llmKey(config: Config, model: LLMModel) throws -> String {
        guard let spec = LLMModelCatalog.spec(for: model) else {
            throw AppError.invalidArgument("LLM model が未登録です: \(model.rawValue)")
        }
        let key = config.apiKeys.value(for: spec.provider)
        guard !key.isEmpty else {
            throw AppError.invalidArgument("\(displayName(for: spec.provider)) APIキーが未設定です")
        }
        return key
    }

    public static func effectivePostProcessModel(_ model: LLMModel) -> LLMModel {
        let resolved = LLMModelCatalog.resolveOrFallback(model, for: .pipelineExecution)
        if resolved == .gemini25FlashLiteAudio {
            return .gemini25FlashLite
        }
        return resolved
    }

    public static func supportsVision(model: LLMModel) -> Bool {
        LLMModelCatalog.supports(.supportsVision, model: model)
    }

    public static func resolveIntentJudgeContext(
        config: Config,
        preferredModel: LLMModel?,
        requiresVision: Bool = false
    ) throws -> (model: LLMModel, apiKey: String) {
        if let preferredModel {
            guard LLMModelCatalog.isRegistered(preferredModel) else {
                throw AppError.invalidArgument("judge model \(preferredModel.rawValue) は未登録です")
            }
            if requiresVision, !supportsVision(model: preferredModel) {
                throw AppError.invalidArgument(
                    "judge model \(preferredModel.rawValue) は画像入力に未対応です。--judge-model は \(LLMModelCatalog.allowedModelRawValueText(for: .cliJudge)) を指定してください"
                )
            }
            let model = effectivePostProcessModel(preferredModel)
            return (model, try llmKey(config: config, model: model))
        }

        if requiresVision {
            if let resolved = autoSelectJudge(config: config, surface: .cliJudge) {
                return resolved
            }
            throw AppError.invalidArgument("画像対応の intent judge 用APIキーが未設定です")
        }

        if let resolved = autoSelectJudge(config: config, surface: .cliLLMEval) {
            return resolved
        }
        throw AppError.invalidArgument("intent judge 用のAPIキーが未設定です")
    }

    private static func autoSelectJudge(
        config: Config,
        surface: LLMSelectionSurface
    ) -> (model: LLMModel, apiKey: String)? {
        let selectable = LLMModelCatalog.selectableModels(for: surface)
        for spec in selectable {
            let key = config.apiKeys.value(for: spec.provider)
            if !key.isEmpty {
                return (spec.id, key)
            }
        }
        return nil
    }

    private static func displayName(for provider: LLMProviderID) -> String {
        switch provider {
        case .gemini:
            return "Gemini"
        case .openai:
            return "OpenAI"
        case .moonshot:
            return "Moonshot"
        case .deepgram:
            return "Deepgram"
        default:
            return provider.rawValue
        }
    }

    private static func resolveDeepgramKey(_ config: Config) throws -> String {
        let key = config.apiKeys.value(for: .deepgram)
        guard !key.isEmpty else {
            throw AppError.invalidArgument("Deepgram APIキーが未設定です")
        }
        return key
    }

    private static func resolveOpenAIKeyForWhisper(_ config: Config) throws -> String {
        let key = config.apiKeys.value(for: .openai)
        guard !key.isEmpty else {
            throw AppError.invalidArgument("OpenAI APIキーが未設定です（Whisper STT）")
        }
        return key
    }
}
