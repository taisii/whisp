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
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            return true
        case .gpt4oMini, .gpt5Nano:
            return false
        }
    }

    func postProcess(
        apiKey: String,
        model _: LLMModel,
        prompt: String
    ) async throws -> PostProcessResult {
        let requestBody = GeminiRequest(
            contents: [
                GeminiContent(role: "user", parts: [.text(prompt)]),
            ]
        )

        guard let url = URL(string: endpoint(apiKey: apiKey)) else {
            throw AppError.invalidArgument("Gemini URL生成に失敗")
        }

        let data = try await client.sendJSONRequest(url: url, method: "POST", headers: [:], body: requestBody)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)

        let text = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usage = decoded.usageMetadata.map {
            LLMUsage(model: LLMModel.gemini25FlashLite.modelName, promptTokens: $0.promptTokenCount, completionTokens: $0.candidatesTokenCount)
        }

        return PostProcessResult(text: text, usage: usage)
    }

    func transcribeAudio(
        apiKey: String,
        model _: LLMModel,
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

        guard let url = URL(string: endpoint(apiKey: apiKey)) else {
            throw AppError.invalidArgument("Gemini URL生成に失敗")
        }

        let data = try await client.sendJSONRequest(url: url, method: "POST", headers: [:], body: requestBody)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)

        let text = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usage = decoded.usageMetadata.map {
            LLMUsage(model: LLMModel.gemini25FlashLite.modelName, promptTokens: $0.promptTokenCount, completionTokens: $0.candidatesTokenCount)
        }

        return PostProcessResult(text: text, usage: usage)
    }

    func analyzeVisionContext(
        apiKey: String,
        model _: LLMModel,
        prompt: String,
        imageData: Data,
        mimeType: String
    ) async throws -> VisionContext? {
        let requestBody = GeminiRequest(
            contents: [
                GeminiContent(
                    role: "user",
                    parts: [
                        .text(prompt),
                        .inline(mimeType: mimeType, data: imageData.base64EncodedString()),
                    ]
                ),
            ]
        )

        guard let url = URL(string: endpoint(apiKey: apiKey)) else {
            throw AppError.invalidArgument("Gemini URL生成に失敗")
        }

        let data = try await client.sendJSONRequest(url: url, method: "POST", headers: [:], body: requestBody)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = decoded.candidates.first?.content.joinedText ?? ""
        return parseVisionContext(text)
    }

    private func endpoint(apiKey: String) -> String {
        "https://generativelanguage.googleapis.com/v1beta/models/\(LLMModel.gemini25FlashLite.modelName):generateContent?key=\(apiKey)"
    }
}
