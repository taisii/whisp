import Foundation
import WhispCore

private struct GeminiRequest: Encodable {
    let contents: [GeminiContent]
}

private struct GeminiContent: Encodable {
    let role: String
    let parts: [GeminiPart]
}

private struct GeminiPart: Encodable {
    let text: String?
    let inlineData: GeminiInlineData?

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }

    static func text(_ value: String) -> GeminiPart {
        GeminiPart(text: value, inlineData: nil)
    }

    static func inline(mimeType: String, data: String) -> GeminiPart {
        GeminiPart(text: nil, inlineData: GeminiInlineData(mimeType: mimeType, data: data))
    }
}

private struct GeminiInlineData: Encodable {
    let mimeType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIVisionRequest: Encodable {
    let model: String
    let messages: [OpenAIVisionMessage]
}

private struct OpenAIVisionMessage: Encodable {
    let role: String
    let content: [OpenAIVisionContent]
}

private struct OpenAIVisionContent: Encodable {
    let type: String
    let text: String?
    let imageURL: OpenAIImageURL?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    static func text(_ text: String) -> OpenAIVisionContent {
        OpenAIVisionContent(type: "text", text: text, imageURL: nil)
    }

    static func imageDataURL(_ dataURL: String) -> OpenAIVisionContent {
        OpenAIVisionContent(type: "image_url", text: nil, imageURL: OpenAIImageURL(url: dataURL))
    }
}

private struct OpenAIImageURL: Encodable {
    let url: String
}

@MainActor
final class PostProcessorService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private let visionContextPrompt = """
    スクリーンショットを解析し、音声整形用のコンテキストをJSONのみで返してください。
    形式: {"summary":"...","terms":["..."]}
    ルール:
    - summary は1文で簡潔
    - terms は専門用語・固有名詞を最大10個
    - 情報がなければ summary は空文字、terms は空配列
    - JSON以外は出力しない
    """

    func postProcess(
        model: LLMModel,
        apiKey: String,
        sttResult: String,
        languageHint: String,
        appName: String?,
        appPromptRules: [AppPromptRule],
        context: ContextInfo?,
        debugRunID: String? = nil
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
        PromptTrace.dump(
            stage: "postprocess",
            model: model.rawValue,
            appName: appName,
            context: context,
            prompt: prompt,
            extra: extra
        )

        switch model {
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            return try await postProcessGemini(apiKey: apiKey, prompt: prompt)
        case .gpt4oMini, .gpt5Nano:
            return try await postProcessOpenAI(apiKey: apiKey, model: model, prompt: prompt)
        }
    }

    func transcribeAudioGemini(
        apiKey: String,
        wavData: Data,
        mimeType: String,
        context: ContextInfo?,
        debugRunID: String? = nil
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
        PromptTrace.dump(
            stage: "audio_transcribe",
            model: LLMModel.gemini25FlashLiteAudio.rawValue,
            appName: nil,
            context: context,
            prompt: prompt,
            extra: extra
        )
        let requestBody = GeminiRequest(
            contents: [
                GeminiContent(
                    role: "user",
                    parts: [
                        .text(prompt),
                        .inline(mimeType: mimeType, data: wavData.base64EncodedString()),
                    ]
                ),
            ]
        )

        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(LLMModel.gemini25FlashLite.modelName):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw AppError.invalidArgument("Gemini URL生成に失敗")
        }

