import Foundation
import WhispCore

final class PostProcessorService: @unchecked Sendable {
    private let providers: [any LLMAPIProvider]

    private let visionContextPrompt = """
    スクリーンショットを解析し、音声整形用のコンテキストをJSONのみで返してください。
    形式: {"summary":"...","terms":["..."]}
    ルール:
    - summary は1文で簡潔
    - terms は専門用語・固有名詞を最大10個
    - 情報がなければ summary は空文字、terms は空配列
    - JSON以外は出力しない
    """

    private let accessibilitySummaryPromptHeader = """
    次のアプリ本文を、音声整形に使うコンテキストとして要約してください。出力はJSONのみ。
    形式: {"summary":"...","terms":["..."]}
    ルール:
    - summary は1文で簡潔（最大120文字）
    - terms は固有名詞・専門用語を最大10個
    - 情報が不十分なら summary は空文字、terms は空配列
    - JSON以外は出力しない
    """

    init(providers: [any LLMAPIProvider] = [GeminiLLMAPIProvider(), OpenAILLMAPIProvider()]) {
        self.providers = providers
    }

    func postProcess(
        model: LLMModel,
        apiKey: String,
        sttResult: String,
        languageHint: String,
        appName: String?,
        appPromptRules: [AppPromptRule],
        context: ContextInfo?,
        debugRunID: String? = nil,
        debugRunDirectory: String? = nil
    ) async throws -> PostProcessResult {
        let prompt = buildPrompt(
            sttResult: sttResult,
            languageHint: languageHint,
            appName: appName,
            appPromptRules: appPromptRules,
            context: context
        )

        var extra: [String: String] = [
            "stt_chars": String(sttResult.count),
            "language_hint": languageHint,
            "rule_count": String(appPromptRules.count),
        ]
        if let debugRunID, !debugRunID.isEmpty {
            extra["run_id"] = debugRunID
        }
        if let debugRunDirectory, !debugRunDirectory.isEmpty {
            extra["run_dir"] = debugRunDirectory
        }

        PromptTrace.dump(
            stage: "postprocess",
            model: model.rawValue,
            appName: appName,
            context: context,
            prompt: prompt,
            extra: extra
        )

        return try await resolveProvider(model: model).postProcess(
            apiKey: apiKey,
            model: model,
            prompt: prompt
        )
    }

    func transcribeAudio(
        model: LLMModel,
        apiKey: String,
        wavData: Data,
        mimeType: String,
        context: ContextInfo?,
        debugRunID: String? = nil,
        debugRunDirectory: String? = nil
    ) async throws -> PostProcessResult {
        var prompt = "次の音声を文字起こしし、フィラー除去と最小限の整形を行ってください。出力は整形後テキストのみ。"
        if let context, !context.isEmpty {
            prompt += "\n\n画面コンテキスト:\n\(contextPromptLines(context))"
        }

        var extra: [String: String] = [
            "mime_type": mimeType,
            "audio_bytes": String(wavData.count),
        ]
        if let debugRunID, !debugRunID.isEmpty {
            extra["run_id"] = debugRunID
        }
        if let debugRunDirectory, !debugRunDirectory.isEmpty {
            extra["run_dir"] = debugRunDirectory
        }

        PromptTrace.dump(
            stage: "audio_transcribe",
            model: model.rawValue,
            appName: nil,
            context: context,
            prompt: prompt,
            extra: extra
        )

        return try await resolveProvider(model: model).transcribeAudio(
            apiKey: apiKey,
            model: model,
            prompt: prompt,
            wavData: wavData,
            mimeType: mimeType
        )
    }

    func analyzeVisionContext(
        model: LLMModel,
        apiKey: String,
        imageData: Data,
        mimeType: String = "image/png",
        debugRunID: String? = nil,
        debugRunDirectory: String? = nil
    ) async throws -> ContextInfo? {
        var extra: [String: String] = [
            "mime_type": mimeType,
            "image_bytes": String(imageData.count),
        ]
        if let debugRunID, !debugRunID.isEmpty {
            extra["run_id"] = debugRunID
        }
        if let debugRunDirectory, !debugRunDirectory.isEmpty {
            extra["run_dir"] = debugRunDirectory
        }

        PromptTrace.dump(
            stage: "vision_context",
            model: model.rawValue,
            appName: nil,
            context: nil,
            prompt: visionContextPrompt,
            extra: extra
        )

        let vision = try await resolveProvider(model: model).analyzeVisionContext(
            apiKey: apiKey,
            model: model,
            prompt: visionContextPrompt,
            imageData: imageData,
            mimeType: mimeType
        )

        guard let vision else { return nil }
        return ContextInfo(visionSummary: vision.summary, visionTerms: vision.terms)
    }

    func summarizeAccessibilityContext(
        model: LLMModel,
        apiKey: String,
        appName: String?,
        sourceText: String,
        debugRunID: String? = nil,
        debugRunDirectory: String? = nil
    ) async throws -> ContextInfo? {
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            return nil
        }

        var prompt = accessibilitySummaryPromptHeader
        if let appName = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
            prompt += "\n\nアプリ名: \(appName)"
        }
        prompt += "\n\n本文:\n\(trimmedSource)"

        var extra: [String: String] = [
            "source_chars": String(trimmedSource.count),
            "source": "accessibility_window_text",
        ]
        if let debugRunID, !debugRunID.isEmpty {
            extra["run_id"] = debugRunID
        }
        if let debugRunDirectory, !debugRunDirectory.isEmpty {
            extra["run_dir"] = debugRunDirectory
        }

        PromptTrace.dump(
            stage: "accessibility_summary",
            model: model.rawValue,
            appName: appName,
            context: nil,
            prompt: prompt,
            extra: extra
        )

        let response = try await resolveProvider(model: model).postProcess(
            apiKey: apiKey,
            model: model,
            prompt: prompt
        )
        guard let parsed = parseVisionContext(response.text) else {
            return nil
        }

        return ContextInfo(
            visionSummary: parsed.summary,
            visionTerms: parsed.terms
        )
    }

    private func resolveProvider(model: LLMModel) throws -> any LLMAPIProvider {
        guard let provider = providers.first(where: { $0.supports(model: model) }) else {
            throw AppError.invalidArgument("model \(model.rawValue) に対応するLLM provider がありません")
        }
        return provider
    }

    private func contextPromptLines(_ context: ContextInfo) -> String {
        var lines: [String] = []
        if let summary = context.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("- 画面の要約: \(summary)")
        }
        if !context.visionTerms.isEmpty {
            lines.append("- 専門用語候補: \(context.visionTerms.joined(separator: ", "))")
        }
        if let accessibility = context.accessibilityText?.trimmingCharacters(in: .whitespacesAndNewlines), !accessibility.isEmpty {
            lines.append("- 選択テキスト: \(accessibility)")
        }
        if let windowText = context.windowText?.trimmingCharacters(in: .whitespacesAndNewlines), !windowText.isEmpty {
            lines.append("- 同一ウィンドウ本文: \(windowText)")
        }
        return lines.joined(separator: "\n")
    }
}
