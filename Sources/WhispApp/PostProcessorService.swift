import Foundation
import WhispCore

final class PostProcessorService: @unchecked Sendable {
    private let providers: [any LLMAPIProvider]

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
        let sanitizedContext = sanitizeContextForPrompt(context)
        let prompt = buildPrompt(
            sttResult: sttResult,
            languageHint: languageHint,
            appName: appName,
            appPromptRules: appPromptRules,
            context: sanitizedContext
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

        let traceReference = PromptTrace.dump(
            stage: "postprocess",
            model: model.rawValue,
            appName: appName,
            context: sanitizedContext,
            prompt: prompt,
            extra: extra
        )

        do {
            let response = try await resolveProvider(model: model).postProcess(
                apiKey: apiKey,
                model: model,
                prompt: prompt
            )
            PromptTrace.writeResponse(response.text, usage: response.usage, reference: traceReference)
            return response
        } catch {
            PromptTrace.writeFailure(error.localizedDescription, reference: traceReference)
            throw error
        }
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
        let sanitizedContext = sanitizeContextForPrompt(context)
        var prompt = "次の音声を文字起こしし、フィラー除去と最小限の整形を行ってください。出力は整形後テキストのみ。"
        if let sanitizedContext, !sanitizedContext.isEmpty {
            prompt += "\n\n画面コンテキスト:\n\(contextPromptLines(sanitizedContext))"
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

        let traceReference = PromptTrace.dump(
            stage: "audio_transcribe",
            model: model.rawValue,
            appName: nil,
            context: sanitizedContext,
            prompt: prompt,
            extra: extra
        )

        do {
            let response = try await resolveProvider(model: model).transcribeAudio(
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                wavData: wavData,
                mimeType: mimeType
            )
            PromptTrace.writeResponse(response.text, usage: response.usage, reference: traceReference)
            return response
        } catch {
            PromptTrace.writeFailure(error.localizedDescription, reference: traceReference)
            throw error
        }
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

        let traceReference = PromptTrace.dump(
            stage: "accessibility_summary",
            model: model.rawValue,
            appName: appName,
            context: nil,
            prompt: prompt,
            extra: extra
        )

        do {
            let response = try await resolveProvider(model: model).postProcess(
                apiKey: apiKey,
                model: model,
                prompt: prompt
            )
            PromptTrace.writeResponse(response.text, usage: response.usage, reference: traceReference)
            guard let parsed = parseVisionContext(response.text) else {
                return nil
            }

            return ContextInfo(
                visionSummary: parsed.summary,
                visionTerms: parsed.terms
            )
        } catch {
            PromptTrace.writeFailure(error.localizedDescription, reference: traceReference)
            throw error
        }
    }

    private func sanitizeContextForPrompt(_ context: ContextInfo?) -> ContextInfo? {
        guard let context else {
            return nil
        }
        let sanitized = ContextInfo(
            accessibilityText: context.accessibilityText,
            visionSummary: context.visionSummary,
            visionTerms: context.visionTerms
        )
        return sanitized.isEmpty ? nil : sanitized
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
        return lines.joined(separator: "\n")
    }
}
