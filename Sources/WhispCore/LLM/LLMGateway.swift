import Foundation

public struct LLMGateway: Sendable {
    private let registry: LLMProviderRegistry

    public init(registry: LLMProviderRegistry = .live()) {
        self.registry = registry
    }

    public func send(request: LLMRequest) async throws -> PostProcessResult {
        let provider = try registry.provider(for: request.model)
        let response = try await provider.send(request: request)
        return PostProcessResult(text: response.text, usage: response.usage)
    }

    public func send(apiKey: String, model: LLMModelID, payload: LLMRequestPayload) async throws -> PostProcessResult {
        try await send(request: LLMRequest(model: model, apiKey: apiKey, payload: payload))
    }

    public func postProcess(apiKey: String, model: LLMModelID, prompt: String) async throws -> PostProcessResult {
        try await send(apiKey: apiKey, model: model, payload: .text(prompt: prompt))
    }

    public func transcribeAudio(
        apiKey: String,
        model: LLMModelID,
        prompt: String,
        audioData: Data,
        mimeType: String
    ) async throws -> PostProcessResult {
        try await send(
            apiKey: apiKey,
            model: model,
            payload: .audio(
                prompt: prompt,
                mimeType: mimeType,
                base64Audio: audioData.base64EncodedString()
            )
        )
    }

    public func judgeWithImage(
        apiKey: String,
        model: LLMModelID,
        prompt: String,
        imageData: Data,
        imageMimeType: String
    ) async throws -> PostProcessResult {
        try await send(
            apiKey: apiKey,
            model: model,
            payload: .textWithImage(
                prompt: prompt,
                image: LLMRequestImage(
                    mimeType: imageMimeType,
                    base64Data: imageData.base64EncodedString()
                )
            )
        )
    }
}
