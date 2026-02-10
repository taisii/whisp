import XCTest
@testable import WhispCore

final class DebugRunEventSchemaTests: XCTestCase {
    func testCriticalEventNamesAreStable() {
        XCTAssertEqual(DebugRunEventName.recordingStart.rawValue, "recording_start")
        XCTAssertEqual(DebugRunEventName.sttStart.rawValue, "stt_start")
        XCTAssertEqual(DebugRunEventName.sttDone.rawValue, "stt_done")
        XCTAssertEqual(DebugRunEventName.contextSummaryStart.rawValue, "context_summary_start")
        XCTAssertEqual(DebugRunEventName.contextSummaryDone.rawValue, "context_summary_done")
        XCTAssertEqual(DebugRunEventName.pipelineDone.rawValue, "pipeline_done")
        XCTAssertEqual(DebugRunEventName.pipelineError.rawValue, "pipeline_error")
    }

    func testCriticalFieldNamesAreStable() {
        XCTAssertEqual(DebugRunEventField.sttProvider.rawValue, "stt_provider")
        XCTAssertEqual(DebugRunEventField.source.rawValue, "source")
        XCTAssertEqual(DebugRunEventField.durationMs.rawValue, "duration_ms")
        XCTAssertEqual(DebugRunEventField.requestSentAtMs.rawValue, "request_sent_at_ms")
        XCTAssertEqual(DebugRunEventField.responseReceivedAtMs.rawValue, "response_received_at_ms")
        XCTAssertEqual(DebugRunEventField.pipelineMs.rawValue, "pipeline_ms")
        XCTAssertEqual(DebugRunEventField.endToEndMs.rawValue, "end_to_end_ms")
    }
}
