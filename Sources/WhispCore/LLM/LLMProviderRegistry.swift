import Foundation

public struct LLMProviderRegistry: Sendable {
    private let clientsByProviderID: [LLMProviderID: any LLMProviderClient]

    public init(clients: [any LLMProviderClient]) {
        var table: [LLMProviderID: any LLMProviderClient] = [:]
        for client in clients {
            table[client.providerID] = client
        }
        clientsByProviderID = table
    }

    public static func live() -> LLMProviderRegistry {
        LLMProviderRegistry(clients: [
            GeminiProviderClient(),
            OpenAIProviderClient(),
            MoonshotProviderClient(),
        ])
    }

    public func provider(for model: LLMModelID) throws -> any LLMProviderClient {
        guard let spec = LLMModelCatalog.spec(for: model) else {
            throw AppError.invalidArgument("LLM model が未登録です: \(model.rawValue)")
        }
        guard let provider = clientsByProviderID[spec.provider] else {
            throw AppError.invalidArgument("LLM provider が未対応です: \(spec.provider.rawValue)")
        }
        return provider
    }
}
