import Foundation
import WhispCore

extension WhispCLI {
    static func makeSkippedCaseArtifacts(
        runID: String,
        caseID: String,
        caseStartedAtMs: Int64,
        reason: String,
        cacheNamespace: String,
        sources: BenchmarkReferenceSources = BenchmarkReferenceSources(),
        contextPresent: Bool,
        visionImagePresent: Bool,
        audioFilePath: String?,
        metrics: BenchmarkCaseMetrics = BenchmarkCaseMetrics()
    ) -> (result: BenchmarkCaseResult, events: [BenchmarkCaseEvent]) {
        let result = BenchmarkCaseResult(
            id: caseID,
            status: .skipped,
            reason: reason,
            cache: BenchmarkCacheRecord(hit: false, namespace: cacheNamespace),
            sources: sources,
            contextUsed: contextPresent,
            visionImageAttached: visionImagePresent,
            metrics: metrics
        )
        let loadEndedAtMs = nowEpochMs()
        let events: [BenchmarkCaseEvent] = [
            .loadCase(BenchmarkLoadCaseLog(
                base: makeEventBase(
                    runID: runID,
                    caseID: caseID,
                    stage: .loadCase,
                    status: .ok,
                    startedAtMs: caseStartedAtMs,
                    endedAtMs: loadEndedAtMs
                ),
                sources: sources,
                contextPresent: contextPresent,
                visionImagePresent: visionImagePresent,
                audioFilePath: audioFilePath,
                rawRowRef: nil
            )),
            .aggregate(BenchmarkAggregateLog(
                base: makeEventBase(
                    runID: runID,
                    caseID: caseID,
                    stage: .aggregate,
                    status: .skipped,
                    startedAtMs: loadEndedAtMs,
                    endedAtMs: nowEpochMs()
                ),
                exactMatch: nil,
                cer: nil,
                intentMatch: nil,
                intentScore: nil,
                intentPreservationScore: nil,
                hallucinationScore: nil,
                hallucinationRate: nil,
                latencyMs: nil,
                totalAfterStopMs: nil,
                outputChars: nil
            )),
        ]
        return (result: result, events: events)
    }
}
