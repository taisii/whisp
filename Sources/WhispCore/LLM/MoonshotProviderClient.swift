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
            data = try await sendWithEndpointFallback(headers: headers, body: body)
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
            data = try await sendWithEndpointFallback(headers: headers, body: body)
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

    private func sendWithEndpointFallback<T: Encodable>(headers: [String: String], body: T) async throws -> Data {
        let endpoints = try endpointURLs()
        var firstError: Error?

        for (index, url) in endpoints.enumerated() {
            do {
                return try await client.sendJSONRequest(url: url, method: "POST", headers: headers, body: body)
            } catch {
                if index == 0 {
                    firstError = error
                }
                if index == 0, shouldRetryOnSecondaryEndpoint(error) {
                    continue
                }
                throw error
            }
        }

        throw firstError ?? AppError.io("Moonshot API request failed")
    }

    private func shouldRetryOnSecondaryEndpoint(_ error: Error) -> Bool {
        guard case let .io(message) = (error as? AppError) else {
            return false
        }
        let normalized = message.lowercased()
        return normalized.contains("401") && normalized.contains("invalid_authentication_error")
    }

    private func endpointURLs() throws -> [URL] {
        let rawValues = [
            "https://api.moonshot.ai/v1/chat/completions",
            "https://api.moonshot.cn/v1/chat/completions",
        ]
        var urls: [URL] = []
        urls.reserveCapacity(rawValues.count)
        for raw in rawValues {
            guard let url = URL(string: raw) else {
                throw AppError.invalidArgument("Moonshot URL生成に失敗")
            }
            urls.append(url)
        }
        return urls
    }
}
