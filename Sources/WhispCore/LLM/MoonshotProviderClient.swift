import Foundation

private struct MoonshotProviderTextRequest: Encodable {
    let model: String
    let messages: [MoonshotProviderTextMessage]
}

private struct MoonshotProviderTextMessage: Encodable {
    let role: String
    let content: String
}

private struct MoonshotProviderImageURLContent: Encodable {
    let url: String
}

private enum MoonshotProviderContentPart: Encodable {
    case text(String)
    case imageURL(MoonshotProviderImageURLContent)

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

private enum MoonshotProviderMessageContent: Encodable {
    case text(String)
    case parts([MoonshotProviderContentPart])

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

private struct MoonshotProviderChatMessage: Encodable {
    let role: String
    let content: MoonshotProviderMessageContent
}

private struct MoonshotProviderChatRequest: Encodable {
    let model: String
    let messages: [MoonshotProviderChatMessage]
}

public struct MoonshotProviderClient: LLMProviderClient, Sendable {
    public let providerID: LLMProviderID = .moonshot

    private let client: HTTPJSONClient

    public init(client: HTTPJSONClient = HTTPJSONClient()) {
        self.client = client
    }

    public func send(request: LLMRequest) async throws -> LLMProviderResponse {
        let headers = ["Authorization": "Bearer \(request.apiKey)"]
        let data: Data

        switch request.payload {
        case let .text(prompt):
            let body = MoonshotProviderTextRequest(
                model: request.model.modelName,
                messages: [MoonshotProviderTextMessage(role: "user", content: prompt)]
            )
            data = try await client.sendJSONRequest(url: endpointURL(), method: "POST", headers: headers, body: body)
        case let .textWithImage(prompt, image):
            let dataURL = "data:\(image.mimeType);base64,\(image.base64Data)"
            let body = MoonshotProviderChatRequest(
                model: request.model.modelName,
                messages: [
                    MoonshotProviderChatMessage(
                        role: "user",
                        content: .parts([
                            .text(prompt),
                            .imageURL(MoonshotProviderImageURLContent(url: dataURL)),
                        ])
                    ),
                ]
            )
            data = try await client.sendJSONRequest(url: endpointURL(), method: "POST", headers: headers, body: body)
        case .audio:
            throw AppError.invalidArgument("Moonshot provider は audio 入力に未対応です")
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
        guard let url = URL(string: "https://api.moonshot.cn/v1/chat/completions") else {
            throw AppError.invalidArgument("Moonshot URL生成に失敗")
        }
        return url
    }
}
