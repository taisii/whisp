import Foundation

public struct BenchmarkLegacyImportInput: Sendable {
    public var runID: String?
    public var kind: BenchmarkKind
    public var rowsPath: String
    public var summaryPath: String
    public var logDirectoryPath: String
    public var options: BenchmarkRunOptions

    public init(
        runID: String? = nil,
        kind: BenchmarkKind,
        rowsPath: String,
        summaryPath: String,
        logDirectoryPath: String,
        options: BenchmarkRunOptions
    ) {
        self.runID = runID
        self.kind = kind
        self.rowsPath = rowsPath
        self.summaryPath = summaryPath
        self.logDirectoryPath = logDirectoryPath
        self.options = options
    }
}

private struct ImportedComponentSummary: Decodable {
    let generatedAt: String
    let benchmark: String
    let jsonlPath: String
    let casesTotal: Int
    let casesSelected: Int
    let executedCases: Int
    let skippedCases: Int
    let failedCases: Int
    let cachedHits: Int

    let exactMatchRate: Double?
    let avgCER: Double?
    let weightedCER: Double?
    let avgTermsF1: Double?
    let intentMatchRate: Double?
    let intentAvgScore: Double?

    let intentPreservationScore: Double?
    let hallucinationScore: Double?
    let hallucinationRate: Double?
    let llmEvalEnabled: Bool
    let llmEvalEvaluatedCases: Int
    let llmEvalErrorCases: Int

    let latencyMs: BenchmarkLatencyDistribution?
    let afterStopLatencyMs: BenchmarkLatencyDistribution?
    let postLatencyMs: BenchmarkLatencyDistribution?
    let totalAfterStopLatencyMs: BenchmarkLatencyDistribution?
}

private struct ImportedManualSummary: Decodable {
    let generatedAt: String
    let jsonlPath: String
    let sttMode: String
    let chunkMs: Int
    let realtime: Bool
    let requireContext: Bool
    let minAudioSeconds: Double
    let minLabelConfidence: Double?
    let intentSource: String
    let intentJudgeEnabled: Bool
    let llmEvalEnabled: Bool
    let llmEvalEvaluatedCases: Int
    let llmEvalErrorCases: Int
    let casesTotal: Int
    let casesSelected: Int
    let executedCases: Int
    let skippedMissingAudio: Int
    let skippedInvalidAudio: Int
    let skippedMissingReferenceTranscript: Int
    let skippedMissingContext: Int
    let skippedTooShortAudio: Int
    let skippedLowLabelConfidence: Int
    let failedRuns: Int
    let exactMatchRate: Double
    let avgCER: Double
    let weightedCER: Double
    let intentMatchRate: Double?
    let intentAvgScore: Double?
    let intentPreservationScore: Double?
    let hallucinationScore: Double?
    let hallucinationRate: Double?
    let sttTotalMs: BenchmarkLatencyDistribution?
    let sttAfterStopMs: BenchmarkLatencyDistribution?
    let postMs: BenchmarkLatencyDistribution?
    let totalAfterStopMs: BenchmarkLatencyDistribution?
}

private struct ImportedCaseRow: Decodable {
    let id: String
    let status: String
    let reason: String?
    let cached: Bool?

    let transcriptReferenceSource: String?
    let inputSource: String?
    let referenceSource: String?
    let intentReferenceSource: String?
    let contextUsed: Bool?
    let visionImageAttached: Bool?

    let exactMatch: Bool?
    let cer: Double?
    let termsPrecision: Double?
    let termsRecall: Double?
    let termsF1: Double?
    let intentMatch: Bool?
    let intentScore: Int?

    let intentPreservationScore: Double?
    let hallucinationScore: Double?
    let hallucinationRate: Double?

    let sttTotalMs: Double?
    let sttAfterStopMs: Double?
    let postMs: Double?
    let totalAfterStopMs: Double?
    let latencyMs: Double?
    let audioSeconds: Double?
    let outputChars: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case reason
        case cached
        case transcriptReferenceSource
        case inputSource
        case referenceSource
        case intentReferenceSource
        case contextUsed
        case visionImageAttached
        case exactMatch
        case cer
        case termsPrecision
        case termsRecall
        case termsF1
        case intentMatch
        case intentScore
        case intentPreservationScore
        case hallucinationScore
        case hallucinationRate
        case sttTotalMs
        case sttAfterStopMs
        case postMs
        case totalAfterStopMs
        case latencyMs
        case audioSeconds
        case outputChars
    }
}

public final class BenchmarkLegacyImporter: Sendable {
    private let store: BenchmarkStore