        let data = try await sendJSONRequest(url: url, method: "POST", headers: [:], body: requestBody)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)

        let text = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usage = decoded.usageMetadata.map {
            LLMUsage(model: LLMModel.gemini25FlashLite.modelName, promptTokens: $0.promptTokenCount, completionTokens: $0.candidatesTokenCount)
        }

        return PostProcessResult(text: text, usage: usage)
    }

    func analyzeVisionContext(
        model: LLMModel,
        apiKey: String,
        imageData: Data,
        mimeType: String = "image/png",
        debugRunID: String? = nil
    ) async throws -> ContextInfo? {
        let vision: VisionContext?
        switch model {
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            vision = try await analyzeVisionContextGemini(
                apiKey: apiKey,
                imageData: imageData,
                mimeType: mimeType,
                debugRunID: debugRunID
            )
        case .gpt4oMini, .gpt5Nano:
            vision = try await analyzeVisionContextOpenAI(
                apiKey: apiKey,
                model: model,
                imageData: imageData,
                mimeType: mimeType,
                debugRunID: debugRunID
            )
        }

        guard let vision else { return nil }
        return ContextInfo(visionSummary: vision.summary, visionTerms: vision.terms)
    }

    private func postProcessGemini(apiKey: String, prompt: String) async throws -> PostProcessResult {
        let requestBody = GeminiRequest(
            contents: [
                GeminiContent(role: "user", parts: [.text(prompt)]),
            ]
        )

        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(LLMModel.gemini25FlashLite.modelName):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw AppError.invalidArgument("Gemini URL生成に失敗")
        }

        let data = try await sendJSONRequest(url: url, method: "POST", headers: [:], body: requestBody)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)

        let text = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usage = decoded.usageMetadata.map {
            LLMUsage(model: LLMModel.gemini25FlashLite.modelName, promptTokens: $0.promptTokenCount, completionTokens: $0.candidatesTokenCount)
        }

        return PostProcessResult(text: text, usage: usage)
    }

    private func postProcessOpenAI(apiKey: String, model: LLMModel, prompt: String) async throws -> PostProcessResult {
        let requestBody = OpenAIRequest(
            model: model.modelName,
            messages: [OpenAIMessage(role: "user", content: prompt)]
        )

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AppError.invalidArgument("OpenAI URL生成に失敗")
        }

        let headers = ["Authorization": "Bearer \(apiKey)"]
        let data = try await sendJSONRequest(url: url, method: "POST", headers: headers, body: requestBody)
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)

        let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usage = decoded.usage.map {
            LLMUsage(model: model.modelName, promptTokens: $0.promptTokens, completionTokens: $0.completionTokens)
        }

        return PostProcessResult(text: text, usage: usage)
    }

    private func analyzeVisionContextGemini(
        apiKey: String,
        imageData: Data,
        mimeType: String,
        debugRunID: String?
    ) async throws -> VisionContext? {
        var extra: [String: String] = [
            "mime_type": mimeType,
            "image_bytes": String(imageData.count),
        ]
        if let debugRunID, !debugRunID.isEmpty {
            extra["run_id"] = debugRunID
        }
        PromptTrace.dump(
            stage: "vision_context",
            model: LLMModel.gemini25FlashLite.rawValue,
            appName: nil,
            context: nil,
            prompt: visionContextPrompt,
            extra: extra
        )
        let requestBody = GeminiRequest(
            contents: [
                GeminiContent(
                    role: "user",
                    parts: [
                        .text(visionContextPrompt),
                        .inline(mimeType: mimeType, data: imageData.base64EncodedString()),
                    ]
                ),
            ]
        )

        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(LLMModel.gemini25FlashLite.modelName):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw AppError.invalidArgument("Gemini URL生成に失敗")
        }

        let data = try await sendJSONRequest(url: url, method: "POST", headers: [:], body: requestBody)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = decoded.candidates.first?.content.joinedText ?? ""
        return parseVisionContext(text)
    }

    private func analyzeVisionContextOpenAI(
        apiKey: String,
        model: LLMModel,
        imageData: Data,
        mimeType: String,
        debugRunID: String?
    ) async throws -> VisionContext? {
        var extra: [String: String] = [
            "mime_type": mimeType,
            "image_bytes": String(imageData.count),
        ]
        if let debugRunID, !debugRunID.isEmpty {
            extra["run_id"] = debugRunID
        }
        PromptTrace.dump(
            stage: "vision_context",
            model: model.rawValue,
            appName: nil,
            context: nil,
            prompt: visionContextPrompt,
            extra: extra
        )
        let dataURL = "data:\(mimeType);base64,\(imageData.base64EncodedString())"
        let requestBody = OpenAIVisionRequest(
            model: model.modelName,
            messages: [
                OpenAIVisionMessage(
                    role: "user",
                    content: [
                        .text(visionContextPrompt),
                        .imageDataURL(dataURL),
                    ]
                ),
            ]
        )

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AppError.invalidArgument("OpenAI URL生成に失敗")
        }

        let headers = ["Authorization": "Bearer \(apiKey)"]
        let data = try await sendJSONRequest(url: url, method: "POST", headers: headers, body: requestBody)
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        let text = decoded.choices.first?.message.content ?? ""
        return parseVisionContext(text)
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

    private func sendJSONRequest<T: Encodable>(
        url: URL,
        method: String,
        headers: [String: String],
        body: T
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.io("HTTPレスポンスが不正")
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AppError.invalidArgument("API error: \(http.statusCode) \(bodyText)")
        }

        return data
    }
}
