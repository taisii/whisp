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
        guard let spec = LLMModelCatalog.spec(for: model) else {
            throw AppError.invalidArgument("LLM model が未登録です: \(model.rawValue)")
        }

        switch spec.provider {
        case .gemini:
            let key = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AppError.invalidArgument("Gemini APIキーが未設定です")
            }
            return key
        case .openai:
            let key = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AppError.invalidArgument("OpenAI APIキーが未設定です")
            }
            return key
        }
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
            let openAIKey = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
            if !openAIKey.isEmpty {
                if let openAIJudge = selectModel(for: .cliJudge, provider: .openai) {
                    return (openAIJudge.id, openAIKey)
                }
            }

            let geminiKey = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
            if !geminiKey.isEmpty {
                if let geminiJudge = selectModel(for: .cliJudge, provider: .gemini) {
                    return (geminiJudge.id, geminiKey)
                }
            }

            throw AppError.invalidArgument("画像対応の intent judge 用APIキーが未設定です（openai または gemini）")
        }

        let openAIKey = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
        if !openAIKey.isEmpty {
            if let openAIJudge = selectModel(for: .cliLLMEval, provider: .openai) {
                return (openAIJudge.id, openAIKey)
            }
        }

        let geminiKey = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
        if !geminiKey.isEmpty {
            if let geminiJudge = selectModel(for: .cliLLMEval, provider: .gemini) {
                return (geminiJudge.id, geminiKey)
            }
        }

        throw AppError.invalidArgument("intent judge 用のAPIキーが未設定です（openai または gemini）")
    }

    private static func selectModel(for surface: LLMSelectionSurface, provider: LLMProvider) -> LLMModelSpec? {
        let selectable = LLMModelCatalog.selectableModels(for: surface)
        let defaultModel = LLMModelCatalog.defaultModel(for: surface)
        if let defaultSpec = LLMModelCatalog.spec(for: defaultModel),
           defaultSpec.provider == provider,
           selectable.contains(where: { $0.id == defaultSpec.id })
        {
            return defaultSpec
        }
        return selectable.first(where: { $0.provider == provider })
    }
}