    public init(store: BenchmarkStore) {
        self.store = store
    }

    @discardableResult
    public func importRun(input: BenchmarkLegacyImportInput) throws -> BenchmarkRunRecord {
        let summaryURL = URL(fileURLWithPath: input.summaryPath)
        let summaryData = try Data(contentsOf: summaryURL)
        let metrics = try decodeRunMetrics(kind: input.kind, summaryData: summaryData)

        let runID = input.runID ?? defaultRunID(kind: input.kind)
        let now = isoNow()
        var paths = store.resolveRunPaths(runID: runID)
        paths.logDirectoryPath = input.logDirectoryPath
        paths.rowsFilePath = input.rowsPath
        paths.summaryFilePath = input.summaryPath

        let run = BenchmarkRunRecord(
            id: runID,
            kind: input.kind,
            status: .completed,
            createdAt: now,
            updatedAt: now,
            options: input.options,
            metrics: metrics,
            paths: paths
        )
        try store.saveRun(run)

        let rowText = try String(contentsOfFile: input.rowsPath, encoding: .utf8)
        let lines = rowText.components(separatedBy: .newlines)
        let decoder = JSONDecoder()

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            guard let lineData = line.data(using: .utf8) else {
                throw AppError.decode("invalid benchmark row encoding")
            }
            let row = try decoder.decode(ImportedCaseRow.self, from: lineData)

            let caseID = row.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "case-\(index + 1)"
                : row.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = decodeCaseStatus(row.status)

            let caseMetrics = BenchmarkCaseMetrics(
                exactMatch: row.exactMatch,
                cer: row.cer,
                termPrecision: row.termsPrecision,
                termRecall: row.termsRecall,
                termF1: row.termsF1,
                intentMatch: row.intentMatch,
                intentScore: row.intentScore,
                intentPreservationScore: row.intentPreservationScore,
                hallucinationScore: row.hallucinationScore,
                hallucinationRate: row.hallucinationRate,
                sttTotalMs: row.sttTotalMs,
                sttAfterStopMs: row.sttAfterStopMs,
                postMs: row.postMs,
                totalAfterStopMs: row.totalAfterStopMs,
                latencyMs: row.latencyMs,
                audioSeconds: row.audioSeconds,
                outputChars: row.outputChars
            )

            let rawRowRef: BenchmarkArtifactRef?
            do {
                rawRowRef = try store.writeArtifact(
                    runID: runID,
                    caseID: caseID,
                    fileName: "legacy_row.json",
                    mimeType: "application/json",
                    data: lineData
                )
            } catch {
                rawRowRef = nil
                let base = eventBase(runID: runID, caseID: caseID, stage: .artifactWriteFailed, status: .error, seed: index * 10)
                try? store.appendEvent(runID: runID, event: .artifactWriteFailed(BenchmarkArtifactWriteFailedLog(
                    base: base,
                    relativePath: "artifacts/\(caseID)/legacy_row.json",
                    message: error.localizedDescription
                )))
            }

            let sources = BenchmarkReferenceSources(
                transcript: normalizedOptionalText(row.transcriptReferenceSource),
                input: normalizedOptionalText(row.inputSource),
                reference: normalizedOptionalText(row.referenceSource),
                intent: normalizedOptionalText(row.intentReferenceSource)
            )

            let cacheRecord = row.cached.map { hit in
                BenchmarkCacheRecord(hit: hit)
            }

            let caseResult = BenchmarkCaseResult(
                id: caseID,
                status: status,
                reason: normalizedOptionalText(row.reason),
                cache: cacheRecord,
                sources: sources,
                contextUsed: row.contextUsed,
                visionImageAttached: row.visionImageAttached,
                metrics: caseMetrics
            )
            try store.appendCaseResult(runID: runID, result: caseResult)

            let loadBase = eventBase(runID: runID, caseID: caseID, stage: .loadCase, status: .ok, seed: index * 10)
            try store.appendEvent(runID: runID, event: .loadCase(BenchmarkLoadCaseLog(
                base: loadBase,
                sources: sources,
                contextPresent: caseResult.contextUsed ?? false,
                visionImagePresent: caseResult.visionImageAttached ?? false,
                audioFilePath: nil,
                rawRowRef: rawRowRef
            )))

            if let cacheHit = row.cached {
                let cacheBase = eventBase(runID: runID, caseID: caseID, stage: .cache, status: .ok, seed: index * 10 + 1)
                try store.appendEvent(runID: runID, event: .cache(BenchmarkCacheLog(
                    base: cacheBase,
                    namespace: nil,
                    key: nil,
                    hit: cacheHit,
                    keyMaterialRef: nil,
                    error: nil
                )))
            }

            if caseMetrics.sttTotalMs != nil || caseMetrics.sttAfterStopMs != nil {
                let sttBase = eventBase(runID: runID, caseID: caseID, stage: .stt, status: .ok, seed: index * 10 + 2)
                try store.appendEvent(runID: runID, event: .stt(BenchmarkSTTLog(
                    base: sttBase,
                    provider: nil,
                    mode: input.options.sttMode,
                    transcriptChars: nil,
                    cer: caseMetrics.cer,
                    sttTotalMs: caseMetrics.sttTotalMs,
                    sttAfterStopMs: caseMetrics.sttAfterStopMs,
                    rawResponseRef: nil,
                    error: nil
                )))
            }

            if caseMetrics.postMs != nil || caseMetrics.outputChars != nil {
                let generationBase = eventBase(runID: runID, caseID: caseID, stage: .generation, status: .ok, seed: index * 10 + 3)
                try store.appendEvent(runID: runID, event: .generation(BenchmarkGenerationLog(
                    base: generationBase,
                    model: input.options.llmModel,
                    inputChars: nil,
                    outputChars: caseMetrics.outputChars,
                    postMs: caseMetrics.postMs,
                    promptRef: nil,
                    responseRef: nil,
                    error: nil
                )))
            }

            if caseMetrics.intentMatch != nil || caseMetrics.intentScore != nil || caseMetrics.intentPreservationScore != nil || caseMetrics.hallucinationScore != nil || caseMetrics.hallucinationRate != nil {
                let judgeBase = eventBase(runID: runID, caseID: caseID, stage: .judge, status: .ok, seed: index * 10 + 4)
                try store.appendEvent(runID: runID, event: .judge(BenchmarkJudgeLog(
                    base: judgeBase,
                    model: input.options.llmEvalModel ?? input.options.intentJudgeModel,
                    match: caseMetrics.intentMatch,
                    score: caseMetrics.intentScore,
                    intentPreservationScore: caseMetrics.intentPreservationScore,
                    hallucinationScore: caseMetrics.hallucinationScore,
                    hallucinationRate: caseMetrics.hallucinationRate,
                    requestRef: nil,
                    responseRef: nil,
                    error: nil
                )))
            }

            let aggregateBase = eventBase(runID: runID, caseID: caseID, stage: .aggregate, status: .ok, seed: index * 10 + 5)
            try store.appendEvent(runID: runID, event: .aggregate(BenchmarkAggregateLog(
                base: aggregateBase,
                exactMatch: caseMetrics.exactMatch,
                cer: caseMetrics.cer,
                intentMatch: caseMetrics.intentMatch,
                intentScore: caseMetrics.intentScore,
                intentPreservationScore: caseMetrics.intentPreservationScore,
                hallucinationScore: caseMetrics.hallucinationScore,
                hallucinationRate: caseMetrics.hallucinationRate,
                latencyMs: caseMetrics.latencyMs,
                totalAfterStopMs: caseMetrics.totalAfterStopMs,
                outputChars: caseMetrics.outputChars
            )))

            if status == .error {
                let errorBase = eventBase(runID: runID, caseID: caseID, stage: .error, status: .error, seed: index * 10 + 6)
                try store.appendEvent(runID: runID, event: .error(BenchmarkErrorLog(
                    base: errorBase,
                    originStage: nil,
                    errorType: "legacy_row_error",
                    message: row.reason ?? "unknown"
                )))
            }
        }

