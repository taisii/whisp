import XCTest
import WhispCore
@testable import WhispApp

final class STTTraceFactoryTests: XCTestCase {
    func testSingleAttemptTraceBuildsConsistentMainSpan() {
        let trace = STTTraceFactory.singleAttemptTrace(
            provider: STTProvider.deepgram.rawValue,
            transport: .rest,
            route: .rest,
            kind: .rest,
            eventStartMs: 100,
            eventEndMs: 160,
            source: "rest",
            textChars: 42,
            sampleRate: 16_000,
            audioBytes: 320_000
        )

        XCTAssertEqual(trace.provider, STTProvider.deepgram.rawValue)
        XCTAssertEqual(trace.transport, .rest)
        XCTAssertEqual(trace.route, .rest)
        XCTAssertEqual(trace.mainSpan.eventStartMs, 100)
        XCTAssertEqual(trace.mainSpan.eventEndMs, 160)
        XCTAssertEqual(trace.mainSpan.source, "rest")
        XCTAssertEqual(trace.mainSpan.textChars, 42)
        XCTAssertEqual(trace.attempts.count, 1)
        XCTAssertEqual(trace.attempts.first?.kind, .rest)
        XCTAssertEqual(trace.attempts.first?.status, .ok)
    }
}
