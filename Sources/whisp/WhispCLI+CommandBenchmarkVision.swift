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

        let runOptions = BenchmarkRunOptions(
            sourceCasesPath: options.jsonlPath,
            useCache: options.useCache,
            caseLimit: options.limit
        )
        let recorder = try BenchmarkRunRecorder(
            runID: runID,
            kind: .vision,
            options: runOptions,
            initialMetrics: BenchmarkRunMetrics(
                casesTotal: allCases.count,
                casesSelected: selectedCases.count,
                executedCases: 0,
                skippedCases: 0,
                failedCases: 0,
                cachedHits: 0
            )
        )

        var caseResults: [BenchmarkCaseResult] = []
        var events: [BenchmarkCaseEvent] = []
        var persistenceError: Error?

        var executed = 0
        var skipped = 0
        var failed = 0
        var cachedHits = 0
        var summaryCERs: [Double] = []
        var termsF1s: [Double] = []
        var latencies: [Double] = []

        for item in selectedCases {
            try recorder.markCaseQueued(caseID: item.id)
        }

        if benchmarkWorkers > 1 {
            let outcomes = try await runVisionCaseBenchmarkWithWorkers(
                runID: runID,
                modeLabel: modeLabel,
                selectedCases: selectedCases,
                options: options,
                recorder: recorder
            )
            for outcome in outcomes {
                print(outcome.displayLine)
                executed += outcome.executed
                skipped += outcome.skipped
                failed += outcome.failed
                cachedHits += outcome.cachedHits
                if let summaryCER = outcome.summaryCER {
                    summaryCERs.append(summaryCER)
                }
                if let termsF1 = outcome.termsF1 {
                    termsF1s.append(termsF1)
                }
                if let latencyMs = outcome.latencyMs {
                    latencies.append(latencyMs)
                }
                try recorder.appendCaseResult(outcome.result)
                try recorder.appendEvents(outcome.events)
                for write in outcome.ioWrites {
                    try recorder.writeCaseIOText(caseID: outcome.result.id, fileName: write.fileName, text: write.text)
                }
            }
        } else {
            for item in selectedCases {
            try recorder.markCaseStarted(caseID: item.id)
            let caseStartedAtMs = nowEpochMs()
            let caseStartIndex = caseResults.count
            let eventStartIndex = events.count
            defer {
                defer {
                    caseResults.removeSubrange(caseStartIndex..<caseResults.count)
                    events.removeSubrange(eventStartIndex..<events.count)
                }
                if persistenceError == nil {
                    do {
                        if caseResults.count > caseStartIndex {
                            for result in caseResults[caseStartIndex...] {
                                try recorder.appendCaseResult(result)
                            }
                        }
                        if events.count > eventStartIndex {
                            try recorder.appendEvents(Array(events[eventStartIndex...]))
                        }
                    } catch {
                        persistenceError = error
                    }
                }
            }
            let sourceInfo = BenchmarkReferenceSources(reference: "context.vision")

            guard let imagePath = item.visionImageFile, !imagePath.isEmpty else {
                skipped += 1
                print("\(item.id)\tskipped_missing_image\tfalse\t-\t-\t-")

                let status: BenchmarkCaseStatus = .skipped
                caseResults.append(BenchmarkCaseResult(
                    id: item.id,
                    status: status,
                    reason: "vision_image_file がありません",
                    cache: BenchmarkCacheRecord(hit: false, namespace: "vision"),
                    sources: sourceInfo,
                    contextUsed: item.context != nil,
                    visionImageAttached: false,
                    metrics: BenchmarkCaseMetrics()
                ))

                let loadEndedAtMs = nowEpochMs()
                let loadBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .loadCase,
                    status: .ok,
                    startedAtMs: caseStartedAtMs,
                    endedAtMs: loadEndedAtMs
                )
                events.append(.loadCase(BenchmarkLoadCaseLog(
                    base: loadBase,
                    sources: sourceInfo,
                    contextPresent: item.context != nil,
                    visionImagePresent: false,
                    audioFilePath: nil,
                    rawRowRef: nil
                )))

                let aggregateBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .aggregate,
                    status: .skipped,
                    startedAtMs: loadEndedAtMs,
                    endedAtMs: nowEpochMs()
                )
                events.append(.aggregate(BenchmarkAggregateLog(
                    base: aggregateBase,
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
                )))
                continue
            }
            guard FileManager.default.fileExists(atPath: imagePath) else {
                skipped += 1
                print("\(item.id)\tskipped_image_not_found\tfalse\t-\t-\t-")

                let status: BenchmarkCaseStatus = .skipped
                caseResults.append(BenchmarkCaseResult(
                    id: item.id,
                    status: status,
                    reason: "画像ファイルが見つかりません: \(imagePath)",
                    cache: BenchmarkCacheRecord(hit: false, namespace: "vision"),
                    sources: sourceInfo,
                    contextUsed: item.context != nil,
                    visionImageAttached: false,
                    metrics: BenchmarkCaseMetrics()
                ))

                let loadEndedAtMs = nowEpochMs()
                let loadBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .loadCase,
                    status: .ok,
                    startedAtMs: caseStartedAtMs,
                    endedAtMs: loadEndedAtMs
                )
                events.append(.loadCase(BenchmarkLoadCaseLog(
                    base: loadBase,
                    sources: sourceInfo,
                    contextPresent: item.context != nil,
                    visionImagePresent: false,
                    audioFilePath: nil,
                    rawRowRef: nil
                )))

                let aggregateBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .aggregate,
                    status: .skipped,
                    startedAtMs: loadEndedAtMs,
                    endedAtMs: nowEpochMs()
                )
                events.append(.aggregate(BenchmarkAggregateLog(
                    base: aggregateBase,
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
                )))
                continue
            }
            guard let ref = item.resolvedVisionReference() else {
                skipped += 1
                print("\(item.id)\tskipped_missing_reference_context\tfalse\t-\t-\t-")

                let status: BenchmarkCaseStatus = .skipped
                caseResults.append(BenchmarkCaseResult(
                    id: item.id,
                    status: status,
                    reason: "context.visionSummary/visionTerms がありません",
                    cache: BenchmarkCacheRecord(hit: false, namespace: "vision"),
                    sources: sourceInfo,
                    contextUsed: item.context != nil,
                    visionImageAttached: true,
                    metrics: BenchmarkCaseMetrics()
                ))

                let loadEndedAtMs = nowEpochMs()
                let loadBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .loadCase,
                    status: .ok,
                    startedAtMs: caseStartedAtMs,
                    endedAtMs: loadEndedAtMs
                )
                events.append(.loadCase(BenchmarkLoadCaseLog(
                    base: loadBase,
                    sources: sourceInfo,
                    contextPresent: item.context != nil,
                    visionImagePresent: true,
                    audioFilePath: nil,
                    rawRowRef: nil
                )))

                let aggregateBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .aggregate,
                    status: .skipped,
                    startedAtMs: loadEndedAtMs,
                    endedAtMs: nowEpochMs()
                )
                events.append(.aggregate(BenchmarkAggregateLog(
                    base: aggregateBase,
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
                )))
                continue
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

                let output: (summary: String, terms: [String], latencyMs: Double, cached: Bool)
                if options.useCache,
                   let cached: CachedVisionResult = loadCacheEntry(component: "vision", key: cacheKey)
                {
                    cacheEndedAtMs = nowEpochMs()
                    contextStartedAtMs = cacheEndedAtMs
                    contextEndedAtMs = nowEpochMs()
                    output = (cached.summary, cached.terms, cached.latencyMs, true)
                    cachedHits += 1
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
                            createdAt: ISO8601DateFormatter().string(from: Date())
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

                executed += 1
                summaryCERs.append(summaryCER)
                termsF1s.append(termScore.f1)
                latencies.append(output.latencyMs)

                print("\(item.id)\tok\t\(output.cached)\t\(String(format: "%.3f", summaryCER))\t\(String(format: "%.3f", termScore.f1))\t\(msString(output.latencyMs))")

                let status: BenchmarkCaseStatus = .ok
                caseResults.append(BenchmarkCaseResult(
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
                ))
                try recorder.writeCaseIOText(caseID: item.id, fileName: "output_vision_summary.txt", text: output.summary)
                try recorder.writeCaseIOText(caseID: item.id, fileName: "reference.txt", text: ref.summary)

                let loadBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .loadCase,
                    status: .ok,
                    startedAtMs: caseStartedAtMs,
                    endedAtMs: loadEndedAtMs
                )
                events.append(.loadCase(BenchmarkLoadCaseLog(
                    base: loadBase,
                    sources: sourceInfo,
                    contextPresent: item.context != nil,
                    visionImagePresent: true,
                    audioFilePath: nil,
                    rawRowRef: nil
                )))

                let cacheBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .cache,
                    status: .ok,
                    startedAtMs: cacheStartedAtMs,
                    endedAtMs: cacheEndedAtMs
                )
                events.append(.cache(BenchmarkCacheLog(
                    base: cacheBase,
                    namespace: "vision",
                    key: cacheKey,
                    hit: output.cached,
                    keyMaterialRef: nil,
                    error: nil
                )))

                let contextBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .context,
                    status: .ok,
                    startedAtMs: contextStartedAtMs,
                    endedAtMs: contextEndedAtMs
                )
                events.append(.context(BenchmarkContextLog(
                    base: contextBase,
                    contextPresent: true,
                    sourceChars: nil,
                    summaryChars: output.summary.count,
                    termsCount: output.terms.count,
                    rawContextRef: nil,
                    error: nil
                )))

                let aggregateBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .aggregate,
                    status: .ok,
                    startedAtMs: contextEndedAtMs,
                    endedAtMs: nowEpochMs()
                )
                events.append(.aggregate(BenchmarkAggregateLog(
                    base: aggregateBase,
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
                )))
            } catch {
                failed += 1
                print("\(item.id)\terror\tfalse\t-\t-\t-")

                let status: BenchmarkCaseStatus = .error
                let message = error.localizedDescription
                caseResults.append(BenchmarkCaseResult(
                    id: item.id,
                    status: status,
                    reason: message,
                    cache: BenchmarkCacheRecord(hit: false, namespace: "vision"),
                    sources: sourceInfo,
                    contextUsed: item.context != nil,
                    visionImageAttached: true,
                    metrics: BenchmarkCaseMetrics()
                ))

                let loadEndedAtMs = nowEpochMs()
                let loadBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .loadCase,
                    status: .ok,
                    startedAtMs: caseStartedAtMs,
                    endedAtMs: loadEndedAtMs
                )
                events.append(.loadCase(BenchmarkLoadCaseLog(
                    base: loadBase,
                    sources: sourceInfo,
                    contextPresent: item.context != nil,
                    visionImagePresent: true,
                    audioFilePath: nil,
                    rawRowRef: nil
                )))

                let aggregateBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .aggregate,
                    status: .error,
                    startedAtMs: loadEndedAtMs,
                    endedAtMs: nowEpochMs()
                )
                events.append(.aggregate(BenchmarkAggregateLog(
                    base: aggregateBase,
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
                )))

                let errorBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .error,
                    status: .error,
                    startedAtMs: loadEndedAtMs,
                    endedAtMs: nowEpochMs()
                )
                events.append(.error(BenchmarkErrorLog(
                    base: errorBase,
                    originStage: nil,
                    errorType: "vision_case_error",
                    message: message
                )))
            }
        }
        }

        let metrics = BenchmarkRunMetrics(
            casesTotal: allCases.count,
            casesSelected: selectedCases.count,
            executedCases: executed,
            skippedCases: skipped,
            failedCases: failed,
            cachedHits: cachedHits,
            exactMatchRate: nil,
            avgCER: summaryCERs.isEmpty ? nil : summaryCERs.reduce(0, +) / Double(summaryCERs.count),
            weightedCER: nil,
            avgTermsF1: termsF1s.isEmpty ? nil : termsF1s.reduce(0, +) / Double(termsF1s.count),
            intentMatchRate: nil,
            intentAvgScore: nil,
            intentPreservationScore: nil,
            hallucinationScore: nil,
            hallucinationRate: nil,
            latencyMs: toBenchmarkLatencyDistribution(latencyDistribution(values: latencies)),
            afterStopLatencyMs: nil,
            postLatencyMs: nil,
            totalAfterStopLatencyMs: nil
        )

        if let persistenceError {
            _ = try? recorder.finalize(metrics: metrics, options: runOptions, status: .failed)
            throw persistenceError
        }
        let run = try recorder.finalize(metrics: metrics, options: runOptions, status: .completed)

        print("")
        print("summary")
        print("executed_cases: \(executed)")
        print("skipped_cases: \(skipped)")
        print("failed_cases: \(failed)")
        print("cached_hits: \(cachedHits)")
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

    private static func runVisionCaseBenchmarkWithWorkers(
        runID: String,
        modeLabel: String,
        selectedCases: [ManualBenchmarkCase],
        options: VisionBenchmarkOptions,
        recorder: BenchmarkRunRecorder
    ) async throws -> [VisionCaseWorkerOutcome] {
        try await runBenchmarkCaseWorkers(cases: selectedCases, workers: options.benchmarkWorkers) { _, item in
            try recorder.markCaseStarted(caseID: item.id)
            return await executeVisionCaseBenchmarkWorker(
                runID: runID,
                modeLabel: modeLabel,
                item: item,
                options: options
            )
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
            let status: BenchmarkCaseStatus = .skipped
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: "vision_image_file がありません",
                cache: BenchmarkCacheRecord(hit: false, namespace: "vision"),
                sources: sourceInfo,
                contextUsed: item.context != nil,
                visionImageAttached: false,
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
                    visionImagePresent: false,
                    audioFilePath: nil,
                    rawRowRef: nil
                )),
                .aggregate(BenchmarkAggregateLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
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
            return VisionCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_image\tfalse\t-\t-\t-",
                result: result,
                events: events,
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
            let status: BenchmarkCaseStatus = .skipped
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: "画像ファイルが見つかりません: \(imagePath)",
                cache: BenchmarkCacheRecord(hit: false, namespace: "vision"),
                sources: sourceInfo,
                contextUsed: item.context != nil,
                visionImageAttached: false,
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
                    visionImagePresent: false,
                    audioFilePath: nil,
                    rawRowRef: nil
                )),
                .aggregate(BenchmarkAggregateLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
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
            return VisionCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_image_not_found\tfalse\t-\t-\t-",
                result: result,
                events: events,
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
            let status: BenchmarkCaseStatus = .skipped
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: "context.visionSummary/visionTerms がありません",
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
            return VisionCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_reference_context\tfalse\t-\t-\t-",
                result: result,
                events: events,
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
                        createdAt: ISO8601DateFormatter().string(from: Date())
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
