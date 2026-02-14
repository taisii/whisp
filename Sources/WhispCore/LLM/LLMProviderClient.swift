import Foundation

public struct LLMRequestImage: Sendable, Equatable {
    public let mimeType: String
    public let base64Data: String

    public init(mimeType: String, base64Data: String) {
        self.mimeType = mimeType
        self.base64Data = base64Data
    }
}

public enum LLMRequestPayload: Sendable, Equatable {
    case text(prompt: String)
    case textWithImage(prompt: String, image: LLMRequestImage)
    case audio(prompt: String, mimeType: String, base64Audio: String)
}

public struct LLMRequest: Sendable, Equatable {
    public let model: LLMModelID
    public let apiKey: String
    public let payload: LLMRequestPayload

    public init(model: LLMModelID, apiKey: String, payload: LLMRequestPayload) {
        self.model = model
        self.apiKey = apiKey
        self.payload = payload
    }
}

public struct LLMProviderResponse: Sendable, Equatable {
    public let text: String
    public let usage: LLMUsage?

    public init(text: String, usage: LLMUsage?) {
        self.text = text
        self.usage = usage
    }
}

public protocol LLMProviderClient: Sendable {
    var providerID: LLMProviderID { get }

    func send(request: LLMRequest) async throws -> LLMProviderResponse
}
