import XCTest
@testable import WhispCore

final class GeminiArgsTests: XCTestCase {
    func testUsesEnvKeyWithSingleAudioArg() throws {
        let parsed = try parseGeminiArguments(args: ["audio.wav"], envAPIKey: "ENV_KEY")
        XCTAssertEqual(parsed.apiKey, "ENV_KEY")
        XCTAssertEqual(parsed.audioPath, "audio.wav")
    }

    func testUsesCLIKeyWhenNoEnvKey() throws {
        let parsed = try parseGeminiArguments(args: ["CLI_KEY"], envAPIKey: nil)
        XCTAssertEqual(parsed.apiKey, "CLI_KEY")
        XCTAssertNil(parsed.audioPath)
    }

    func testUsesCLIKeyAndAudioWhenTwoArgs() throws {
        let parsed = try parseGeminiArguments(args: ["CLI_KEY", "audio.wav"], envAPIKey: "ENV_KEY")
        XCTAssertEqual(parsed.apiKey, "CLI_KEY")
        XCTAssertEqual(parsed.audioPath, "audio.wav")
    }

    func testRequiresEnvKeyWhenNoArgs() {
        XCTAssertThrowsError(try parseGeminiArguments(args: [], envAPIKey: nil)) { error in
            XCTAssertEqual(error as? AppError, .invalidArgument("GEMINI_API_KEYが必要です"))
        }
    }
}
