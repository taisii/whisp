import XCTest
@testable import WhispCore

final class GenerationPrimaryConfigTests: XCTestCase {
    func testResolveUsesSnapshotWhenSelectionIsValid() {
        var config = Config()
        config.llmModel = .gemini25FlashLite
        config.generationPrimary = GenerationPrimarySelection(
            candidateID: "generation-gpt-5-nano-default",
            snapshot: GenerationPrimarySnapshot(
                model: .gpt5Nano,
                promptName: "default",
                promptTemplate: "整形してください\n入力: {STT結果}",
                promptHash: promptTemplateHash("整形してください\n入力: {STT結果}"),
                options: ["require_context": "true"],
                capturedAt: "2026-02-14T00:00:00.000Z"
            ),
            selectedAt: "2026-02-14T00:00:00.000Z"
        )

        let resolved = GenerationPrimaryConfigResolver.resolve(config: config)
        XCTAssertEqual(resolved.model, .gpt5Nano)
        XCTAssertEqual(resolved.promptTemplateOverride, "整形してください\n入力: {STT結果}")
        XCTAssertTrue(resolved.requireContext)
        XCTAssertTrue(resolved.usesSelection)
    }

    func testResolveFallsBackWhenSnapshotModelIsUnknown() {
        var config = Config()
        config.llmModel = .gemini25FlashLite
        config.generationPrimary = GenerationPrimarySelection(
            candidateID: "generation-unknown",
            snapshot: GenerationPrimarySnapshot(
                model: LLMModel(uncheckedRawValue: "unknown-model"),
                promptName: "default",
                promptTemplate: "入力: {STT結果}",
                promptHash: promptTemplateHash("入力: {STT結果}"),
                options: ["require_context": "true"],
                capturedAt: "2026-02-14T00:00:00.000Z"
            ),
            selectedAt: "2026-02-14T00:00:00.000Z"
        )

        let resolved = GenerationPrimaryConfigResolver.resolve(config: config)
        XCTAssertEqual(resolved.model, .gemini25FlashLite)
        XCTAssertNil(resolved.promptTemplateOverride)
        XCTAssertFalse(resolved.requireContext)
        XCTAssertFalse(resolved.usesSelection)
    }

    func testResolveFallsBackWhenSnapshotPromptTemplateIsEmpty() {
        var config = Config()
        config.llmModel = .gpt4oMini
        config.generationPrimary = GenerationPrimarySelection(
            candidateID: "generation-gpt-4o-mini-empty",
            snapshot: GenerationPrimarySnapshot(
                model: .gpt4oMini,
                promptName: "empty",
                promptTemplate: "   ",
                promptHash: promptTemplateHash(""),
                options: ["require_context": "true"],
                capturedAt: "2026-02-14T00:00:00.000Z"
            ),
            selectedAt: "2026-02-14T00:00:00.000Z"
        )

        let resolved = GenerationPrimaryConfigResolver.resolve(config: config)
        XCTAssertEqual(resolved.model, .gpt4oMini)
        XCTAssertNil(resolved.promptTemplateOverride)
        XCTAssertFalse(resolved.requireContext)
        XCTAssertFalse(resolved.usesSelection)
    }

    func testSelectionFactoryBuildsCanonicalSnapshot() {
        let candidate = BenchmarkCandidate(
            id: "generation-gpt-5-nano-default",
            task: .generation,
            model: "gpt-5-nano",
            promptName: "default",
            generationPromptTemplate: "入力: {STT結果}\r\n",
            generationPromptHash: nil,
            options: ["require_context": "false"],
            createdAt: "2026-02-14T00:00:00.000Z",
            updatedAt: "2026-02-14T00:00:00.000Z"
        )

        let selection = GenerationPrimarySelectionFactory.makeSelection(
            candidate: candidate,
            selectedAt: "2026-02-14T10:00:00.000Z"
        )
        XCTAssertEqual(selection?.candidateID, candidate.id)
        XCTAssertEqual(selection?.snapshot.model, .gpt5Nano)
        XCTAssertEqual(selection?.snapshot.promptTemplate, "入力: {STT結果}")
        XCTAssertEqual(selection?.snapshot.promptHash, promptTemplateHash("入力: {STT結果}"))
        XCTAssertEqual(selection?.selectedAt, "2026-02-14T10:00:00.000Z")
    }
}
