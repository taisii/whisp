import Foundation
import XCTest
@testable import WhispCore

final class UsageStoreTests: XCTestCase {
    private func tempFile(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    func testRecordSTTUsage() throws {
        let store = try UsageStore(path: tempFile("usage.json"))
        store.recordUsage(stt: STTUsage(durationSeconds: 10.5, requestID: nil), llm: nil)

        let today = store.today()
        XCTAssertEqual(today.deepgramSeconds, 10.5, accuracy: 0.001)
        XCTAssertEqual(today.deepgramRequests, 1)
    }

    func testRecordLLMUsageGemini() throws {
        let store = try UsageStore(path: tempFile("usage.json"))
        store.recordUsage(stt: nil, llm: LLMUsage(model: "gemini-2.5-flash-lite", promptTokens: 100, completionTokens: 50))

        let today = store.today()
        XCTAssertEqual(today.geminiPromptTokens, 100)
        XCTAssertEqual(today.geminiCompletionTokens, 50)
        XCTAssertEqual(today.geminiRequests, 1)
        XCTAssertEqual(today.openaiRequests, 0)
    }

    func testRecordLLMUsageOpenAI() throws {
        let store = try UsageStore(path: tempFile("usage.json"))
        store.recordUsage(stt: nil, llm: LLMUsage(model: "gpt-4o-mini", promptTokens: 200, completionTokens: 100))

        let today = store.today()
        XCTAssertEqual(today.openaiPromptTokens, 200)
        XCTAssertEqual(today.openaiCompletionTokens, 100)
        XCTAssertEqual(today.openaiRequests, 1)
        XCTAssertEqual(today.geminiRequests, 0)
    }

    func testRecordBothSTTAndLLM() throws {
        let store = try UsageStore(path: tempFile("usage.json"))
        store.recordUsage(
            stt: STTUsage(durationSeconds: 5.0, requestID: nil),
            llm: LLMUsage(model: "gemini-2.5-flash-lite", promptTokens: 50, completionTokens: 25)
        )

        let today = store.today()
        XCTAssertEqual(today.deepgramSeconds, 5.0, accuracy: 0.001)
        XCTAssertEqual(today.deepgramRequests, 1)
        XCTAssertEqual(today.geminiPromptTokens, 50)
        XCTAssertEqual(today.geminiCompletionTokens, 25)
        XCTAssertEqual(today.geminiRequests, 1)
    }

    func testMultipleRecordsAccumulate() throws {
        let store = try UsageStore(path: tempFile("usage.json"))
        store.recordUsage(stt: STTUsage(durationSeconds: 10.0, requestID: nil), llm: nil)
        store.recordUsage(stt: STTUsage(durationSeconds: 5.0, requestID: nil), llm: nil)

        let today = store.today()
        XCTAssertEqual(today.deepgramSeconds, 15.0, accuracy: 0.001)
        XCTAssertEqual(today.deepgramRequests, 2)
    }
}
