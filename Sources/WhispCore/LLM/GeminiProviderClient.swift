import Foundation

private struct GeminiProviderRequest: Encodable {
    let contents: [GeminiProviderContent]
}

private struct GeminiProviderContent: Encodable {
    let role: String
    let parts: [GeminiProviderPart]
}

private struct GeminiProviderPart: Encodable {
    let text: String?
    let inlineData: GeminiProviderInlineData?

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }

    static func text(_ value: String) -> GeminiProviderPart {
        GeminiProviderPart(text: value, inlineData: nil)
    }

    static func inline(mimeType: String, data: String) -> GeminiProviderPart {
        GeminiProviderPart(text: nil, inlineData: GeminiProviderInlineData(mimeType: mimeType, data: data))
    }
}

private struct GeminiProviderInlineData: Encodable {
    let mimeType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }
}

public struct GeminiProviderClient: LLMProviderClient, Sendable {
    public let providerID: LLMProviderID = .gemini

    private let client: HTTPJSONClient

    public init(client: HTTPJSONClient = HTTPJSONClient()) {
        self.client = client
    }

    public func send(request: LLMRequest) async throws -> LLMProviderResponse {
        let parts: [GeminiProviderPart]
        switch request.payload {
        case let .text(prompt):
            parts = [.text(prompt)]
        case let .textWithImage(prompt, image):
            parts = [
                .text(prompt),
                .inline(mimeType: image.mimeType, data: image.base64Data),
            ]
        case let .audio(prompt, mimeType, base64Audio):
            parts = [
                .text(prompt),
                .inline(mimeType: mimeType, data: base64Audio),
            ]
        }

        let body = GeminiProviderRequest(contents: [
            GeminiProviderContent(role: "user", parts: parts),
        ])

        guard let url = URL(string: endpoint(apiKey: request.apiKey, model: request.model)) else {
            throw AppError.invalidArgument("Gemini URL生成に失敗")
        }

        let data = try await client.sendJSONRequest(url: url, method: "POST", headers: [:], body: body)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usage = decoded.usageMetadata.map {
            LLMUsage(
                model: request.model.modelName,
                promptTokens: $0.promptTokenCount,
                completionTokens: $0.candidatesTokenCount,
                provider: providerID.rawValue
            )
        }

        return LLMProviderResponse(text: text, usage: usage)
    }

    private func endpoint(apiKey: String, model: LLMModelID) -> String {
        "https://generativelanguage.googleapis.com/v1beta/models/\(model.modelName):generateContent?key=\(apiKey)"
    }
}
