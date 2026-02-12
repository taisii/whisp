import Foundation
import XCTest
@testable import WhispCore

final class BenchmarkEventCodableTests: XCTestCase {
    func testAudioReplayEventCodableRoundtrip() throws {
        let base = BenchmarkCaseEventBase(
            runID: "run-1",
            caseID: "case-1",
            stage: .audioReplay,
            status: .ok,
            startedAtMs: 1_000,
            endedAtMs: 2_000,
            recordedAtMs: 2_001
        )
        let event = BenchmarkCaseEvent.audioReplay(BenchmarkAudioReplayLog(
            base: base,
            profile: "file_replay_realtime",
            chunkMs: 120,
            realtime: true
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BenchmarkCaseEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func testSTTEventCodableRoundtripIncludesAttempts() throws {
        let base = BenchmarkCaseEventBase(
            runID: "run-2",
            caseID: "case-9",
            stage: .stt,
            status: .ok,
            startedAtMs: 10,
            endedAtMs: 110,
            recordedAtMs: 111
        )
        let event = BenchmarkCaseEvent.stt(BenchmarkSTTLog(
            base: base,
            provider: "deepgram",
            mode: "stream",
            transcriptText: "あしたの会議を移動してください",
            referenceText: "明日の会議を移動してください",
            transcriptChars: 42,
            cer: 0.12,
            sttTotalMs: 85,
            sttAfterStopMs: 20,
            attempts: [
                BenchmarkSTTAttempt(kind: "stream_send", status: .ok, startedAtMs: 10, endedAtMs: 70),
                BenchmarkSTTAttempt(kind: "stream_finalize", status: .ok, startedAtMs: 71, endedAtMs: 110),
            ],
            rawResponseRef: nil,
            error: nil
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BenchmarkCaseEvent.self, from: data)
        XCTAssertEqual(decoded, event)

        guard case let .stt(stt) = decoded else {
            return XCTFail("expected stt event")
        }
        XCTAssertEqual(stt.attempts?.count, 2)
        XCTAssertEqual(stt.attempts?.first?.kind, "stream_send")
        XCTAssertEqual(stt.transcriptText, "あしたの会議を移動してください")
        XCTAssertEqual(stt.referenceText, "明日の会議を移動してください")
    }

    func testRunOptionsCodableRoundtripIncludesExecutionProfile() throws {
        let options = BenchmarkRunOptions(
            sourceCasesPath: "/tmp/cases.jsonl",
            sttExecutionProfile: "file_replay_realtime",
            datasetHash: "hash",
            runtimeOptionsHash: "runtime"
        )

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(BenchmarkRunOptions.self, from: data)
        XCTAssertEqual(decoded.sttExecutionProfile, "file_replay_realtime")
    }
}
