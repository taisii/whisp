import Foundation
import XCTest
@testable import WhispCore

final class ConfigStoreTests: XCTestCase {
    private func tempFile(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    func testConfigRoundtrip() throws {
        let path = tempFile("config.json")
        let store = try ConfigStore(path: path)

        let config = Config(
            apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
            shortcut: "Option+Space",
            inputLanguage: "ja",
            recordingMode: .pushToTalk,
            sttProvider: .appleSpeech,
            appPromptRules: [AppPromptRule(appName: "Slack", template: "入力: {STT結果}")],
            llmModel: .gpt5Nano,
            context: ContextConfig(visionEnabled: true, visionMode: .ocr)
        )

        try store.save(config)
        let loaded = try store.load()
        XCTAssertEqual(loaded, config)
    }

    func testLoadOrCreateCreatesDefault() throws {
        let path = tempFile("config.json")
        let store = try ConfigStore(path: path)
        let config = try store.loadOrCreate()

        XCTAssertEqual(config, Config())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testLoadLegacyConfigDefaultsSTTProvider() throws {
        let path = tempFile("config.json")
        let json = """
        {
          "apiKeys" : {
            "deepgram" : "dg",
            "gemini" : "gm",
            "openai" : "oa"
          },
          "appPromptRules" : [],
          "inputLanguage" : "ja",
          "llmModel" : "gpt-5-nano",
          "recordingMode" : "toggle",
          "shortcut" : "Cmd+J"
        }
        """
        guard let data = json.data(using: .utf8) else {
            XCTFail("JSON文字列のエンコードに失敗")
            return
        }
        try data.write(to: path)

        let store = try ConfigStore(path: path)
        let loaded = try store.load()

        XCTAssertEqual(loaded.sttProvider, .deepgram)
        XCTAssertEqual(loaded.context.visionMode, .llm)
    }

    func testLoadContextWithoutVisionModeDefaultsLLM() throws {
        let path = tempFile("config.json")
        let json = """
        {
          "apiKeys" : {
            "deepgram" : "dg",
            "gemini" : "gm",
            "openai" : "oa"
          },
          "appPromptRules" : [],
          "context" : {
            "visionEnabled" : true
          },
          "inputLanguage" : "ja",
          "llmModel" : "gpt-5-nano",
          "recordingMode" : "toggle",
          "shortcut" : "Cmd+J",
          "sttProvider" : "deepgram"
        }
        """
        guard let data = json.data(using: .utf8) else {
            XCTFail("JSON文字列のエンコードに失敗")
            return
        }
        try data.write(to: path)

        let store = try ConfigStore(path: path)
        let loaded = try store.load()

        XCTAssertEqual(loaded.context.visionEnabled, true)
        XCTAssertEqual(loaded.context.visionMode, .llm)
    }
}
