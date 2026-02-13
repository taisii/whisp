import AppKit
import SwiftUI
import XCTest
import WhispCore
@testable import WhispApp

@MainActor
final class DebugViewSnapshotTests: XCTestCase {
    private let snapshotWidth = 1200
    private let snapshotHeight = 1700

    func testDebugViewSnapshotRenders() throws {
        let source = try makeSampleSource()

        let viewModel = DebugViewModel(store: source.store)
        viewModel.refresh()
        viewModel.select(captureID: source.captureID)

        let actualBitmap = try renderSnapshot(viewModel: viewModel)
        let artifactDir = try makeArtifactDirectory()
        let actualURL = artifactDir.appendingPathComponent("debug_view_snapshot_actual.png")
        try pngData(from: actualBitmap).write(to: actualURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: actualURL.path))
    }

    private struct SnapshotSource {
        let store: DebugCaptureStore
        let captureID: String
    }

    private func renderSnapshot(viewModel: DebugViewModel) throws -> NSBitmapImageRep {
        let root = DebugView(viewModel: viewModel)
            .frame(width: CGFloat(snapshotWidth), height: CGFloat(snapshotHeight))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: snapshotWidth, height: snapshotHeight)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw AppError.io("failed to create bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private func makeArtifactDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = root.appendingPathComponent(".build/snapshot-artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pngData(from bitmap: NSBitmapImageRep) throws -> Data {
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.io("failed to encode png")
        }
        return png
    }

    private func makeSampleSource() throws -> SnapshotSource {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = DebugCaptureStore(environment: ["HOME": home.path])

        let snapshot = AccessibilitySnapshot(
            capturedAt: "2026-02-11T00:00:00Z",
            trusted: true,
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            processID: 1234,
            windowTitle: "Debug.swift",
            windowText: "let value = 1",
            windowTextChars: 13,
            focusedElement: AccessibilityElementSnapshot(
                role: "AXTextArea",
                subrole: "AXStandardWindow",
                title: "Editor",
                elementDescription: "source editor",
                help: nil,
                placeholder: nil,
                value: "let value = 1",
                valueChars: 13,
                selectedText: "value",
                selectedRange: AccessibilityTextRange(location: 4, length: 5),
                insertionPointLineNumber: 1,
                labelTexts: ["Source Editor"],
                caretContext: "let value = 1",
                caretContextRange: AccessibilityTextRange(location: 0, length: 13)
            ),
            error: nil
        )

        let captureID = try store.saveRecording(
            runID: "run-snapshot",
            sampleRate: 16_000,
            pcmData: Data(repeating: 1, count: 3200),
            llmModel: "gpt-5-nano",
            appName: "Xcode",
            accessibilitySnapshot: snapshot
        )
        try store.updateResult(
            captureID: captureID,
            sttText: "これはテストです",
            outputText: "これは整形済みテキストです",
            status: "completed"
        )
        let details = try XCTUnwrap(store.loadDetails(captureID: captureID))
        let promptsDir = URL(fileURLWithPath: details.record.promptsDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        let traceDir = promptsDir.appendingPathComponent("sample-postprocess", isDirectory: true)
        try FileManager.default.createDirectory(at: traceDir, withIntermediateDirectories: true)
        try """
        音声を整えてください。

        入力: これはテストです
        """.write(
            to: traceDir.appendingPathComponent("request.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "これは整形済みテキストです".write(
            to: traceDir.appendingPathComponent("response.txt"),
            atomically: true,
            encoding: .utf8
        )
        let trace = PromptTraceRequestRecord(
            traceID: "sample-postprocess",
            timestamp: "2026-02-11T00:00:00Z",
            stage: "postprocess",
            model: "gpt-5-nano",
            appName: "Xcode",
            context: ContextInfo(visionSummary: "editor open", visionTerms: ["Swift", "Xcode"]),
            requestChars: 27,
            extra: [:]
        )
        try JSONEncoder().encode(trace).write(
            to: traceDir.appendingPathComponent("request.json"),
            options: .atomic
        )
        try store.saveVisionArtifacts(
            captureID: captureID,
            context: ContextInfo(visionSummary: "editor open", visionTerms: ["Swift", "Xcode"]),
            imageData: Data([0xFF, 0xD8, 0xFF]),
            imageMimeType: "image/jpeg"
        )

        let t0: Int64 = 1_730_000_000_000
        let logs: [DebugRunLog] = [
            .recording(DebugRecordingLog(
                base: DebugRunLogBase(
                    runID: "run-snapshot",
                    captureID: captureID,
                    logType: .recording,
                    eventStartMs: t0,
                    eventEndMs: t0 + 2000,
                    recordedAtMs: t0 + 2001,
                    status: .ok
                ),
                mode: "toggle",
                model: "gpt-5-nano",
                sttProvider: STTProvider.deepgram.rawValue,
                sttStreaming: true,
                visionEnabled: true,
                accessibilitySummaryStarted: true,
                sampleRate: 16_000,
                pcmBytes: 3200
            )),
            .contextSummary(DebugContextSummaryLog(
                base: DebugRunLogBase(
                    runID: "run-snapshot",
                    captureID: captureID,
                    logType: .contextSummary,
                    eventStartMs: t0 + 2000,
                    eventEndMs: t0 + 2300,
                    recordedAtMs: t0 + 2301,
                    status: .ok
                ),
                source: "accessibility",
                appName: "Xcode",
                sourceChars: 100,
                summaryChars: 24,
                termsCount: 2,
                error: nil
            )),
            .stt(DebugSTTLog(
                base: DebugRunLogBase(
                    runID: "run-snapshot",
                    captureID: captureID,
                    logType: .stt,
                    eventStartMs: t0 + 2000,
                    eventEndMs: t0 + 2450,
                    recordedAtMs: t0 + 2451,
                    status: .ok
                ),
                provider: STTProvider.deepgram.rawValue,
                route: .streamingFallbackREST,
                source: "rest_fallback",
                textChars: 8,
                sampleRate: 16_000,
                audioBytes: 3200,
                attempts: [
                    DebugSTTAttempt(
                        kind: .streamFinalize,
                        status: .error,
                        eventStartMs: t0 + 2000,
                        eventEndMs: t0 + 2210,
                        source: "stream_finalize",
                        error: "timeout"
                    ),
                    DebugSTTAttempt(
                        kind: .restFallback,
                        status: .ok,
                        eventStartMs: t0 + 2211,
                        eventEndMs: t0 + 2450,
                        source: "rest_fallback",
                        textChars: 8,
                        sampleRate: 16_000,
                        audioBytes: 3200
                    ),
                ]
            )),
            .postprocess(DebugPostProcessLog(
                base: DebugRunLogBase(
                    runID: "run-snapshot",
                    captureID: captureID,
                    logType: .postprocess,
                    eventStartMs: t0 + 2460,
                    eventEndMs: t0 + 2750,
                    recordedAtMs: t0 + 2751,
                    status: .ok
                ),
                model: "gpt-5-nano",
                contextPresent: true,
                sttChars: 8,
                outputChars: 14,
                kind: .textPostprocess
            )),
            .directInput(DebugDirectInputLog(
                base: DebugRunLogBase(
                    runID: "run-snapshot",
                    captureID: captureID,
                    logType: .directInput,
                    eventStartMs: t0 + 2760,
                    eventEndMs: t0 + 2780,
                    recordedAtMs: t0 + 2781,
                    status: .ok
                ),
                success: true,
                outputChars: 14
            )),
            .pipeline(DebugPipelineLog(
                base: DebugRunLogBase(
                    runID: "run-snapshot",
                    captureID: captureID,
                    logType: .pipeline,
                    eventStartMs: t0 + 2000,
                    eventEndMs: t0 + 2790,
                    recordedAtMs: t0 + 2791,
                    status: .ok
                ),
                sttChars: 8,
                outputChars: 14,
                error: nil
            )),
        ]
        for log in logs {
            try store.appendLog(captureID: captureID, log: log)
        }

        let failedCaptureID = try store.saveRecording(
            runID: "run-snapshot-failed",
            sampleRate: 16_000,
            pcmData: Data(repeating: 2, count: 1600),
            llmModel: "gpt-5-nano",
            appName: "Xcode",
            accessibilitySnapshot: snapshot
        )
        try store.updateResult(
            captureID: failedCaptureID,
            sttText: "失敗したSTT",
            outputText: nil,
            status: "failed",
            errorMessage: "network timeout"
        )

        let skippedCaptureID = try store.saveRecording(
            runID: "run-snapshot-skipped",
            sampleRate: 16_000,
            pcmData: Data(repeating: 3, count: 1600),
            llmModel: "gpt-5-nano",
            appName: "Xcode",
            accessibilitySnapshot: snapshot
        )
        try store.updateResult(
            captureID: skippedCaptureID,
            sttText: nil,
            outputText: nil,
            status: "skipped",
            skipReason: "empty_stt"
        )

        return SnapshotSource(store: store, captureID: captureID)
    }
}
