import XCTest
@testable import WhispCore

final class APIKeyResolverTests: XCTestCase {
    func testResolvesSTTKeyByProvider() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"))
        XCTAssertEqual(try APIKeyResolver.sttKey(config: config, provider: .deepgram), "dg")
        XCTAssertEqual(try APIKeyResolver.sttKey(config: config, provider: .whisper), "oa")
        XCTAssertEqual(try APIKeyResolver.sttKey(config: config, provider: .appleSpeech), "")
    }

    func testResolvesLLMKeyByModel() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"))
        XCTAssertEqual(try APIKeyResolver.llmKey(config: config, model: .gemini25FlashLite), "gm")
        XCTAssertEqual(try APIKeyResolver.llmKey(config: config, model: .gpt5Nano), "oa")
    }

    func testEffectivePostProcessModelMapsAudioModel() {
        XCTAssertEqual(APIKeyResolver.effectivePostProcessModel(.gemini25FlashLiteAudio), .gemini25FlashLite)
        XCTAssertEqual(APIKeyResolver.effectivePostProcessModel(.gpt4oMini), .gpt4oMini)
    }

    func testResolveIntentJudgeContextPrefersExplicitModel() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "gm", openai: "oa"))
        let resolved = try APIKeyResolver.resolveIntentJudgeContext(config: config, preferredModel: .gemini25FlashLiteAudio)
        XCTAssertEqual(resolved.model, .gemini25FlashLite)
        XCTAssertEqual(resolved.apiKey, "gm")
    }

    func testResolveIntentJudgeContextRequiresVisionRejectsUnsupportedModel() {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "gm", openai: "oa"))
        XCTAssertThrowsError(
            try APIKeyResolver.resolveIntentJudgeContext(
                config: config,
                preferredModel: .gpt5Nano,
                requiresVision: true
            )
        )
    }

    func testResolveIntentJudgeContextRequiresVisionRejectsGeminiAudioModel() {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "gm", openai: "oa"))
        XCTAssertThrowsError(
            try APIKeyResolver.resolveIntentJudgeContext(
                config: config,
                preferredModel: .gemini25FlashLiteAudio,
                requiresVision: true
            )
        )
    }

    func testResolveIntentJudgeContextRequiresVisionAutoSelectsOpenAI() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "gm", openai: "oa"))
        let resolved = try APIKeyResolver.resolveIntentJudgeContext(
            config: config,
            preferredModel: nil,
            requiresVision: true
        )
        XCTAssertEqual(resolved.model, .gpt4oMini)
        XCTAssertEqual(resolved.apiKey, "oa")
    }

    func testResolveIntentJudgeContextRequiresVisionFallsBackToGemini() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "gm", openai: ""))
        let resolved = try APIKeyResolver.resolveIntentJudgeContext(
            config: config,
            preferredModel: nil,
            requiresVision: true
        )
        XCTAssertEqual(resolved.model, .gemini25FlashLite)
        XCTAssertEqual(resolved.apiKey, "gm")
    }
}
