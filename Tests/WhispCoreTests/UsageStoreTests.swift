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
        store.recordUsage(
            stt: STTUsage(durationSeconds: 10.5, requestID: nil, provider: STTProvider.deepgram.rawValue),
            llm: nil
        )

        let today = store.today()
        XCTAssertEqual(today.stt[STTProvider.deepgram.rawValue]?.durationSeconds ?? 0, 10.5, accuracy: 0.001)
        XCTAssertEqual(today.stt[STTProvider.deepgram.rawValue]?.requests, 1)
    }

    func testRecordLLMUsageGemini() throws {
        let store = try UsageStore(path: tempFile("usage.json"))
        store.recordUsage(stt: nil, llm: LLMUsage(model: "gemini-2.5-flash-lite", promptTokens: 100, completionTokens: 50))

        let today = store.today()
        XCTAssertEqual(today.llm["gemini"]?.promptTokens, 100)
        XCTAssertEqual(today.llm["gemini"]?.completionTokens, 50)
        XCTAssertEqual(today.llm["gemini"]?.requests, 1)
        XCTAssertNil(today.llm["openai"])
    }

    func testRecordLLMUsageOpenAI() throws {
        let store = try UsageStore(path: tempFile("usage.json"))
        store.recordUsage(stt: nil, llm: LLMUsage(model: "gpt-4o-mini", promptTokens: 200, completionTokens: 100))

        let today = store.today()
        XCTAssertEqual(today.llm["openai"]?.promptTokens, 200)
        XCTAssertEqual(today.llm["openai"]?.completionTokens, 100)
        XCTAssertEqual(today.llm["openai"]?.requests, 1)
        XCTAssertNil(today.llm["gemini"])
    }

    func testRecordBothSTTAndLLM() throws {
        let store = try UsageStore(path: tempFile("usage.json"))
        store.recordUsage(
            stt: STTUsage(durationSeconds: 5.0, requestID: nil, provider: STTProvider.deepgram.rawValue),
            llm: LLMUsage(model: "gemini-2.5-flash-lite", promptTokens: 50, completionTokens: 25)
        )

        let today = store.today()
        XCTAssertEqual(today.stt[STTProvider.deepgram.rawValue]?.durationSeconds ?? 0, 5.0, accuracy: 0.001)
        XCTAssertEqual(today.stt[STTProvider.deepgram.rawValue]?.requests, 1)
        XCTAssertEqual(today.llm["gemini"]?.promptTokens, 50)
        XCTAssertEqual(today.llm["gemini"]?.completionTokens, 25)
        XCTAssertEqual(today.llm["gemini"]?.requests, 1)
    }

    func testMultipleRecordsAccumulate() throws {
        let store = try UsageStore(path: tempFile("usage.json"))
        store.recordUsage(
            stt: STTUsage(durationSeconds: 10.0, requestID: nil, provider: STTProvider.deepgram.rawValue),
            llm: nil
        )
        store.recordUsage(
            stt: STTUsage(durationSeconds: 5.0, requestID: nil, provider: STTProvider.deepgram.rawValue),
            llm: nil
        )

        let today = store.today()
        XCTAssertEqual(today.stt[STTProvider.deepgram.rawValue]?.durationSeconds ?? 0, 15.0, accuracy: 0.001)
        XCTAssertEqual(today.stt[STTProvider.deepgram.rawValue]?.requests, 2)
    }
}
