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

final class GeminiLLMAPIProvider: LLMAPIProvider, @unchecked Sendable {
    private let client: HTTPJSONClient

    init(client: HTTPJSONClient = HTTPJSONClient()) {
        self.client = client
    }

    func supports(model: LLMModel) -> Bool {
        switch model {
        case .gemini3FlashPreview, .gemini25FlashLite, .gemini25FlashLiteAudio:
            return true
        case .gpt4oMini, .gpt5Nano:
            return false
        }
    }

    func postProcess(
        apiKey: String,
        model: LLMModel,
        prompt: String
    ) async throws -> PostProcessResult {
        let requestBody = GeminiRequest(
            contents: [
                GeminiContent(role: "user", parts: [.text(prompt)]),
            ]
        )

        guard let url = URL(string: endpoint(apiKey: apiKey, model: model)) else {
            throw AppError.invalidArgument("Gemini URL生成に失敗")
        }

        let data = try await client.sendJSONRequest(url: url, method: "POST", headers: [:], body: requestBody)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)

        let text = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usage = decoded.usageMetadata.map {
            LLMUsage(model: model.modelName, promptTokens: $0.promptTokenCount, completionTokens: $0.candidatesTokenCount, provider: "gemini")
        }

        return PostProcessResult(text: text, usage: usage)
    }

    func transcribeAudio(
        apiKey: String,
        model: LLMModel,
        prompt: String,
        wavData: Data,
        mimeType: String
    ) async throws -> PostProcessResult {
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

        guard let url = URL(string: endpoint(apiKey: apiKey, model: model)) else {
            throw AppError.invalidArgument("Gemini URL生成に失敗")
        }

        let data = try await client.sendJSONRequest(url: url, method: "POST", headers: [:], body: requestBody)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)

        let text = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usage = decoded.usageMetadata.map {
            LLMUsage(model: model.modelName, promptTokens: $0.promptTokenCount, completionTokens: $0.candidatesTokenCount, provider: "gemini")
        }

        return PostProcessResult(text: text, usage: usage)
    }

    private func endpoint(apiKey: String, model: LLMModel) -> String {
        "https://generativelanguage.googleapis.com/v1beta/models/\(model.modelName):generateContent?key=\(apiKey)"
    }
}
