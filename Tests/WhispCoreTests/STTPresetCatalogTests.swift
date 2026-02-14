import XCTest
@testable import WhispCore

final class STTPresetCatalogTests: XCTestCase {
    func testTargetInputSampleRateUses24kForOpenAIStreamingPreset() {
        XCTAssertEqual(
            STTPresetCatalog.targetInputSampleRate(for: .chatgptWhisperStream),
            24_000
        )
    }

    func testTargetInputSampleRateUses16kForDeepgramPresets() {
        XCTAssertEqual(STTPresetCatalog.targetInputSampleRate(for: .deepgramStream), 16_000)
        XCTAssertEqual(STTPresetCatalog.targetInputSampleRate(for: .deepgramRest), 16_000)
    }

    func testTargetInputSampleRateUses16kForAppleSpeechPresets() {
        XCTAssertEqual(STTPresetCatalog.targetInputSampleRate(for: .appleSpeechRecognizerStream), 16_000)
        XCTAssertEqual(STTPresetCatalog.targetInputSampleRate(for: .appleSpeechRecognizerRest), 16_000)
    }
}
