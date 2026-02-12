import Foundation
import WhispCore

extension WhispCLI {
    static func runVisionCaseBenchmark(options: VisionBenchmarkOptions) async throws {
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases = options.limit.map { Array(allCases.prefix($0)) } ?? allCases
        let runID = defaultBenchmarkRunID(kind: .vision)
        let benchmarkWorkers = resolveBenchmarkWorkers(options.benchmarkWorkers)

        let modeLabel = VisionContextMode.ocr.rawValue

        print("mode: vision_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("use_cache: \(options.useCache)")
        print("benchmark_workers: \(benchmarkWorkers)")
        print("vision_mode: \(modeLabel)")
        print("")
        print("id\tstatus\tcached\tsummary_cer\tterms_f1\tlatency_ms")

        let runOptions = BenchmarkRunOptions.vision(BenchmarkVisionRunOptions(
            common: BenchmarkRunCommonOptions(
                sourceCasesPath: options.jsonlPath,
                caseLimit: options.limit,
                useCache: options.useCache
            )
        ))
        let recorder = try BenchmarkRunRecorder(
            runID: runID,
            kind: .vision,
            options: runOptions,
            initialMetrics: .vision(BenchmarkVisionRunMetrics(
                counts: BenchmarkRunCounts(
                    casesTotal: allCases.count,
                    casesSelected: selectedCases.count,
                    executedCases: 0,
                    skippedCases: 0,
                    failedCases: 0,
                    cachedHits: 0
                )
            ))
        )

        let accumulator = VisionOutcomeAccumulator()
        let lifecycle = try await executeBenchmarkRunLifecycle(
            selectedCases: selectedCases,
            recorder: recorder
        ) {
            try await runVisionCaseBenchmarkWithWorkers(
                runID: runID,
                modeLabel: modeLabel,
                selectedCases: selectedCases,
                options: options,
                recorder: recorder
            ) { outcome in
                try await accumulator.consume(outcome, recorder: recorder)
            }
        } snapshotSummary: {
            await accumulator.snapshot()
        } makeMetrics: { summary in
            makeVisionRunMetrics(
                allCasesCount: allCases.count,
                selectedCasesCount: selectedCases.count,
                summary: summary
            )
        } makeRunOptions: { _ in
            runOptions
        }

        let summary = lifecycle.summary
        let metrics = lifecycle.metrics
        let run = lifecycle.run

        print("")
        print("summary")
        print("executed_cases: \(summary.executed)")
        print("skipped_cases: \(summary.skipped)")
        print("failed_cases: \(summary.failed)")
        print("cached_hits: \(summary.cachedHits)")
        print("avg_summary_cer: \(metrics.avgCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("avg_terms_f1: \(metrics.avgTermsF1.map { String(format: "%.3f", $0) } ?? "n/a")")
        if let latency = metrics.latencyMs {
            print("vision_latency_ms: avg=\(latency.avg.map(msString) ?? "n/a") p50=\(latency.p50.map(msString) ?? "n/a") p95=\(latency.p95.map(msString) ?? "n/a") p99=\(latency.p99.map(msString) ?? "n/a")")
        } else {
            print("vision_latency_ms: n/a")
        }
        print("benchmark_run_id: \(run.id)")
        print("benchmark_manifest: \(benchmarkManifestPath(runID: run.id))")
    }

    private struct VisionCaseIOWrite: Sendable {
        let fileName: String
        let text: String
    }

    private struct VisionCaseWorkerOutcome: Sendable {
        let displayLine: String
        let result: BenchmarkCaseResult
        let events: [BenchmarkCaseEvent]
        let ioWrites: [VisionCaseIOWrite]
        let executed: Int
        let skipped: Int
        let failed: Int
        let cachedHits: Int
        let summaryCER: Double?
        let termsF1: Double?
        let latencyMs: Double?
    }

    private struct VisionOutcomeSummary: Sendable {
        var executed = 0
        var skipped = 0
        var failed = 0
        var cachedHits = 0
        var summaryCERs: [Double] = []
        var termsF1s: [Double] = []
        var latencies: [Double] = []
    }

    private actor VisionOutcomeAccumulator {
        private var summary = VisionOutcomeSummary()

        func consume(_ outcome: VisionCaseWorkerOutcome, recorder: BenchmarkRunRecorder) throws {
            print(outcome.displayLine)
            summary.executed += outcome.executed
            summary.skipped += outcome.skipped
            summary.failed += outcome.failed
            summary.cachedHits += outcome.cachedHits
            if let value = outcome.summaryCER {
                summary.summaryCERs.append(value)
            }
            if let value = outcome.termsF1 {
                summary.termsF1s.append(value)
            }
            if let value = outcome.latencyMs {
                summary.latencies.append(value)
            }

            try recorder.appendCaseResult(outcome.result)
            try recorder.appendEvents(outcome.events)
            for write in outcome.ioWrites {
                try recorder.writeCaseIOText(caseID: outcome.result.id, fileName: write.fileName, text: write.text)
            }
        }

        func snapshot() -> VisionOutcomeSummary {
            summary
        }
    }

    private static func makeVisionRunMetrics(
        allCasesCount: Int,
        selectedCasesCount: Int,
        summary: VisionOutcomeSummary
    ) -> BenchmarkRunMetrics {
        .vision(BenchmarkVisionRunMetrics(
            counts: BenchmarkRunCounts(
                casesTotal: allCasesCount,
                casesSelected: selectedCasesCount,
                executedCases: summary.executed,
                skippedCases: summary.skipped,
                failedCases: summary.failed,
                cachedHits: summary.cachedHits
            ),
            avgCER: summary.summaryCERs.isEmpty ? nil : summary.summaryCERs.reduce(0, +) / Double(summary.summaryCERs.count),
            avgTermsF1: summary.termsF1s.isEmpty ? nil : summary.termsF1s.reduce(0, +) / Double(summary.termsF1s.count),
            latencyMs: toBenchmarkLatencyDistribution(latencyDistribution(values: summary.latencies))
        ))
    }

    private static func runVisionCaseBenchmarkWithWorkers(
        runID: String,
        modeLabel: String,
        selectedCases: [ManualBenchmarkCase],
        options: VisionBenchmarkOptions,
        recorder: BenchmarkRunRecorder,
        onOutcome: @escaping @Sendable (VisionCaseWorkerOutcome) async throws -> Void
    ) async throws {
        try await runBenchmarkCaseWorkers(
            cases: selectedCases,
            workers: options.benchmarkWorkers
        ) { _, item in
            try recorder.markCaseStarted(caseID: item.id)
            return await executeVisionCaseBenchmarkWorker(
                runID: runID,
                modeLabel: modeLabel,
                item: item,
                options: options
            )
        } onResult: { outcome in
            try await onOutcome(outcome)
        }
    }

    private static func executeVisionCaseBenchmarkWorker(
        runID: String,
        modeLabel: String,
        item: ManualBenchmarkCase,
        options: VisionBenchmarkOptions
    ) async -> VisionCaseWorkerOutcome {
        let sourceInfo = BenchmarkReferenceSources(reference: "context.vision")
        let caseStartedAtMs = nowEpochMs()

        guard let imagePath = item.visionImageFile, !imagePath.isEmpty else {
            let artifacts = makeSkippedCaseArtifacts(
                runID: runID,
                caseID: item.id,
                caseStartedAtMs: caseStartedAtMs,
                reason: "vision_image_file がありません",
                cacheNamespace: "vision",
                sources: sourceInfo,
                contextPresent: item.context != nil,
                visionImagePresent: false,
                audioFilePath: nil
            )
            return VisionCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_image\tfalse\t-\t-\t-",
                result: artifacts.result,
                events: artifacts.events,
                ioWrites: [],
                executed: 0,
                skipped: 1,
                failed: 0,
                cachedHits: 0,
                summaryCER: nil,
                termsF1: nil,
                latencyMs: nil
            )
        }

        guard FileManager.default.fileExists(atPath: imagePath) else {
            let artifacts = makeSkippedCaseArtifacts(
                runID: runID,
                caseID: item.id,
                caseStartedAtMs: caseStartedAtMs,
                reason: "画像ファイルが見つかりません: \(imagePath)",
                cacheNamespace: "vision",
                sources: sourceInfo,
                contextPresent: item.context != nil,
                visionImagePresent: false,
                audioFilePath: nil
            )
            return VisionCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_image_not_found\tfalse\t-\t-\t-",
                result: artifacts.result,
                events: artifacts.events,
                ioWrites: [],
                executed: 0,
                skipped: 1,
                failed: 0,
                cachedHits: 0,
                summaryCER: nil,
                termsF1: nil,
                latencyMs: nil
            )
        }

        guard let ref = item.resolvedVisionReference() else {
            let artifacts = makeSkippedCaseArtifacts(
                runID: runID,
                caseID: item.id,
                caseStartedAtMs: caseStartedAtMs,
                reason: "context.visionSummary/visionTerms がありません",
                cacheNamespace: "vision",
                sources: sourceInfo,
                contextPresent: item.context != nil,
                visionImagePresent: true,
                audioFilePath: nil
            )
            return VisionCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_reference_context\tfalse\t-\t-\t-",
                result: artifacts.result,
                events: artifacts.events,
                ioWrites: [],
                executed: 0,
                skipped: 1,
                failed: 0,
                cachedHits: 0,
                summaryCER: nil,
                termsF1: nil,
                latencyMs: nil
            )
        }

