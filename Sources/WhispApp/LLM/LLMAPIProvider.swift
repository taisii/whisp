import Foundation
import WhispCore

protocol LLMAPIProvider: Sendable {
    func supports(model: LLMModel) -> Bool

    func postProcess(
        apiKey: String,
        model: LLMModel,
        prompt: String
    ) async throws -> PostProcessResult

    func transcribeAudio(
        apiKey: String,
        model: LLMModel,
        prompt: String,
        wavData: Data,
        mimeType: String
    ) async throws -> PostProcessResult
}
