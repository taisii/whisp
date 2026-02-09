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
            knownApps: ["Slack", "VSCode"],
            appPromptRules: [AppPromptRule(appName: "Slack", template: "入力: {STT結果}")],
            llmModel: .gpt5Nano,
            context: ContextConfig(accessibilityEnabled: false, visionEnabled: true),
            billing: BillingSettings(deepgramEnabled: true, deepgramProjectID: "project-123")
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
}
