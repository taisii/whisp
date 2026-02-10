import XCTest
import WhispCore
@testable import WhispApp

final class DebugEventAnalyzerTests: XCTestCase {
    func testAnalyzeResolvesSTTProviderAndRouteFromSharedSchema() {
        let analyzer = DebugEventAnalyzer()
        let events: [DebugRunEvent] = [
            makeEvent(.recordingStart, fields: [
                .sttProvider: STTProvider.whisper.rawValue,
                .recordingStartedAtMs: "1000",
            ]),
            makeEvent(.recordingStop, fields: [
                .recordingMs: "1000",
                .recordingStoppedAtMs: "2000",
            ]),
            makeEvent(.sttStart, fields: [
                .source: DebugSTTSource.whisper.rawValue,
                .requestSentAtMs: "2000",
            ]),
            makeEvent(.sttDone, fields: [
                .source: DebugSTTSource.whisperREST.rawValue,
                .durationMs: "120",
                .requestSentAtMs: "2000",
                .responseReceivedAtMs: "2120",
            ]),
            makeEvent(.postprocessDone, fields: [
                .durationMs: "85",
            ]),
            makeEvent(.directInputDone, fields: [
                .durationMs: "10",
            ]),
            makeEvent(.pipelineDone, fields: [
                .pipelineMs: "250",
                .endToEndMs: "1250",
            ]),
        ]

        let analysis = analyzer.analyze(events: events)

        XCTAssertEqual(analysis.sttInfo.providerName, "Whisper (OpenAI)")
        XCTAssertEqual(analysis.sttInfo.routeName, "REST")
        XCTAssertEqual(analysis.timings.recordingMs, 1000)
        XCTAssertEqual(analysis.timings.sttMs, 120)
        XCTAssertEqual(analysis.timings.postProcessMs, 85)
        XCTAssertEqual(analysis.timings.pipelineMs, 250)
    }

    func testAnalyzePrefersContextSummaryTimelineWhenPresent() {
        let analyzer = DebugEventAnalyzer()
        let events: [DebugRunEvent] = [
            makeEvent(.contextSummaryStart, fields: [
                .requestSentAtMs: "5000",
            ]),
            makeEvent(.contextSummaryDone, fields: [
                .durationMs: "180",
                .requestSentAtMs: "5000",
                .responseReceivedAtMs: "5180",
            ]),
            makeEvent(.visionStart, fields: [
                .requestSentAtMs: "6000",
            ]),
            makeEvent(.visionDone, fields: [
                .totalMs: "220",
                .requestSentAtMs: "6000",
                .responseReceivedAtMs: "6220",
            ]),
            makeEvent(.pipelineDone, fields: [
                .pipelineMs: "300",
                .endToEndMs: "1500",
            ]),
        ]

        let analysis = analyzer.analyze(events: events)

        XCTAssertEqual(analysis.timings.visionTotalMs, 180)
        XCTAssertTrue(analysis.timeline.phases.contains { $0.id == "context_summary" })
        XCTAssertFalse(analysis.timeline.phases.contains { $0.id == "vision" })
    }

    private func makeEvent(
        _ name: DebugRunEventName,
        timestamp: String = "2026-02-10T00:00:00.000Z",
        fields: [DebugRunEventField: String] = [:]
    ) -> DebugRunEvent {
        DebugRunEvent(
            timestamp: timestamp,
            event: name.rawValue,
            fields: Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) })
        )
    }
}
