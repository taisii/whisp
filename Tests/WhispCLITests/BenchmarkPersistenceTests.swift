import Foundation
import XCTest
import WhispCore
@testable import whisp

final class BenchmarkPersistenceTests: XCTestCase {
    private enum DummyFailure: Error {
        case worker
    }

    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBenchmarkCase(id: String) throws -> ManualBenchmarkCase {
        let json = """
        {
          "id": "\(id)",
          "audio_file": "/tmp/\(id).wav"
        }
        """
        return try JSONDecoder().decode(ManualBenchmarkCase.self, from: Data(json.utf8))
    }

    func testSaveBenchmarkRunPersistsRunCasesAndEvents() throws {
        let home = tempHome()
        let runID = "stt-20260211-000000-000-aaaa1111"
        let env = ["HOME": home.path]

        let caseResult = BenchmarkCaseResult(
            id: "case-1",
            status: .ok,
            reason: nil,
            cache: BenchmarkCacheRecord(hit: true, key: "cache-key", namespace: "stt"),
            sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
            contextUsed: false,
            visionImageAttached: false,
            metrics: BenchmarkCaseMetrics(
                exactMatch: true,
                cer: 0,
                sttTotalMs: 120,
                sttAfterStopMs: 40,
                latencyMs: 120,
                outputChars: 32
            )
        )

        let base = WhispCLI.makeEventBase(
            runID: runID,
            caseID: "case-1",
            stage: .aggregate,
            status: .ok,
            seed: 1
        )
        let event = BenchmarkCaseEvent.aggregate(BenchmarkAggregateLog(
            base: base,
            exactMatch: true,
            cer: 0,
            intentMatch: nil,
            intentScore: nil,
            intentPreservationScore: nil,
            hallucinationScore: nil,
            hallucinationRate: nil,
            latencyMs: 120,
            totalAfterStopMs: 40,
            outputChars: 32
        ))

        _ = try WhispCLI.saveBenchmarkRun(
            runID: runID,
            kind: .stt,
            options: .stt(BenchmarkSTTRunOptions(
                common: BenchmarkRunCommonOptions(sourceCasesPath: "/tmp/manual.jsonl"),
                sttMode: "stream"
            )),
            metrics: .stt(BenchmarkSTTRunMetrics(
                counts: BenchmarkRunCounts(
                    casesTotal: 1,
                    casesSelected: 1,
                    executedCases: 1,
                    skippedCases: 0,
                    failedCases: 0,
                    cachedHits: 1
                ),
                exactMatchRate: 1,
                avgCER: 0,
                weightedCER: 0,
                latencyMs: BenchmarkLatencyDistribution(avg: 120, p50: 120, p95: 120, p99: 120)
            )),
            caseResults: [caseResult],
            events: [event],
            environment: env
        )

        let store = BenchmarkStore(environment: env)
        let run = try store.loadRun(runID: runID)
        XCTAssertNotNil(run)
        XCTAssertEqual(run?.id, runID)

        let rows = try store.loadCaseResults(runID: runID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "case-1")
        XCTAssertEqual(rows.first?.metrics.cer, 0)

        let events = try store.loadEvents(runID: runID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.base.stage, .aggregate)
    }

    func testMakeSkippedCaseArtifactsBuildsLoadAndAggregateEvents() {
        let artifacts = WhispCLI.makeSkippedCaseArtifacts(
            runID: "run-skip",
            caseID: "case-skip",
            caseStartedAtMs: 1_700_000_000_000,
            reason: "missing reference",
            cacheNamespace: "stt",
            sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
            contextPresent: true,
            visionImagePresent: false,
            audioFilePath: "/tmp/case-skip.wav",
            metrics: BenchmarkCaseMetrics(audioSeconds: 1.2)
        )

        XCTAssertEqual(artifacts.result.id, "case-skip")
        XCTAssertEqual(artifacts.result.status, .skipped)
        XCTAssertEqual(artifacts.result.reason, "missing reference")
        XCTAssertEqual(artifacts.result.cache?.namespace, "stt")
        XCTAssertEqual(artifacts.events.count, 2)

        guard case let .loadCase(load) = artifacts.events[0] else {
            XCTFail("first event should be loadCase")
            return
        }
        XCTAssertEqual(load.base.stage, .loadCase)
        XCTAssertEqual(load.base.status, .ok)
        XCTAssertEqual(load.sources.transcript, "labels.transcript_gold")

        guard case let .aggregate(aggregate) = artifacts.events[1] else {
            XCTFail("second event should be aggregate")
            return
        }
        XCTAssertEqual(aggregate.base.stage, .aggregate)
        XCTAssertEqual(aggregate.base.status, .skipped)
        XCTAssertGreaterThanOrEqual(aggregate.base.startedAtMs, load.base.endedAtMs)
    }

