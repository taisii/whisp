import XCTest
@testable import WhispCore

final class DebugRunLogSchemaTests: XCTestCase {
    func testCriticalLogTypeNamesAreStable() {
        XCTAssertEqual(DebugLogType.recording.rawValue, "recording")
        XCTAssertEqual(DebugLogType.stt.rawValue, "stt")
        XCTAssertEqual(DebugLogType.vision.rawValue, "vision")
        XCTAssertEqual(DebugLogType.postprocess.rawValue, "postprocess")
        XCTAssertEqual(DebugLogType.directInput.rawValue, "direct_input")
        XCTAssertEqual(DebugLogType.pipeline.rawValue, "pipeline")
        XCTAssertEqual(DebugLogType.contextSummary.rawValue, "context_summary")
    }

    func testDebugRunLogRoundTrip() throws {
        let base = DebugRunLogBase(
            runID: "run-1",
            captureID: "cap-1",
            logType: .recording,
            eventStartMs: 1000,
            eventEndMs: 2000,
            recordedAtMs: 2100,
            status: .ok
        )

        let logs: [DebugRunLog] = [
            .recording(DebugRecordingLog(
                base: base,
                mode: "toggle",
                model: "gpt-5-nano",
                sttProvider: "deepgram",
                sttStreaming: true,
                visionEnabled: true,
                accessibilitySummaryStarted: false,
                sampleRate: 16000,
                pcmBytes: 32000
            )),
            .stt(DebugSTTLog(
                base: DebugRunLogBase(
                    runID: "run-1",
                    captureID: "cap-1",
                    logType: .stt,
                    eventStartMs: 2000,
                    eventEndMs: 2300,
                    recordedAtMs: 2301,
                    status: .ok
                ),
                provider: "deepgram",
                route: .streamingFallbackREST,
                source: "rest_fallback",
                textChars: 12,
                sampleRate: 16000,
                audioBytes: 32000,
                attempts: [
                    DebugSTTAttempt(
                        kind: .streamFinalize,
                        status: .error,
                        eventStartMs: 2000,
                        eventEndMs: 2100,
                        source: "stream_finalize",
                        error: "timeout"
                    ),
                    DebugSTTAttempt(
                        kind: .restFallback,
                        status: .ok,
                        eventStartMs: 2101,
                        eventEndMs: 2300,
                        source: "rest_fallback",
                        textChars: 12,
                        sampleRate: 16000,
                        audioBytes: 32000
                    ),
                ]
            )),
            .vision(DebugVisionLog(
                base: DebugRunLogBase(
                    runID: "run-1",
                    captureID: "cap-1",
                    logType: .vision,
                    eventStartMs: 2300,
                    eventEndMs: 2400,
                    recordedAtMs: 2401,
                    status: .ok
                ),
                model: "gpt-5-nano",
                mode: "ocr",
                contextPresent: true,
                imageBytes: 1024,
                imageWidth: 1280,
                imageHeight: 720,
                error: nil
            )),
            .postprocess(DebugPostProcessLog(
                base: DebugRunLogBase(
                    runID: "run-1",
                    captureID: "cap-1",
                    logType: .postprocess,
                    eventStartMs: 2400,
                    eventEndMs: 2600,
                    recordedAtMs: 2601,
                    status: .ok
                ),
                model: "gpt-5-nano",
                contextPresent: true,
                sttChars: 12,
                outputChars: 11,
                kind: .textPostprocess
            )),
            .directInput(DebugDirectInputLog(
                base: DebugRunLogBase(
                    runID: "run-1",
                    captureID: "cap-1",
                    logType: .directInput,
                    eventStartMs: 2600,
                    eventEndMs: 2650,
                    recordedAtMs: 2651,
                    status: .ok
                ),
                success: true,
                outputChars: 11
            )),
            .pipeline(DebugPipelineLog(
                base: DebugRunLogBase(
                    runID: "run-1",
                    captureID: "cap-1",
                    logType: .pipeline,
                    eventStartMs: 2000,
                    eventEndMs: 2650,
                    recordedAtMs: 2652,
                    status: .ok
                ),
                sttChars: 12,
                outputChars: 11,
                error: nil
            )),
            .contextSummary(DebugContextSummaryLog(
                base: DebugRunLogBase(
                    runID: "run-1",
                    captureID: "cap-1",
                    logType: .contextSummary,
                    eventStartMs: 1500,
                    eventEndMs: 1900,
                    recordedAtMs: 1901,
                    status: .ok
                ),
                source: "accessibility",
                appName: "Xcode",
                sourceChars: 500,
                summaryChars: 120,
                termsCount: 8,
                error: nil
            )),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for log in logs {
            let data = try encoder.encode(log)
            let decoded = try decoder.decode(DebugRunLog.self, from: data)
            XCTAssertEqual(decoded, log)
        }
    }
}