        do {
            let imageData = try Data(contentsOf: URL(fileURLWithPath: imagePath))
            let imageHash = sha256Hex(data: imageData)
            let cacheKey = sha256Hex(text: "vision-v2|\(modeLabel)|\(imageHash)")
            let loadEndedAtMs = nowEpochMs()
            let cacheStartedAtMs = nowEpochMs()
            var cacheEndedAtMs = cacheStartedAtMs
            var contextStartedAtMs = cacheStartedAtMs
            var contextEndedAtMs = cacheStartedAtMs

            var cachedHits = 0
            let output: (summary: String, terms: [String], latencyMs: Double, cached: Bool)
            if options.useCache,
               let cached: CachedVisionResult = loadCacheEntry(component: "vision", key: cacheKey)
            {
                cacheEndedAtMs = nowEpochMs()
                contextStartedAtMs = cacheEndedAtMs
                contextEndedAtMs = nowEpochMs()
                output = (cached.summary, cached.terms, cached.latencyMs, true)
                cachedHits = 1
            } else {
                cacheEndedAtMs = nowEpochMs()
                contextStartedAtMs = nowEpochMs()
                let startedAt = DispatchTime.now()
                let context = try analyzeVisionContextOCR(imageData: imageData)
                let latency = elapsedMs(since: startedAt)
                contextEndedAtMs = nowEpochMs()
                output = (
                    (context?.visionSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    context?.visionTerms ?? [],
                    latency,
                    false
                )
                if options.useCache {
                    let cache = CachedVisionResult(
                        key: cacheKey,
                        model: modeLabel,
                        summary: output.summary,
                        terms: output.terms,
                        latencyMs: output.latencyMs,
                        createdAt: WhispTime.isoNow()
                    )
                    try saveCacheEntry(component: "vision", key: cacheKey, value: cache)
                }
            }

            let summaryCER: Double
            if ref.summary.isEmpty, output.summary.isEmpty {
                summaryCER = 0
            } else {
                let left = Array(normalizedEvalText(ref.summary))
                let right = Array(normalizedEvalText(output.summary))
                let edit = levenshteinDistance(left, right)
                summaryCER = Double(edit) / Double(max(1, left.count))
            }
            let termScore = termSetScore(reference: ref.terms, hypothesis: output.terms)

            let status: BenchmarkCaseStatus = .ok
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: nil,
                cache: BenchmarkCacheRecord(hit: output.cached, key: cacheKey, namespace: "vision"),
                sources: sourceInfo,
                contextUsed: item.context != nil,
                visionImageAttached: true,
                metrics: BenchmarkCaseMetrics(
                    cer: summaryCER,
                    termPrecision: termScore.precision,
                    termRecall: termScore.recall,
                    termF1: termScore.f1,
                    latencyMs: output.latencyMs
                )
            )

            let events: [BenchmarkCaseEvent] = [
                .loadCase(BenchmarkLoadCaseLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .loadCase,
                        status: .ok,
                        startedAtMs: caseStartedAtMs,
                        endedAtMs: loadEndedAtMs
                    ),
                    sources: sourceInfo,
                    contextPresent: item.context != nil,
                    visionImagePresent: true,
                    audioFilePath: nil,
                    rawRowRef: nil
                )),
                .cache(BenchmarkCacheLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .cache,
                        status: .ok,
                        startedAtMs: cacheStartedAtMs,
                        endedAtMs: cacheEndedAtMs
                    ),
                    namespace: "vision",
                    key: cacheKey,
                    hit: output.cached,
                    keyMaterialRef: nil,
                    error: nil
                )),
                .context(BenchmarkContextLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .context,
                        status: .ok,
                        startedAtMs: contextStartedAtMs,
                        endedAtMs: contextEndedAtMs
                    ),
                    contextPresent: true,
                    sourceChars: nil,
                    summaryChars: output.summary.count,
                    termsCount: output.terms.count,
                    rawContextRef: nil,
                    error: nil
                )),
                .aggregate(BenchmarkAggregateLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .aggregate,
                        status: .ok,
                        startedAtMs: contextEndedAtMs,
                        endedAtMs: nowEpochMs()
                    ),
                    exactMatch: nil,
                    cer: summaryCER,
                    intentMatch: nil,
                    intentScore: nil,
                    intentPreservationScore: nil,
                    hallucinationScore: nil,
                    hallucinationRate: nil,
                    latencyMs: output.latencyMs,
                    totalAfterStopMs: nil,
                    outputChars: output.summary.count
                )),
            ]

            return VisionCaseWorkerOutcome(
                displayLine: "\(item.id)\tok\t\(output.cached)\t\(String(format: "%.3f", summaryCER))\t\(String(format: "%.3f", termScore.f1))\t\(msString(output.latencyMs))",
                result: result,
                events: events,
                ioWrites: [
                    VisionCaseIOWrite(fileName: "output_vision_summary.txt", text: output.summary),
                    VisionCaseIOWrite(fileName: "reference.txt", text: ref.summary),
                ],
                executed: 1,
                skipped: 0,
                failed: 0,
                cachedHits: cachedHits,
                summaryCER: summaryCER,
                termsF1: termScore.f1,
                latencyMs: output.latencyMs
            )
        } catch {
            let status: BenchmarkCaseStatus = .error
            let message = error.localizedDescription
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: message,
                cache: BenchmarkCacheRecord(hit: false, namespace: "vision"),
                sources: sourceInfo,
                contextUsed: item.context != nil,
                visionImageAttached: true,
                metrics: BenchmarkCaseMetrics()
            )
            let loadEndedAtMs = nowEpochMs()
            let events: [BenchmarkCaseEvent] = [
                .loadCase(BenchmarkLoadCaseLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .loadCase,
                        status: .ok,
                        startedAtMs: caseStartedAtMs,
                        endedAtMs: loadEndedAtMs
                    ),
                    sources: sourceInfo,
                    contextPresent: item.context != nil,
                    visionImagePresent: true,
                    audioFilePath: nil,
                    rawRowRef: nil
                )),
                .aggregate(BenchmarkAggregateLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .aggregate,
                        status: .error,
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
                .error(BenchmarkErrorLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .error,
                        status: .error,
                        startedAtMs: loadEndedAtMs,
                        endedAtMs: nowEpochMs()
                    ),
                    originStage: nil,
                    errorType: "vision_case_error",
                    message: message
                )),
            ]

            return VisionCaseWorkerOutcome(
                displayLine: "\(item.id)\terror\tfalse\t-\t-\t-",
                result: result,
                events: events,
                ioWrites: [],
                executed: 0,
                skipped: 0,
                failed: 1,
                cachedHits: 0,
                summaryCER: nil,
                termsF1: nil,
                latencyMs: nil
            )
        }
    }
}