    func testExecuteBenchmarkRunLifecycleFinalizesCompleted() async throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let runID = "stt-lifecycle-success"
        let runOptions = BenchmarkRunOptions.stt(BenchmarkSTTRunOptions(
            common: BenchmarkRunCommonOptions(sourceCasesPath: "/tmp/manual.jsonl"),
            sttMode: "stream"
        ))
        let recorder = try BenchmarkRunRecorder(
            runID: runID,
            kind: .stt,
            options: runOptions,
            initialMetrics: .stt(BenchmarkSTTRunMetrics(
                counts: BenchmarkRunCounts(
                    casesTotal: 2,
                    casesSelected: 2,
                    executedCases: 0,
                    skippedCases: 0,
                    failedCases: 0,
                    cachedHits: 0
                )
            )),
            environment: env
        )
        let selectedCases = [
            try makeBenchmarkCase(id: "case-1"),
            try makeBenchmarkCase(id: "case-2"),
        ]

        let lifecycle = try await WhispCLI.executeBenchmarkRunLifecycle(
            selectedCases: selectedCases,
            recorder: recorder
        ) {
            // success path
        } snapshotSummary: {
            2
        } makeMetrics: { executed in
            .stt(BenchmarkSTTRunMetrics(
                counts: BenchmarkRunCounts(
                    casesTotal: 2,
                    casesSelected: 2,
                    executedCases: executed,
                    skippedCases: 0,
                    failedCases: 0,
                    cachedHits: 0
                )
            ))
        } makeRunOptions: { _ in
            runOptions
        }

        XCTAssertEqual(lifecycle.run.status, .completed)
        XCTAssertEqual(lifecycle.metrics.executedCases, 2)

        let store = BenchmarkStore(environment: env)
        let run = try XCTUnwrap(try store.loadRun(runID: runID))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.metrics.executedCases, 2)

        let orchestrator = try store.loadOrchestratorEvents(runID: runID)
        XCTAssertEqual(orchestrator.filter { $0.stage == .caseQueued }.count, 2)
        XCTAssertEqual(orchestrator.last?.stage, .runCompleted)
    }

    func testExecuteBenchmarkRunLifecycleFinalizesFailedOnWorkerError() async throws {
        let home = tempHome()
        let env = ["HOME": home.path]
        let runID = "stt-lifecycle-failed"
        let runOptions = BenchmarkRunOptions.stt(BenchmarkSTTRunOptions(
            common: BenchmarkRunCommonOptions(sourceCasesPath: "/tmp/manual.jsonl"),
            sttMode: "stream"
        ))
        let recorder = try BenchmarkRunRecorder(
            runID: runID,
            kind: .stt,
            options: runOptions,
            initialMetrics: .stt(BenchmarkSTTRunMetrics(
                counts: BenchmarkRunCounts(
                    casesTotal: 1,
                    casesSelected: 1,
                    executedCases: 0,
                    skippedCases: 0,
                    failedCases: 0,
                    cachedHits: 0
                )
            )),
            environment: env
        )
        let selectedCases = [try makeBenchmarkCase(id: "case-failed")]

        do {
            _ = try await WhispCLI.executeBenchmarkRunLifecycle(
                selectedCases: selectedCases,
                recorder: recorder
            ) {
                throw DummyFailure.worker
            } snapshotSummary: {
                1
            } makeMetrics: { executed in
                .stt(BenchmarkSTTRunMetrics(
                    counts: BenchmarkRunCounts(
                        casesTotal: 1,
                        casesSelected: 1,
                        executedCases: executed,
                        skippedCases: 0,
                        failedCases: 1,
                        cachedHits: 0
                    )
                ))
            } makeRunOptions: { _ in
                runOptions
            }
            XCTFail("worker error should be rethrown")
        } catch DummyFailure.worker {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let store = BenchmarkStore(environment: env)
        let run = try XCTUnwrap(try store.loadRun(runID: runID))
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.metrics.executedCases, 1)

        let orchestrator = try store.loadOrchestratorEvents(runID: runID)
        XCTAssertEqual(orchestrator.filter { $0.stage == .caseQueued }.count, 1)
        XCTAssertEqual(orchestrator.last?.stage, .runFailed)
    }
}
