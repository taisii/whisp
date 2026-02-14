import XCTest
@testable import WhispCore

final class LLMModelCatalogTests: XCTestCase {
    func testSelectableModelsFollowSurfaceConstraints() {
        let appSettings = Set(LLMModelCatalog.selectableModelIDs(for: .appSettings))
        XCTAssertTrue(appSettings.contains(.gemini25FlashLiteAudio))
        XCTAssertFalse(appSettings.contains(.kimiK25))

        let cliJudge = Set(LLMModelCatalog.selectableModelIDs(for: .cliJudge))
        XCTAssertTrue(cliJudge.contains(.gpt4oMini))
        XCTAssertTrue(cliJudge.contains(.kimiK25))
        XCTAssertFalse(cliJudge.contains(.gpt5Nano))
    }

    func testResolveOrFallbackUsesDefaultForMissingOrUnsupportedModel() {
        let unknown = LLMModelID(uncheckedRawValue: "not-registered-model")
        XCTAssertEqual(
            LLMModelCatalog.resolveOrFallback(unknown, for: .pipelineExecution),
            LLMModelCatalog.defaultModel(for: .pipelineExecution)
        )
        XCTAssertEqual(
            LLMModelCatalog.resolveOrFallback(.gpt5Nano, for: .cliJudge),
            LLMModelCatalog.defaultModel(for: .cliJudge)
        )
    }

    func testResolveRegisteredRejectsUnknownID() {
        XCTAssertEqual(LLMModelCatalog.resolveRegistered(rawValue: "gpt-4o-mini"), .gpt4oMini)
        XCTAssertNil(LLMModelCatalog.resolveRegistered(rawValue: "unknown"))
    }
}
