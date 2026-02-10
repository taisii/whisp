import Foundation
import WhispCore

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

final class OpenAILLMAPIProvider: LLMAPIProvider, @unchecked Sendable {
    private let client: HTTPJSONClient

    init(client: HTTPJSONClient = HTTPJSONClient()) {
        self.client = client
    }

    func supports(model: LLMModel) -> Bool {
        switch model {
        case .gpt4oMini, .gpt5Nano:
            return true
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            return false
        }
    }

    func postProcess(
        apiKey: String,
        model: LLMModel,
        prompt: String
    ) async throws -> PostProcessResult {
        let requestBody = OpenAIRequest(
            model: model.modelName,
            messages: [OpenAIMessage(role: "user", content: prompt)]
        )

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AppError.invalidArgument("OpenAI URL生成に失敗")
        }

        let headers = ["Authorization": "Bearer \(apiKey)"]
        let data = try await client.sendJSONRequest(url: url, method: "POST", headers: headers, body: requestBody)
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)

        let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usage = decoded.usage.map {
            LLMUsage(model: model.modelName, promptTokens: $0.promptTokens, completionTokens: $0.completionTokens)
        }

        return PostProcessResult(text: text, usage: usage)
    }

    func transcribeAudio(
        apiKey _: String,
        model _: LLMModel,
        prompt _: String,
        wavData _: Data,
        mimeType _: String
    ) async throws -> PostProcessResult {
        throw AppError.invalidArgument("OpenAI provider は audio transcription に未対応です")
    }

    func analyzeVisionContext(
        apiKey: String,
        model: LLMModel,
        prompt: String,
        imageData: Data,
        mimeType: String
    ) async throws -> VisionContext? {
        let dataURL = "data:\(mimeType);base64,\(imageData.base64EncodedString())"
        let requestBody = OpenAIVisionRequest(
            model: model.modelName,
            messages: [
                OpenAIVisionMessage(
                    role: "user",
                    content: [
                        .text(prompt),
                        .imageDataURL(dataURL),
                    ]
                ),
            ]
        )

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AppError.invalidArgument("OpenAI URL生成に失敗")
        }

        let headers = ["Authorization": "Bearer \(apiKey)"]
        let data = try await client.sendJSONRequest(url: url, method: "POST", headers: headers, body: requestBody)
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        let text = decoded.choices.first?.message.content ?? ""
        return parseVisionContext(text)
    }
}
