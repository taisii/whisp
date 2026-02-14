import Foundation
import XCTest
@testable import WhispCore

final class DebugCaptureStoreTests: XCTestCase {
    private struct ManualCaseLine: Decodable {
        struct Labels: Decodable {
            let transcriptGold: String

            enum CodingKeys: String, CodingKey {
                case transcriptGold = "transcript_gold"
            }
        }

        let id: String
        let groundTruthText: String
        let llmModel: String
        let audioDurationSec: Double?
        let audioFile: String
        let visionImageFile: String?
        let labels: Labels?
        let context: ContextInfo?

        enum CodingKeys: String, CodingKey {
            case id
            case groundTruthText = "ground_truth_text"
            case llmModel = "llm_model"
            case audioDurationSec = "audio_duration_sec"
            case audioFile = "audio_file"
            case visionImageFile = "vision_image_file"
            case labels
            case context
        }
    }

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
            status: "completed"
        )
        try store.setGroundTruth(captureID: captureID, text: "  これは正解です  ")
        try store.setSTTGroundTruth(captureID: captureID, text: "  これはSTT正解です  ")

        let records = try store.listRecords(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, captureID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: records.first?.audioFilePath ?? ""))

        let details = try XCTUnwrap(store.loadDetails(captureID: captureID))
        XCTAssertEqual(details.record.schemaVersion, 2)
        XCTAssertEqual(details.record.status, "completed")
        XCTAssertEqual(details.record.sttText, "これはsttです")
        XCTAssertEqual(details.record.outputText, "これは整形結果です")
        XCTAssertEqual(details.record.groundTruthText, "これは正解です")
        XCTAssertEqual(details.record.sttGroundTruthText, "これはSTT正解です")
        XCTAssertTrue(FileManager.default.fileExists(atPath: details.record.eventsFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: details.record.runDirectoryPath))
    }

    func testReserveRunThenSaveRecordingReusesSameCaptureID() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let captureID = try store.reserveRun(
            runID: "run-reserved",
            llmModel: "gpt-5-nano",
            appName: "Xcode"
        )

        let reserved = try XCTUnwrap(store.loadDetails(captureID: captureID))
        XCTAssertEqual(reserved.record.status, "recording")
        XCTAssertEqual(reserved.record.sampleRate, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reserved.record.eventsFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reserved.record.promptsDirectoryPath))

        let finalizedCaptureID = try store.saveRecording(
            runID: "run-reserved",
            sampleRate: 16_000,
            pcmData: Data(repeating: 7, count: 640),
            llmModel: "gpt-5-nano",
            appName: "Xcode",
            captureID: captureID
        )
        XCTAssertEqual(finalizedCaptureID, captureID)

        let finalized = try XCTUnwrap(store.loadDetails(captureID: captureID))
        XCTAssertEqual(finalized.record.status, "recorded")
        XCTAssertEqual(finalized.record.sampleRate, 16_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalized.record.audioFilePath))
    }

    func testAppendLogWritesStructuredJSONL() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let captureID = try store.saveRecording(
            runID: "run-log",
            sampleRate: 16_000,
            pcmData: Data(repeating: 0, count: 640),
            llmModel: "gpt-5-nano",
            appName: "Xcode"
        )

        let log = DebugRunLog.pipeline(DebugPipelineLog(
            base: DebugRunLogBase(
                runID: "run-log",
                captureID: captureID,
                logType: .pipeline,
                eventStartMs: 1_000,
                eventEndMs: 1_280,
                recordedAtMs: 1_300,
                status: .ok
            ),
            sttChars: 20,
            outputChars: 18,
            error: nil
        ))
        try store.appendLog(captureID: captureID, log: log)

        let details = try XCTUnwrap(store.loadDetails(captureID: captureID))
        let text = try String(contentsOfFile: details.record.eventsFilePath, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 1)

        let data = try XCTUnwrap(lines.first?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(DebugRunLog.self, from: data)
        XCTAssertEqual(decoded, log)
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

        let runDirectory = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(captureID, isDirectory: true)
        let promptsDir = runDirectory.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)

        let traceDir = promptsDir.appendingPathComponent("sample-trace", isDirectory: true)
        try FileManager.default.createDirectory(at: traceDir, withIntermediateDirectories: true)
        try "PROMPT BODY".write(
            to: traceDir.appendingPathComponent("request.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "RESPONSE BODY".write(
            to: traceDir.appendingPathComponent("response.txt"),
            atomically: true,
            encoding: .utf8
        )

        let metaURL = traceDir.appendingPathComponent("request.json")
        let trace = PromptTraceRequestRecord(
            traceID: "sample-trace",
            timestamp: "2026-02-09T00:00:00Z",
            stage: "postprocess",
            model: "gpt-5-nano",
            appName: nil,
            context: ContextInfo(visionSummary: "summary", visionTerms: ["term1", "term2"]),
            requestChars: 11,
            extra: [:]
        )
        try JSONEncoder().encode(trace).write(to: metaURL)

        let details = try XCTUnwrap(store.loadDetails(captureID: captureID))
        XCTAssertEqual(details.prompts.count, 1)
        XCTAssertEqual(details.prompts.first?.promptText, "PROMPT BODY")
        XCTAssertEqual(details.prompts.first?.responseText, "RESPONSE BODY")
        XCTAssertEqual(details.prompts.first?.contextTermsCount, 2)
        XCTAssertEqual(details.prompts.first?.context?.visionSummary, "summary")
    }

    func testUpdateContextPersistsAndIsNotClearedByNilVisionContext() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let captureID = try store.saveRecording(
            runID: "run-context",
            sampleRate: 16_000,
            pcmData: Data(repeating: 3, count: 640),
            llmModel: "gpt-5-nano",
            appName: "Codex"
        )

        let expected = ContextInfo(
            accessibilityText: "selected text",
            windowText: "window body",
            visionSummary: "summary",
            visionTerms: ["termA", "termB"]
        )
        try store.updateContext(captureID: captureID, context: expected)
        try store.saveVisionArtifacts(
            captureID: captureID,
            context: nil,
            imageData: Data([0xFF, 0xD8, 0xFF]),
            imageMimeType: "image/jpeg"
        )

        let details = try XCTUnwrap(store.loadDetails(captureID: captureID))
        XCTAssertEqual(details.record.context, expected)
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
        try store.updateResult(captureID: captureID, sttText: "stt", outputText: "out", status: "completed")
        try store.setGroundTruth(captureID: captureID, text: "正解")
        try store.setSTTGroundTruth(captureID: captureID, text: "stt正解")
        try store.saveVisionArtifacts(
            captureID: captureID,
            context: ContextInfo(visionSummary: "editor", visionTerms: ["Swift"]),
            imageData: Data([0xFF, 0xD8, 0xFF]),
            imageMimeType: "image/jpeg"
        )

        let path = try store.appendManualTestCase(captureID: captureID)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        guard let line = content.components(separatedBy: .newlines).first(where: { !$0.isEmpty }),
              let data = line.data(using: .utf8)
        else {
            return XCTFail("manual case JSONL parse failed")
        }
        let payload = try JSONDecoder().decode(ManualCaseLine.self, from: data)

        XCTAssertEqual(payload.id, captureID)
        XCTAssertEqual(payload.groundTruthText, "正解")
        XCTAssertEqual(payload.llmModel, "gemini-2.5-flash-lite")
        XCTAssertTrue(payload.audioFile.contains("/manual_case_assets/\(captureID)/audio."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.audioFile))
        let visionImageFile = try XCTUnwrap(payload.visionImageFile)
        XCTAssertTrue(visionImageFile.contains("/manual_case_assets/\(captureID)/vision."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: visionImageFile))
        XCTAssertEqual(payload.labels?.transcriptGold, "stt正解")
        XCTAssertEqual(payload.context?.visionSummary, "editor")
    }

    func testAppendManualTestCaseRejectsDuplicateID() throws {
        let home = tempHome()
        let store = makeStore(home: home)
        let captureID = try store.saveRecording(
            runID: "run-manual-duplicate",
            sampleRate: 16_000,
            pcmData: Data(repeating: 3, count: 640),
            llmModel: "gemini-2.5-flash-lite",
            appName: "Codex"
        )

        let path = try store.appendManualTestCase(captureID: captureID)
        XCTAssertThrowsError(try store.appendManualTestCase(captureID: captureID)) { error in
            guard case AppError.invalidArgument(let message) = error else {
                return XCTFail("expected invalidArgument, got: \(error)")
            }
            XCTAssertTrue(message.contains("既に追加済み"))
            XCTAssertTrue(message.contains(captureID))
        }

        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        XCTAssertEqual(lines.count, 1)
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: detailsBeforeDelete.record.runDirectoryPath))

        try store.deleteCapture(captureID: captureID)

        XCTAssertNil(try store.loadDetails(captureID: captureID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: detailsBeforeDelete.record.audioFilePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: detailsBeforeDelete.record.visionImageFilePath ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: detailsBeforeDelete.record.runDirectoryPath))
        XCTAssertTrue(try store.listRecords(limit: 10).isEmpty)
    }

}
