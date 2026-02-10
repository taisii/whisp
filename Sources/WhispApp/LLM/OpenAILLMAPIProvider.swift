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
            LLMUsage(model: model.modelName, promptTokens: $0.promptTokens, completionTokens: $0.completionTokens, provider: "openai")
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
}
