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

public final class BenchmarkLegacyImporter: Sendable {
    private let store: BenchmarkStore

    public init(store: BenchmarkStore) {
        self.store = store
    }

    @discardableResult
    public func importRun(input: BenchmarkLegacyImportInput) throws -> BenchmarkRunRecord {
        let summaryURL = URL(fileURLWithPath: input.summaryPath)
        let summaryData = try Data(contentsOf: summaryURL)
        let summaryJSONObject = try JSONSerialization.jsonObject(with: summaryData)

        guard let summary = summaryJSONObject as? [String: Any] else {
            throw AppError.decode("legacy summary is not object")
        }

        let runID = input.runID ?? defaultRunID(kind: input.kind)
        let now = isoNow()
        let metrics = summaryToRunMetrics(summary)
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

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            guard let lineData = line.data(using: .utf8) else {
                continue
            }
            let obj = try JSONSerialization.jsonObject(with: lineData)
            guard let row = obj as? [String: Any] else {
                continue
            }

            let caseID = readString(row, key: "id") ?? "case-\(index + 1)"
            let status = decodeCaseStatus(readString(row, key: "status"))
            let reason = readString(row, key: "reason")

            let metrics = BenchmarkCaseMetrics(
                exactMatch: readBool(row, keys: ["exact_match", "exactMatch"]),
                cer: readDouble(row, key: "cer"),
                termPrecision: readDouble(row, keys: ["terms_precision", "termsPrecision"]),
                termRecall: readDouble(row, keys: ["terms_recall", "termsRecall"]),
                termF1: readDouble(row, keys: ["terms_f1", "termsF1"]),
                intentMatch: readBool(row, keys: ["intent_match", "intentMatch"]),
                intentScore: readInt(row, keys: ["intent_score", "intentScore"]),
                sttTotalMs: readDouble(row, keys: ["stt_total_ms", "sttTotalMs"]),
                sttAfterStopMs: readDouble(row, keys: ["stt_after_stop_ms", "sttAfterStopMs"]),
                postMs: readDouble(row, keys: ["post_ms", "postMs"]),
                totalAfterStopMs: readDouble(row, keys: ["total_after_stop_ms", "totalAfterStopMs"]),
                latencyMs: readDouble(row, keys: ["latency_ms", "latencyMs"]),
                audioSeconds: readDouble(row, keys: ["audio_seconds", "audioSeconds"]),
                outputChars: readInt(row, keys: ["output_chars", "outputChars"])
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
                transcript: readString(row, keys: ["transcript_reference_source", "transcriptReferenceSource"]),
                input: readString(row, keys: ["input_source", "inputSource"]),
                reference: readString(row, keys: ["reference_source", "referenceSource"]),
                intent: readString(row, keys: ["intent_reference_source", "intentReferenceSource"])
            )

            let cacheHit = readBool(row, key: "cached")
            let cacheRecord = cacheHit.map { hit in
                BenchmarkCacheRecord(hit: hit)
            }

            let caseResult = BenchmarkCaseResult(
                id: caseID,
                status: status,
                reason: reason,
                cache: cacheRecord,
                sources: sources,
                contextUsed: readBool(row, keys: ["context_used", "contextUsed"]),
                visionImageAttached: readBool(row, keys: ["vision_image_attached", "visionImageAttached"]),
                metrics: metrics
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

            if let cacheHit {
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

            if metrics.sttTotalMs != nil || metrics.sttAfterStopMs != nil {
                let sttBase = eventBase(runID: runID, caseID: caseID, stage: .stt, status: .ok, seed: index * 10 + 2)
                try store.appendEvent(runID: runID, event: .stt(BenchmarkSTTLog(
                    base: sttBase,
                    provider: nil,
                    mode: input.options.sttMode,
                    transcriptChars: nil,
                    cer: metrics.cer,
                    sttTotalMs: metrics.sttTotalMs,
                    sttAfterStopMs: metrics.sttAfterStopMs,
                    rawResponseRef: nil,
                    error: nil
                )))
            }

            if metrics.postMs != nil || metrics.outputChars != nil {
                let genBase = eventBase(runID: runID, caseID: caseID, stage: .generation, status: .ok, seed: index * 10 + 3)
                try store.appendEvent(runID: runID, event: .generation(BenchmarkGenerationLog(
                    base: genBase,
                    model: input.options.llmModel,
                    inputChars: nil,
                    outputChars: metrics.outputChars,
                    postMs: metrics.postMs,
                    promptRef: nil,
                    responseRef: nil,
                    error: nil
                )))
            }

            if metrics.intentMatch != nil || metrics.intentScore != nil {
                let judgeBase = eventBase(runID: runID, caseID: caseID, stage: .judge, status: .ok, seed: index * 10 + 4)
                try store.appendEvent(runID: runID, event: .judge(BenchmarkJudgeLog(
                    base: judgeBase,
                    model: input.options.intentJudgeModel,
                    match: metrics.intentMatch,
                    score: metrics.intentScore,
                    requestRef: nil,
                    responseRef: nil,
                    error: nil
                )))
            }

            let aggregateBase = eventBase(runID: runID, caseID: caseID, stage: .aggregate, status: .ok, seed: index * 10 + 5)
            try store.appendEvent(runID: runID, event: .aggregate(BenchmarkAggregateLog(
                base: aggregateBase,
                exactMatch: metrics.exactMatch,
                cer: metrics.cer,
                intentMatch: metrics.intentMatch,
                intentScore: metrics.intentScore,
                latencyMs: metrics.latencyMs,
                totalAfterStopMs: metrics.totalAfterStopMs,
                outputChars: metrics.outputChars
            )))

            if status == .error {
                let errorBase = eventBase(runID: runID, caseID: caseID, stage: .error, status: .error, seed: index * 10 + 6)
                try store.appendEvent(runID: runID, event: .error(BenchmarkErrorLog(
                    base: errorBase,
                    originStage: nil,
                    errorType: "legacy_row_error",
                    message: reason ?? "unknown"
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

    private func summaryToRunMetrics(_ summary: [String: Any]) -> BenchmarkRunMetrics {
        let skippedFromDetails = [
            readInt(summary, keys: ["skipped_missing_audio", "skippedMissingAudio"]),
            readInt(summary, keys: ["skipped_invalid_audio", "skippedInvalidAudio"]),
            readInt(summary, keys: ["skipped_missing_reference_transcript", "skippedMissingReferenceTranscript"]),
            readInt(summary, keys: ["skipped_missing_context", "skippedMissingContext"]),
            readInt(summary, keys: ["skipped_too_short_audio", "skippedTooShortAudio"]),
            readInt(summary, keys: ["skipped_low_label_confidence", "skippedLowLabelConfidence"]),
        ].compactMap { $0 }.reduce(0, +)

        let skipped = readInt(summary, keys: ["skipped_cases", "skippedCases"]) ?? skippedFromDetails
        let failed = readInt(summary, keys: ["failed_cases", "failedCases", "failed_runs", "failedRuns"]) ?? 0

        return BenchmarkRunMetrics(
            casesTotal: readInt(summary, keys: ["cases_total", "casesTotal"]) ?? 0,
            casesSelected: readInt(summary, keys: ["cases_selected", "casesSelected"]) ?? 0,
            executedCases: readInt(summary, keys: ["executed_cases", "executedCases"]) ?? 0,
            skippedCases: skipped,
            failedCases: failed,
            cachedHits: readInt(summary, keys: ["cached_hits", "cachedHits"]) ?? 0,
            exactMatchRate: readDouble(summary, keys: ["exact_match_rate", "exactMatchRate"]),
            avgCER: readDouble(summary, keys: ["avg_cer", "avgCER"]),
            weightedCER: readDouble(summary, keys: ["weighted_cer", "weightedCER"]),
            avgTermsF1: readDouble(summary, keys: ["avg_terms_f1", "avgTermsF1"]),
            intentMatchRate: readDouble(summary, keys: ["intent_match_rate", "intentMatchRate"]),
            intentAvgScore: readDouble(summary, keys: ["intent_avg_score_0_4", "intentAvgScore"]),
            latencyMs: BenchmarkLatencyDistribution(avg: readDouble(summary, keys: ["avg_latency_ms", "avgLatencyMs", "avg_stt_total_ms", "avgSttTotalMs"])),
            afterStopLatencyMs: BenchmarkLatencyDistribution(avg: readDouble(summary, keys: ["avg_after_stop_ms", "avgAfterStopMs", "avg_stt_after_stop_ms", "avgSttAfterStopMs"])),
            postLatencyMs: BenchmarkLatencyDistribution(avg: readDouble(summary, keys: ["avg_post_ms", "avgPostMs"])),
            totalAfterStopLatencyMs: BenchmarkLatencyDistribution(avg: readDouble(summary, keys: ["avg_total_after_stop_ms", "avgTotalAfterStopMs"]))
        )
    }

    private func decodeCaseStatus(_ raw: String?) -> BenchmarkCaseStatus {
        switch raw {
        case "ok":
            return .ok
        case let value where value?.hasPrefix("skipped_") == true:
            return .skipped
        default:
            return .error
        }
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

    private func readString(_ json: [String: Any], key: String) -> String? {
        if let value = json[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func readString(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = readString(json, key: key) {
                return value
            }
        }
        return nil
    }

    private func readInt(_ json: [String: Any], key: String) -> Int? {
        if let value = json[key] as? Int {
            return value
        }
        if let value = json[key] as? Double {
            return Int(value)
        }
        if let value = json[key] as? String,
           let parsed = Int(value)
        {
            return parsed
        }
        return nil
    }

    private func readInt(_ json: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = readInt(json, key: key) {
                return value
            }
        }
        return nil
    }

    private func readDouble(_ json: [String: Any], key: String) -> Double? {
        if let value = json[key] as? Double {
            return value
        }
        if let value = json[key] as? Int {
            return Double(value)
        }
        if let value = json[key] as? String,
           let parsed = Double(value)
        {
            return parsed
        }
        return nil
    }

    private func readDouble(_ json: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = readDouble(json, key: key) {
                return value
            }
        }
        return nil
    }

    private func readBool(_ json: [String: Any], key: String) -> Bool? {
        if let value = json[key] as? Bool {
            return value
        }
        if let value = json[key] as? String {
            switch value.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func readBool(_ json: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = readBool(json, key: key) {
                return value
            }
        }
        return nil
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
