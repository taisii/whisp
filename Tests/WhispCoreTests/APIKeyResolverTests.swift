import XCTest
@testable import WhispCore

final class APIKeyResolverTests: XCTestCase {
    func testResolvesSTTCredentialByProvider() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa", moonshot: "ms"))
        XCTAssertEqual(try APIKeyResolver.sttCredential(config: config, provider: .deepgram), .apiKey("dg"))
        XCTAssertEqual(try APIKeyResolver.sttCredential(config: config, provider: .whisper), .apiKey("oa"))
        XCTAssertEqual(try APIKeyResolver.sttCredential(config: config, provider: .appleSpeech), .none)
    }

    func testResolvesLLMKeyByModel() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa", moonshot: "ms"))
        XCTAssertEqual(try APIKeyResolver.llmKey(config: config, model: .gemini25FlashLite), "gm")
        XCTAssertEqual(try APIKeyResolver.llmKey(config: config, model: .gpt5Nano), "oa")
        XCTAssertEqual(try APIKeyResolver.llmKey(config: config, model: .kimiK25), "ms")
    }

    func testEffectivePostProcessModelMapsAudioModel() {
        XCTAssertEqual(APIKeyResolver.effectivePostProcessModel(.gemini25FlashLiteAudio), .gemini25FlashLite)
        XCTAssertEqual(APIKeyResolver.effectivePostProcessModel(.gpt4oMini), .gpt4oMini)
    }

    func testResolveIntentJudgeContextPrefersExplicitModel() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "gm", openai: "oa", moonshot: "ms"))
        let resolved = try APIKeyResolver.resolveIntentJudgeContext(config: config, preferredModel: .gemini25FlashLiteAudio)
        XCTAssertEqual(resolved.model, .gemini25FlashLite)
        XCTAssertEqual(resolved.apiKey, "gm")
    }

    func testResolveIntentJudgeContextRequiresVisionRejectsUnsupportedModel() {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "gm", openai: "oa", moonshot: "ms"))
        XCTAssertThrowsError(
            try APIKeyResolver.resolveIntentJudgeContext(
                config: config,
                preferredModel: .gpt5Nano,
                requiresVision: true
            )
        )
    }

    func testResolveIntentJudgeContextRequiresVisionRejectsGeminiAudioModel() {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "gm", openai: "oa", moonshot: "ms"))
        XCTAssertThrowsError(
            try APIKeyResolver.resolveIntentJudgeContext(
                config: config,
                preferredModel: .gemini25FlashLiteAudio,
                requiresVision: true
            )
        )
    }

    func testResolveIntentJudgeContextRequiresVisionAutoSelectsFirstSelectableModel() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "gm", openai: "oa", moonshot: "ms"))
        let resolved = try APIKeyResolver.resolveIntentJudgeContext(
            config: config,
            preferredModel: nil,
            requiresVision: true
        )
        XCTAssertEqual(resolved.model, .gemini3FlashPreview)
        XCTAssertEqual(resolved.apiKey, "gm")
    }

    func testResolveIntentJudgeContextRequiresVisionFallsBackToGemini() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "gm", openai: "", moonshot: ""))
        let resolved = try APIKeyResolver.resolveIntentJudgeContext(
            config: config,
            preferredModel: nil,
            requiresVision: true
        )
        XCTAssertEqual(resolved.model, .gemini3FlashPreview)
        XCTAssertEqual(resolved.apiKey, "gm")
    }

    func testResolveIntentJudgeContextRequiresVisionFallsBackToKimiWhenGeminiOpenAIMissing() throws {
        let config = Config(apiKeys: APIKeys(deepgram: "", gemini: "", openai: "", moonshot: "ms"))
        let resolved = try APIKeyResolver.resolveIntentJudgeContext(
            config: config,
            preferredModel: nil,
            requiresVision: true
        )
        XCTAssertEqual(resolved.model, .kimiK25)
        XCTAssertEqual(resolved.apiKey, "ms")
    }
}
