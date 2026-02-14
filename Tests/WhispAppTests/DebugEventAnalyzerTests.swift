import XCTest
import WhispCore
@testable import WhispApp

final class DebugEventAnalyzerTests: XCTestCase {
    func testAnalyzeResolvesSTTProviderAndRouteFromStructuredLog() {
        let analyzer = DebugEventAnalyzer()
        let logs: [DebugRunLog] = [
            makeRecordingLog(start: 1000, end: 2000),
            .stt(DebugSTTLog(
                base: base(type: .stt, start: 2000, end: 2120),
                provider: STTPresetID.chatgptWhisperStream.rawValue,
                transport: .websocket,
                route: .streaming,
                source: "openai_realtime_stream",
                textChars: 16,
                sampleRate: 16_000,
                audioBytes: 40_000,
                attempts: [
                    DebugSTTAttempt(
                        kind: .streamFinalize,
                        status: .ok,
                        eventStartMs: 2000,
                        eventEndMs: 2120,
                        source: "openai_realtime_stream",
                        textChars: 16,
                        sampleRate: 16_000,
                        audioBytes: 40_000
                    ),
                ]
            )),
            .postprocess(DebugPostProcessLog(
                base: base(type: .postprocess, start: 2125, end: 2210),
                model: "gpt-5-nano",
                contextPresent: true,
                sttChars: 16,
                outputChars: 14,
                kind: .textPostprocess
            )),
            .directInput(DebugDirectInputLog(
                base: base(type: .directInput, start: 2210, end: 2220),
                success: true,
                outputChars: 14
            )),
            .pipeline(DebugPipelineLog(
                base: base(type: .pipeline, start: 2000, end: 2250),
                sttChars: 16,
                outputChars: 14,
                error: nil
            )),
        ]

        let analysis = analyzer.analyze(logs: logs)

        XCTAssertEqual(analysis.sttInfo.providerName, "ChatGPT Whisper (Streaming)")
        XCTAssertEqual(analysis.sttInfo.routeName, "Streaming")
        XCTAssertEqual(analysis.timings.recordingMs ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(analysis.timings.sttMs ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(analysis.timings.postProcessMs ?? 0, 85, accuracy: 0.001)
        XCTAssertEqual(analysis.timings.directInputMs ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(analysis.timings.pipelineMs ?? 0, 250, accuracy: 0.001)
        XCTAssertEqual(analysis.timings.endToEndMs ?? 0, 1250, accuracy: 0.001)
    }

    func testAnalyzePrefersContextSummaryTimelineWhenPresent() {
        let analyzer = DebugEventAnalyzer()
        let logs: [DebugRunLog] = [
            .contextSummary(DebugContextSummaryLog(
                base: base(type: .contextSummary, start: 5000, end: 5180),
                source: "accessibility",
                appName: "Xcode",
                sourceChars: 200,
                summaryChars: 80,
                termsCount: 5,
                error: nil
            )),
            .vision(DebugVisionLog(
                base: base(type: .vision, start: 6000, end: 6220),
                model: "gpt-5-nano",
                mode: "ocr",
                contextPresent: true,
                imageBytes: 100,
                imageWidth: 100,
                imageHeight: 80,
                error: nil
            )),
            .pipeline(DebugPipelineLog(
                base: base(type: .pipeline, start: 5000, end: 5300),
                sttChars: 0,
                outputChars: 0,
                error: nil
            )),
        ]

        let analysis = analyzer.analyze(logs: logs)

        XCTAssertEqual(analysis.timings.visionTotalMs ?? 0, 180, accuracy: 0.001)
        XCTAssertTrue(analysis.timeline.phases.contains { $0.id == "context_summary" })
        XCTAssertFalse(analysis.timeline.phases.contains { $0.id == "vision" })
    }

    private func makeRecordingLog(start: Int64, end: Int64) -> DebugRunLog {
        .recording(DebugRecordingLog(
            base: base(type: .recording, start: start, end: end),
            mode: "toggle",
            model: "gpt-5-nano",
            sttProvider: STTPresetID.chatgptWhisperStream.rawValue,
            sttStreaming: false,
            visionEnabled: true,
            accessibilitySummaryStarted: true,
            sampleRate: 16_000,
            pcmBytes: 40_000
        ))
    }

    private func base(type: DebugLogType, start: Int64, end: Int64) -> DebugRunLogBase {
        DebugRunLogBase(
            runID: "run-1",
            captureID: "cap-1",
            logType: type,
            eventStartMs: start,
            eventEndMs: end,
            recordedAtMs: end + 1,
            status: .ok
        )
    }
}
