import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import WhispCore
@testable import WhispApp

@MainActor
final class DebugViewSnapshotTests: XCTestCase {
    func testDebugViewSnapshotMatchesBaseline() throws {
        let source = try makeSampleSource()

        let viewModel = DebugViewModel(store: source.store)
        viewModel.refresh()
        viewModel.select(captureID: source.captureID)

        let actualBitmap = try renderSnapshot(viewModel: viewModel)
        let baselineURL = fixtureURL(fileName: "debug_view_snapshot_baseline.png")
        let baselineBitmap = try loadBitmap(at: baselineURL)

        XCTAssertEqual(actualBitmap.pixelsWide, baselineBitmap.pixelsWide)
        XCTAssertEqual(actualBitmap.pixelsHigh, baselineBitmap.pixelsHigh)

        let diff = try compare(
            actual: try cgImage(from: actualBitmap),
            baseline: try cgImage(from: baselineBitmap),
            channelTolerance: 2
        )

        let allowedRatio = 0.0005
        if diff.ratio > allowedRatio {
            let ratioText = String(format: "%.6f", diff.ratio)
            let artifactDir = try makeArtifactDirectory()
            let actualURL = artifactDir.appendingPathComponent("debug_view_snapshot_actual.png")
            let diffURL = artifactDir.appendingPathComponent("debug_view_snapshot_diff.png")
            try pngData(from: actualBitmap).write(to: actualURL, options: .atomic)
            if let diffPNGData = diff.diffPNGData {
                try diffPNGData.write(to: diffURL, options: .atomic)
            }

            XCTFail(
                "DebugView snapshot mismatch: changed=\(diff.changedPixels)/\(diff.totalPixels) " +
                    "(ratio=\(ratioText), allowed=\(allowedRatio)). " +
                    "actual=\(actualURL.path), diff=\(diffURL.path)"
            )
        }
    }

    private struct SnapshotSource {
        let store: DebugCaptureStore
        let captureID: String
    }

    private struct SnapshotDiff {
        let changedPixels: Int
        let totalPixels: Int
        let ratio: Double
        let diffPNGData: Data?
    }

    private func renderSnapshot(viewModel: DebugViewModel) throws -> NSBitmapImageRep {
        let root = DebugView(viewModel: viewModel)
            .frame(width: 1200, height: 1700)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 1200, height: 1700)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw AppError.io("failed to create bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private func fixtureURL(fileName: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(fileName)
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

    private func loadBitmap(at url: URL) throws -> NSBitmapImageRep {
        let data = try Data(contentsOf: url)
        guard let bitmap = NSBitmapImageRep(data: data) else {
            throw AppError.io("failed to decode baseline image: \(url.path)")
        }
        return bitmap
    }

    private func cgImage(from bitmap: NSBitmapImageRep) throws -> CGImage {
        guard let image = bitmap.cgImage else {
            throw AppError.io("failed to create cgImage")
        }
        return image
    }

    private func pngData(from bitmap: NSBitmapImageRep) throws -> Data {
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.io("failed to encode png")
        }
        return png
    }

    private func compare(actual: CGImage, baseline: CGImage, channelTolerance: UInt8) throws -> SnapshotDiff {
        let actualRGBA = try rgbaBytes(from: actual)
        let baselineRGBA = try rgbaBytes(from: baseline)

        guard actualRGBA.width == baselineRGBA.width, actualRGBA.height == baselineRGBA.height else {
            throw AppError.io("snapshot size mismatch")
        }

        let totalPixels = actualRGBA.width * actualRGBA.height
        var changedPixels = 0
        var diffBytes = [UInt8](repeating: 0, count: totalPixels * 4)

        for idx in stride(from: 0, to: actualRGBA.data.count, by: 4) {
            let dr = abs(Int(actualRGBA.data[idx]) - Int(baselineRGBA.data[idx]))
            let dg = abs(Int(actualRGBA.data[idx + 1]) - Int(baselineRGBA.data[idx + 1]))
            let db = abs(Int(actualRGBA.data[idx + 2]) - Int(baselineRGBA.data[idx + 2]))
            let da = abs(Int(actualRGBA.data[idx + 3]) - Int(baselineRGBA.data[idx + 3]))
            let maxDiff = max(dr, dg, db, da)

            if maxDiff > Int(channelTolerance) {
                changedPixels += 1
                diffBytes[idx] = 255
                diffBytes[idx + 1] = 0
                diffBytes[idx + 2] = 0
                diffBytes[idx + 3] = 180
            }
        }

        let ratio = totalPixels == 0 ? 0 : Double(changedPixels) / Double(totalPixels)
        let diffPNGData: Data?
        if changedPixels > 0 {
            let diffCG = try cgImage(fromRGBA: diffBytes, width: actualRGBA.width, height: actualRGBA.height)
            let diffRep = NSBitmapImageRep(cgImage: diffCG)
            diffPNGData = diffRep.representation(using: .png, properties: [:])
        } else {
            diffPNGData = nil
        }

        return SnapshotDiff(
            changedPixels: changedPixels,
            totalPixels: totalPixels,
            ratio: ratio,
            diffPNGData: diffPNGData
        )
    }

    private func rgbaBytes(from image: CGImage) throws -> (data: [UInt8], width: Int, height: Int) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AppError.io("failed to create bitmap context")
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    private func cgImage(fromRGBA bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let bytesPerRow = width * 4
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw AppError.io("failed to create diff data provider")
        }

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw AppError.io("failed to create diff cgImage")
        }

        return image
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

        return SnapshotSource(store: store, captureID: captureID)
    }
}