        do {
            let summaryRef = try store.writeArtifact(
                runID: runID,
                caseID: "_run",
                fileName: "legacy_summary.json",
                mimeType: "application/json",
                data: summaryData
            )
            let base = eventBase(runID: runID, caseID: "_run", stage: .aggregate, status: .ok, seed: 999_000)
            try store.appendEvent(runID: runID, event: .aggregate(BenchmarkAggregateLog(
                base: base,
                exactMatch: nil,
                cer: metrics.avgCER,
                intentMatch: nil,
                intentScore: nil,
                intentPreservationScore: metrics.intentPreservationScore,
                hallucinationScore: metrics.hallucinationScore,
                hallucinationRate: metrics.hallucinationRate,
                latencyMs: metrics.latencyMs?.avg,
                totalAfterStopMs: metrics.totalAfterStopLatencyMs?.avg,
                outputChars: nil
            )))
            let loadBase = eventBase(runID: runID, caseID: "_run", stage: .loadCase, status: .ok, seed: 999_001)
            try store.appendEvent(runID: runID, event: .loadCase(BenchmarkLoadCaseLog(
                base: loadBase,
                sources: BenchmarkReferenceSources(),
                contextPresent: false,
                visionImagePresent: false,
                audioFilePath: nil,
                rawRowRef: summaryRef
            )))
        } catch {
            let base = eventBase(runID: runID, caseID: "_run", stage: .artifactWriteFailed, status: .error, seed: 999_002)
            try? store.appendEvent(runID: runID, event: .artifactWriteFailed(BenchmarkArtifactWriteFailedLog(
                base: base,
                relativePath: "artifacts/_run/legacy_summary.json",
                message: error.localizedDescription
            )))
        }

