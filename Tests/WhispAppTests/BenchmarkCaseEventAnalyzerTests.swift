import XCTest
import WhispCore
@testable import WhispApp

final class BenchmarkCaseEventAnalyzerTests: XCTestCase {
    func testAnalyzeBuildsTimelineAndOverlap() {
        let analyzer = BenchmarkCaseEventAnalyzer()
        let events: [BenchmarkCaseEvent] = [
            .loadCase(BenchmarkLoadCaseLog(
                base: Self.base(stage: .loadCase, started: 0, ended: 10),
                sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
                contextPresent: false,
                visionImagePresent: false,
                audioFilePath: "/tmp/a.wav",
                rawRowRef: nil
            )),
            .audioReplay(BenchmarkAudioReplayLog(
                base: Self.base(stage: .audioReplay, started: 100, ended: 500),
                profile: "file_replay_realtime",
                chunkMs: 120,
                realtime: true
            )),
            .stt(BenchmarkSTTLog(
                base: Self.base(stage: .stt, started: 300, ended: 900),
                provider: "deepgram",
                mode: "stream",
                transcriptChars: 10,
                cer: 0.1,
                sttTotalMs: 600,
                sttAfterStopMs: 200,
                attempts: [
                    BenchmarkSTTAttempt(kind: "stream_send", status: .ok, startedAtMs: 300, endedAtMs: 700),
                    BenchmarkSTTAttempt(kind: "stream_finalize", status: .ok, startedAtMs: 701, endedAtMs: 900),
                ],
                rawResponseRef: nil,
                error: nil
            )),
        ]

        let analysis = analyzer.analyze(events: events)

        XCTAssertEqual(analysis.audioFilePath, "/tmp/a.wav")
        XCTAssertEqual(analysis.sttLog?.provider, "deepgram")
        XCTAssertEqual(analysis.timeline.phases.count, 3)
        XCTAssertEqual(analysis.timeline.totalMs, 800)
        XCTAssertEqual(analysis.timeline.overlap?.durationMs, 200)
        XCTAssertEqual(analysis.timeline.recordingMs, 400)
        XCTAssertEqual(analysis.timeline.sttMs, 600)
        XCTAssertEqual(analysis.timeline.deltaAfterRecordingMs, 400)
        XCTAssertTrue(analysis.timeline.missingMessages.isEmpty)
    }

    func testAnalyzeHandlesMissingAudioReplayWithoutCrash() {
        let analyzer = BenchmarkCaseEventAnalyzer()
        let events: [BenchmarkCaseEvent] = [
            .loadCase(BenchmarkLoadCaseLog(
                base: Self.base(stage: .loadCase, started: 0, ended: 10),
                sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
                contextPresent: false,
                visionImagePresent: false,
                audioFilePath: "/tmp/a.wav",
                rawRowRef: nil
            )),
            .stt(BenchmarkSTTLog(
                base: Self.base(stage: .stt, started: 50, ended: 150),
                provider: "deepgram",
                mode: "stream",
                transcriptChars: 8,
                cer: 0.2,
                sttTotalMs: 100,
                sttAfterStopMs: 40,
                attempts: nil,
                rawResponseRef: nil,
                error: nil
            )),
        ]

        let analysis = analyzer.analyze(events: events)

        XCTAssertEqual(analysis.timeline.phases.count, 1)
        XCTAssertTrue(analysis.timeline.missingMessages.contains(where: { $0.contains("audio_replay") }))
    }

    private static func base(stage: BenchmarkEventStage, started: Int64, ended: Int64) -> BenchmarkCaseEventBase {
        BenchmarkCaseEventBase(
            runID: "run-1",
            caseID: "case-1",
            stage: stage,
            status: .ok,
            startedAtMs: started,
            endedAtMs: ended,
            recordedAtMs: ended + 1
        )
    }
}
