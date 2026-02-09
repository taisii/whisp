import Foundation
import XCTest
@testable import WhispCore

final class DebugCaptureStoreTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(home: URL) -> DebugCaptureStore {
        DebugCaptureStore(environment: ["HOME": home.path])
    }

    func testSaveUpdateAndGroundTruth() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let pcm = Data(repeating: 0, count: 16_000 * MemoryLayout<Int16>.size)

        let captureID = try store.saveRecording(
            runID: "run-001",
            sampleRate: 16_000,
            pcmData: pcm,
            llmModel: "gemini-2.5-flash-lite",
            appName: "Xcode"
        )
        try store.updateResult(
            captureID: captureID,
            sttText: "これはsttです",
            outputText: "これは整形結果です",
            status: "done"
        )
        try store.setGroundTruth(captureID: captureID, text: "  これは正解です  ")

        let records = try store.listRecords(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, captureID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: records.first?.audioFilePath ?? ""))

        let details = try XCTUnwrap(store.loadDetails(captureID: captureID))
        XCTAssertEqual(details.record.sttText, "これはsttです")
        XCTAssertEqual(details.record.outputText, "これは整形結果です")
        XCTAssertEqual(details.record.groundTruthText, "これは正解です")
    }

    func testLoadDetailsIncludesPromptTraceForSameRunID() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let captureID = try store.saveRecording(
            runID: "run-xyz",
            sampleRate: 16_000,
            pcmData: Data(repeating: 0, count: 320),
            llmModel: "gpt-5-nano",
            appName: nil
        )

        let promptsDir = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)

        let promptFile = "sample.prompt.txt"
        let promptURL = promptsDir.appendingPathComponent(promptFile)
        try "PROMPT BODY".write(to: promptURL, atomically: true, encoding: .utf8)

        let metaURL = promptsDir.appendingPathComponent("sample.meta.json")
        let trace = PromptTraceRecord(
            timestamp: "2026-02-09T00:00:00Z",
            stage: "postprocess",
            model: "gpt-5-nano",
            appName: nil,
            context: ContextInfo(visionSummary: "summary", visionTerms: ["term1", "term2"]),
            promptChars: 11,
            promptFile: promptFile,
            extra: ["run_id": "run-xyz"]
        )
        try JSONEncoder().encode(trace).write(to: metaURL)

        let details = try XCTUnwrap(store.loadDetails(captureID: captureID))
        XCTAssertEqual(details.prompts.count, 1)
        XCTAssertEqual(details.prompts.first?.promptText, "PROMPT BODY")
        XCTAssertEqual(details.prompts.first?.contextTermsCount, 2)
    }

    func testAppendManualTestCaseWritesJSONL() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let captureID = try store.saveRecording(
            runID: "run-manual",
            sampleRate: 16_000,
            pcmData: Data(repeating: 1, count: 640),
            llmModel: "gemini-2.5-flash-lite",
            appName: "Cursor"
        )
        try store.updateResult(captureID: captureID, sttText: "stt", outputText: "out", status: "done")
        try store.setGroundTruth(captureID: captureID, text: "正解")
        try store.saveVisionArtifacts(
            captureID: captureID,
            context: ContextInfo(visionSummary: "editor", visionTerms: ["Swift"]),
            imageData: Data([0xFF, 0xD8, 0xFF]),
            imageMimeType: "image/jpeg"
        )

        let path = try store.appendManualTestCase(captureID: captureID)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        guard let line = content.components(separatedBy: .newlines).first(where: { !$0.isEmpty }),
              let data = line.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return XCTFail("manual case JSONL parse failed")
        }

        XCTAssertEqual(json["id"] as? String, captureID)
        XCTAssertEqual(json["ground_truth_text"] as? String, "正解")
        XCTAssertEqual(json["llm_model"] as? String, "gemini-2.5-flash-lite")
        XCTAssertNotNil(json["vision_image_file"] as? String)
        let context = json["context"] as? [String: Any]
        XCTAssertEqual(context?["visionSummary"] as? String, "editor")
    }

    func testDeleteCaptureRemovesRecordAndAudio() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let captureID = try store.saveRecording(
            runID: "run-delete",
            sampleRate: 16_000,
            pcmData: Data(repeating: 2, count: 640),
            llmModel: "gpt-5-nano",
            appName: nil
        )
        try store.saveVisionArtifacts(
            captureID: captureID,
            context: ContextInfo(visionSummary: "screen", visionTerms: []),
            imageData: Data([0xFF, 0xD8, 0xFF]),
            imageMimeType: "image/jpeg"
        )

        let detailsBeforeDelete = try XCTUnwrap(store.loadDetails(captureID: captureID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: detailsBeforeDelete.record.audioFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: detailsBeforeDelete.record.visionImageFilePath ?? ""))

        try store.deleteCapture(captureID: captureID)

        XCTAssertNil(try store.loadDetails(captureID: captureID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: detailsBeforeDelete.record.audioFilePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: detailsBeforeDelete.record.visionImageFilePath ?? ""))
        XCTAssertTrue(try store.listRecords(limit: 10).isEmpty)
    }
}