        return run
    }

    private func decodeRunMetrics(kind: BenchmarkKind, summaryData: Data) throws -> BenchmarkRunMetrics {
        let decoder = JSONDecoder()
        if kind == .e2e {
            let summary = try decoder.decode(ImportedManualSummary.self, from: summaryData)
            return manualSummaryToRunMetrics(summary)
        }
        let summary = try decoder.decode(ImportedComponentSummary.self, from: summaryData)
        return componentSummaryToRunMetrics(summary)
    }

    private func componentSummaryToRunMetrics(_ summary: ImportedComponentSummary) -> BenchmarkRunMetrics {
        BenchmarkRunMetrics(
            casesTotal: summary.casesTotal,
            casesSelected: summary.casesSelected,
            executedCases: summary.executedCases,
            skippedCases: summary.skippedCases,
            failedCases: summary.failedCases,
            cachedHits: summary.cachedHits,
            exactMatchRate: summary.exactMatchRate,
            avgCER: summary.avgCER,
            weightedCER: summary.weightedCER,
            avgTermsF1: summary.avgTermsF1,
            intentMatchRate: summary.intentMatchRate,
            intentAvgScore: summary.intentAvgScore,
            intentPreservationScore: summary.intentPreservationScore,
            hallucinationScore: summary.hallucinationScore,
            hallucinationRate: summary.hallucinationRate,
            latencyMs: summary.latencyMs,
            afterStopLatencyMs: summary.afterStopLatencyMs,
            postLatencyMs: summary.postLatencyMs,
            totalAfterStopLatencyMs: summary.totalAfterStopLatencyMs
        )
    }

    private func manualSummaryToRunMetrics(_ summary: ImportedManualSummary) -> BenchmarkRunMetrics {
        let skippedCases = summary.skippedMissingAudio
            + summary.skippedInvalidAudio
            + summary.skippedMissingReferenceTranscript
            + summary.skippedMissingContext
            + summary.skippedTooShortAudio
            + summary.skippedLowLabelConfidence

        return BenchmarkRunMetrics(
            casesTotal: summary.casesTotal,
            casesSelected: summary.casesSelected,
            executedCases: summary.executedCases,
            skippedCases: skippedCases,
            failedCases: summary.failedRuns,
            cachedHits: 0,
            exactMatchRate: summary.exactMatchRate,
            avgCER: summary.avgCER,
            weightedCER: summary.weightedCER,
            avgTermsF1: nil,
            intentMatchRate: summary.intentMatchRate,
            intentAvgScore: summary.intentAvgScore,
            intentPreservationScore: summary.intentPreservationScore,
            hallucinationScore: summary.hallucinationScore,
            hallucinationRate: summary.hallucinationRate,
            latencyMs: summary.sttTotalMs,
            afterStopLatencyMs: summary.sttAfterStopMs,
            postLatencyMs: summary.postMs,
            totalAfterStopLatencyMs: summary.totalAfterStopMs
        )
    }

    private func decodeCaseStatus(_ raw: String) -> BenchmarkCaseStatus {
        if raw == "ok" {
            return .ok
        }
        if raw.hasPrefix("skipped") {
            return .skipped
        }
        return .error
    }

    private func eventBase(
        runID: String,
        caseID: String,
        stage: BenchmarkEventStage,
        status: BenchmarkEventStatus,
        seed: Int
    ) -> BenchmarkCaseEventBase {
        let now = Date().timeIntervalSince1970 * 1000
        let started = Int64(now) + Int64(seed)
        return BenchmarkCaseEventBase(
            runID: runID,
            caseID: caseID,
            stage: stage,
            status: status,
            startedAtMs: started,
            endedAtMs: started + 1,
            recordedAtMs: started + 2
        )
    }

    private func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func defaultRunID(kind: BenchmarkKind) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let timestamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "\(kind.rawValue)-\(timestamp)-\(suffix)"
    }

    private func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
