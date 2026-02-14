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
            sttPreset: .appleSpeechRecognizerStream,
            appPromptRules: [AppPromptRule(appName: "Slack", template: "入力: {STT結果}")],
            llmModel: .gpt5Nano,
            context: ContextConfig(visionEnabled: true, visionMode: .ocr),
            generationPrimary: GenerationPrimarySelection(
                candidateID: "generation-gpt-5-nano-default",
                snapshot: GenerationPrimarySnapshot(
                    model: .gpt5Nano,
                    promptName: "default",
                    promptTemplate: "入力: {STT結果}",
                    promptHash: promptTemplateHash("入力: {STT結果}"),
                    options: [
                        "require_context": "true",
                        "use_cache": "true",
                    ],
                    capturedAt: "2026-02-14T00:00:00.000Z"
                ),
                selectedAt: "2026-02-14T00:00:00.000Z"
            )
        )

        try store.save(config)
        let loaded = try store.load()
        XCTAssertEqual(loaded, config)
    }

    func testEnsureExistsCreatesDefaultWhenMissing() throws {
        let path = tempFile("config.json")
        let store = try ConfigStore(path: path)
        try store.ensureExists(default: Config())
        let loaded = try store.load()

        XCTAssertEqual(loaded, Config())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testLossyDecodeUsesDefaultForMissingSTTPreset() throws {
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
        XCTAssertEqual(loaded.apiKeys.deepgram, "dg")
        XCTAssertEqual(loaded.apiKeys.gemini, "gm")
        XCTAssertEqual(loaded.apiKeys.openai, "oa")
        XCTAssertEqual(loaded.shortcut, "Cmd+J")
        XCTAssertEqual(loaded.inputLanguage, "ja")
        XCTAssertEqual(loaded.recordingMode, .toggle)
        XCTAssertEqual(loaded.llmModel, .gpt5Nano)
        XCTAssertEqual(loaded.sttPreset, .deepgramStream)
        XCTAssertEqual(loaded.context, ContextConfig())
    }

    func testLossyDecodeKeepsContextFieldAndFallsBackInvalidVisionMode() throws {
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
            "visionEnabled" : false,
            "visionMode" : "invalid_mode"
          },
          "inputLanguage" : "ja",
          "llmModel" : "gpt-5-nano",
          "recordingMode" : "toggle",
          "shortcut" : "Cmd+J",
          "sttPreset" : "deepgram_stream"
        }
        """
        guard let data = json.data(using: .utf8) else {
            XCTFail("JSON文字列のエンコードに失敗")
            return
        }
        try data.write(to: path)

        let store = try ConfigStore(path: path)
        let loaded = try store.load()
        XCTAssertEqual(loaded.context.visionEnabled, false)
        XCTAssertEqual(loaded.context.visionMode, .saveOnly)
    }

    func testLossyDecodeKeepsValidSTTSegmentationValues() throws {
        let path = tempFile("config.json")
        let json = """
        {
          "apiKeys" : {},
          "appPromptRules" : [],
          "context" : {
            "visionEnabled" : true,
            "visionMode" : "ocr"
          },
          "inputLanguage" : "ja",
          "llmModel" : "gpt-5-nano",
          "recordingMode" : "toggle",
          "shortcut" : "Cmd+J",
          "sttPreset" : "deepgram_stream",
          "sttSegmentation" : {
            "silenceMs" : "oops",
            "maxSegmentMs" : 11000,
            "preRollMs" : 150,
            "livePreviewEnabled" : true
          }
        }
        """
        guard let data = json.data(using: .utf8) else {
            XCTFail("JSON文字列のエンコードに失敗")
            return
        }
        try data.write(to: path)

        let store = try ConfigStore(path: path)
        let loaded = try store.load()
        XCTAssertEqual(loaded.sttSegmentation.silenceMs, 700)
        XCTAssertEqual(loaded.sttSegmentation.maxSegmentMs, 11_000)
        XCTAssertEqual(loaded.sttSegmentation.preRollMs, 150)
        XCTAssertEqual(loaded.sttSegmentation.livePreviewEnabled, true)
    }
}
