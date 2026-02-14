import Foundation

private struct OpenAIProviderTextRequest: Encodable {
    let model: String
    let messages: [OpenAIProviderTextMessage]
}

private struct OpenAIProviderTextMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIProviderImageURLContent: Encodable {
    let url: String
}

private enum OpenAIProviderContentPart: Encodable {
    case text(String)
    case imageURL(OpenAIProviderImageURLContent)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    private enum ContentType: String, Encodable {
        case text
        case imageURL = "image_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode(ContentType.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case let .imageURL(value):
            try container.encode(ContentType.imageURL, forKey: .type)
            try container.encode(value, forKey: .imageURL)
        }
    }
}

private enum OpenAIProviderMessageContent: Encodable {
    case text(String)
    case parts([OpenAIProviderContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value):
            try container.encode(value)
        case let .parts(value):
            try container.encode(value)
        }
    }
}

private struct OpenAIProviderChatMessage: Encodable {
    let role: String
    let content: OpenAIProviderMessageContent
}

private struct OpenAIProviderChatRequest: Encodable {
    let model: String
    let messages: [OpenAIProviderChatMessage]
}

public struct OpenAIProviderClient: LLMProviderClient, Sendable {
    public let providerID: LLMProviderID = .openai

    private let client: HTTPJSONClient

    public init(client: HTTPJSONClient = HTTPJSONClient()) {
        self.client = client
    }

    public func send(request: LLMRequest) async throws -> LLMProviderResponse {
        let headers = ["Authorization": "Bearer \(request.apiKey)"]
        let data: Data

        switch request.payload {
        case let .text(prompt):
            let body = OpenAIProviderTextRequest(
                model: request.model.modelName,
                messages: [OpenAIProviderTextMessage(role: "user", content: prompt)]
            )
            data = try await client.sendJSONRequest(url: endpointURL(), method: "POST", headers: headers, body: body)
        case let .textWithImage(prompt, image):
            let dataURL = "data:\(image.mimeType);base64,\(image.base64Data)"
            let body = OpenAIProviderChatRequest(
                model: request.model.modelName,
                messages: [
                    OpenAIProviderChatMessage(
                        role: "user",
                        content: .parts([
                            .text(prompt),
                            .imageURL(OpenAIProviderImageURLContent(url: dataURL)),
                        ])
                    ),
                ]
            )
            data = try await client.sendJSONRequest(url: endpointURL(), method: "POST", headers: headers, body: body)
        case .audio:
            throw AppError.invalidArgument("OpenAI provider は audio 入力に未対応です")
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usage = decoded.usage.map {
            LLMUsage(
                model: request.model.modelName,
                promptTokens: $0.promptTokens,
                completionTokens: $0.completionTokens,
                provider: providerID.rawValue
            )
        }

        return LLMProviderResponse(text: text, usage: usage)
    }

    private func endpointURL() throws -> URL {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AppError.invalidArgument("OpenAI URL生成に失敗")
        }
        return url
    }
}
