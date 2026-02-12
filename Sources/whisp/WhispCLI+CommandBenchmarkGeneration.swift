import Foundation
import WhispCore

extension WhispCLI {
    static func runGenerationCaseBenchmark(options: GenerationBenchmarkOptions) async throws {
        let config = try loadConfig()
        let resolved = options.modelOverride ?? config.llmModel
        let model = APIKeyResolver.effectivePostProcessModel(resolved)
        let apiKey = try APIKeyResolver.llmKey(config: config, model: model)
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases = options.limit.map { Array(allCases.prefix($0)) } ?? allCases
        let runID = defaultBenchmarkRunID(kind: .generation)
        let benchmarkWorkers = resolveBenchmarkWorkers(options.benchmarkWorkers)

        print("mode: generation_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("model: \(model.rawValue)")
        print("require_context: \(options.requireContext)")
        print("use_cache: \(options.useCache)")
        print("llm_eval: \(options.llmEvalEnabled)")
        print("llm_eval_model: \(options.llmEvalModel?.rawValue ?? "auto")")
        print("benchmark_workers: \(benchmarkWorkers)")
        print("")
        print("id\tstatus\tcached\texact_match\tcer\tpost_ms\toutput_chars\tintent_preservation\thallucination_rate")

        let runOptions = BenchmarkRunOptions(
            sourceCasesPath: options.jsonlPath,
            datasetHash: options.datasetHash,
            runtimeOptionsHash: options.runtimeOptionsHash,
            evaluatorVersion: options.evaluatorVersion,
            codeVersion: options.codeVersion,
            candidateID: options.candidateID,
            requireContext: options.requireContext,
            useCache: options.useCache,
            llmEvalEnabled: options.llmEvalEnabled,
            llmEvalModel: options.llmEvalModel?.rawValue,
            llmModel: model.rawValue,
            caseLimit: options.limit
        )
        let recorder = try BenchmarkRunRecorder(
            runID: runID,
            kind: .generation,
            options: runOptions,
            candidateID: options.candidateID,
            benchmarkKey: options.benchmarkKey,
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
        var exactCount = 0
        var cerValues: [Double] = []
        var totalEdits = 0
        var totalRefChars = 0
        var postLatencies: [Double] = []
        var llmEvalContext: (model: LLMModel, apiKey: String)?
        var llmEvalUnavailableReason: String?
        var resolvedLLMEvalModel: String?
        var llmEvalEvaluatedCases = 0
        var llmEvalErrorCases = 0
        var intentPreservationValues: [Double] = []
        var hallucinationScoreValues: [Double] = []
        var hallucinationRateValues: [Double] = []

        for item in selectedCases {
            try recorder.markCaseQueued(caseID: item.id)
        }

        if benchmarkWorkers > 1 {
            let outcomes = try await runGenerationCaseBenchmarkWithWorkers(
                runID: runID,
                selectedCases: selectedCases,
                options: options,
                config: config,
                model: model,
                apiKey: apiKey,
                recorder: recorder
            )
            for outcome in outcomes {
                print(outcome.displayLine)
                executed += outcome.executed
                skipped += outcome.skipped
                failed += outcome.failed
                cachedHits += outcome.cachedHits
                exactCount += outcome.exactCount
                if let cer = outcome.cer {
                    cerValues.append(cer)
                }
                totalEdits += outcome.totalEdits
                totalRefChars += outcome.totalRefChars
                if let postMs = outcome.postMs {
                    postLatencies.append(postMs)
                }
                if let ips = outcome.intentPreservationScore {
                    intentPreservationValues.append(ips)
                }
                if let hs = outcome.hallucinationScore {
                    hallucinationScoreValues.append(hs)
                }
                if let hr = outcome.hallucinationRate {
                    hallucinationRateValues.append(hr)
                }
                llmEvalEvaluatedCases += outcome.llmEvalEvaluatedCases
                llmEvalErrorCases += outcome.llmEvalErrorCases
                if llmEvalUnavailableReason == nil, let note = outcome.llmEvalUnavailableReason {
                    llmEvalUnavailableReason = note
                }
                if resolvedLLMEvalModel == nil, let used = outcome.resolvedLLMEvalModel {
                    resolvedLLMEvalModel = used
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

            guard let input = item.resolvedGenerationInputSTT() else {
                skipped += 1
                print("\(item.id)\tskipped_missing_input_stt\tfalse\t-\t-\t-\t-")

                let status: BenchmarkCaseStatus = .skipped
                let caseResult = BenchmarkCaseResult(
                    id: item.id,
                    status: status,
                    reason: "stt入力がありません",
                    cache: BenchmarkCacheRecord(hit: false, namespace: "generation"),
                    sources: BenchmarkReferenceSources(),
                    contextUsed: item.context != nil,
                    visionImageAttached: item.visionImageFile != nil,
                    metrics: BenchmarkCaseMetrics()
                )
                caseResults.append(caseResult)

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
                    sources: BenchmarkReferenceSources(),
                    contextPresent: item.context != nil,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
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
            guard let reference = item.resolvedGenerationReferenceText() else {
                skipped += 1
                print("\(item.id)\tskipped_missing_reference\tfalse\t-\t-\t-\t-")

                let status: BenchmarkCaseStatus = .skipped
                let sources = BenchmarkReferenceSources(input: input.source)
                caseResults.append(BenchmarkCaseResult(
                    id: item.id,
                    status: status,
                    reason: "参照テキストがありません",
                    cache: BenchmarkCacheRecord(hit: false, namespace: "generation"),
                    sources: sources,
                    contextUsed: item.context != nil,
                    visionImageAttached: item.visionImageFile != nil,
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
                    sources: sources,
                    contextPresent: item.context != nil,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
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
            if options.requireContext, item.context == nil {
                skipped += 1
                print("\(item.id)\tskipped_missing_context\tfalse\t-\t-\t-\t-")

                let status: BenchmarkCaseStatus = .skipped
                let sources = BenchmarkReferenceSources(input: input.source, reference: reference.source)
                caseResults.append(BenchmarkCaseResult(
                    id: item.id,
                    status: status,
                    reason: "--require-context が指定されています",
                    cache: BenchmarkCacheRecord(hit: false, namespace: "generation"),
                    sources: sources,
                    contextUsed: false,
                    visionImageAttached: item.visionImageFile != nil,
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
                    sources: sources,
                    contextPresent: false,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
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

            let sources = BenchmarkReferenceSources(input: input.source, reference: reference.source)

            do {
                let contextHash = sha256Hex(text: canonicalContextString(item.context))
                let inputHash = sha256Hex(text: input.text)
                let cacheKey = sha256Hex(text: "generation-v1|\(model.rawValue)|\(config.inputLanguage)|\(inputHash)|\(contextHash)")
                let loadEndedAtMs = nowEpochMs()
                let cacheStartedAtMs = nowEpochMs()
                var cacheEndedAtMs = cacheStartedAtMs
                var generationStartedAtMs = cacheStartedAtMs
                var generationEndedAtMs = cacheStartedAtMs
                let generation: (output: String, postMs: Double, cached: Bool)
                if options.useCache,
                   let cached: CachedGenerationResult = loadCacheEntry(component: "generation", key: cacheKey)
                {
                    cacheEndedAtMs = nowEpochMs()
                    generationStartedAtMs = cacheEndedAtMs
                    generationEndedAtMs = nowEpochMs()
                    generation = (cached.output, cached.postMs, true)
                    cachedHits += 1
                } else {
                    cacheEndedAtMs = nowEpochMs()
                    generationStartedAtMs = nowEpochMs()
                    let startedAt = DispatchTime.now()
                    let result = try await postProcessText(
                        model: model,
                        apiKey: apiKey,
                        config: config,
                        sttText: input.text,
                        context: item.context,
                        sttMode: "generation_benchmark"
                    )
                    let postMs = elapsedMs(since: startedAt)
                    generationEndedAtMs = nowEpochMs()
                    generation = (result.text, postMs, false)
                    if options.useCache {
                        let cache = CachedGenerationResult(
                            key: cacheKey,
                            model: model.rawValue,
                            output: result.text,
                            postMs: postMs,
                            createdAt: ISO8601DateFormatter().string(from: Date())
                        )
                        try saveCacheEntry(component: "generation", key: cacheKey, value: cache)
                    }
                }

                let refChars = Array(normalizedEvalText(reference.text))
                let outChars = Array(normalizedEvalText(generation.output))
                let edit = levenshteinDistance(refChars, outChars)
                let cer = Double(edit) / Double(max(1, refChars.count))
                let exact = normalizedEvalText(reference.text) == normalizedEvalText(generation.output)
                var intentPreservationScore: Double?
                var hallucinationScore: Double?
                var hallucinationRate: Double?
                var llmEvalError: String?
                var judgeStartedAtMs: Int64?
                var judgeEndedAtMs: Int64?

                if options.llmEvalEnabled {
                    if llmEvalContext == nil, llmEvalUnavailableReason == nil {
                        do {
                            llmEvalContext = try APIKeyResolver.resolveIntentJudgeContext(
                                config: config,
                                preferredModel: options.llmEvalModel
                            )
                        } catch {
                            llmEvalUnavailableReason = error.localizedDescription
                        }
                    }
                    if let llmEvalContext {
                        judgeStartedAtMs = nowEpochMs()
                        do {
                            let evaluation = try await runLLMEvaluation(
                                model: llmEvalContext.model,
                                apiKey: llmEvalContext.apiKey,
                                referenceText: reference.text,
                                hypothesisText: generation.output,
                                context: item.context
                            )
                            intentPreservationScore = evaluation.intentPreservationScore
                            hallucinationScore = evaluation.hallucinationScore
                            hallucinationRate = evaluation.hallucinationRate
                            llmEvalEvaluatedCases += 1
                            intentPreservationValues.append(evaluation.intentPreservationScore)
                            hallucinationScoreValues.append(evaluation.hallucinationScore)
                            hallucinationRateValues.append(evaluation.hallucinationRate)
                        } catch {
                            llmEvalError = error.localizedDescription
                            llmEvalErrorCases += 1
                        }
                        judgeEndedAtMs = nowEpochMs()
                    } else if let reason = llmEvalUnavailableReason {
                        judgeStartedAtMs = nowEpochMs()
                        llmEvalError = reason
                        llmEvalErrorCases += 1
                        judgeEndedAtMs = nowEpochMs()
                    }
                }

                executed += 1
                if exact { exactCount += 1 }
                cerValues.append(cer)
                totalEdits += edit
                totalRefChars += refChars.count
                postLatencies.append(generation.postMs)

                print("\(item.id)\tok\t\(generation.cached)\t\(exact)\t\(String(format: "%.3f", cer))\t\(msString(generation.postMs))\t\(outChars.count)\t\(intentPreservationScore.map { String(format: "%.3f", $0) } ?? "-")\t\(hallucinationRate.map { String(format: "%.3f", $0) } ?? "-")")

                let status: BenchmarkCaseStatus = .ok
                caseResults.append(BenchmarkCaseResult(
                    id: item.id,
                    status: status,
                    reason: nil,
                    cache: BenchmarkCacheRecord(hit: generation.cached, key: cacheKey, namespace: "generation"),
                    sources: sources,
                    contextUsed: item.context != nil,
                    visionImageAttached: item.visionImageFile != nil,
                    metrics: BenchmarkCaseMetrics(
                        exactMatch: exact,
                        cer: cer,
                        intentPreservationScore: intentPreservationScore,
                        hallucinationScore: hallucinationScore,
                        hallucinationRate: hallucinationRate,
                        postMs: generation.postMs,
                        outputChars: outChars.count
                    )
                ))
                try recorder.writeCaseIOText(caseID: item.id, fileName: "input_stt.txt", text: input.text)
                try recorder.writeCaseIOText(caseID: item.id, fileName: "output_generation.txt", text: generation.output)
                try recorder.writeCaseIOText(caseID: item.id, fileName: "reference.txt", text: reference.text)

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
                    sources: sources,
                    contextPresent: item.context != nil,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
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
                    namespace: "generation",
                    key: cacheKey,
                    hit: generation.cached,
                    keyMaterialRef: nil,
                    error: nil
                )))

                let generationBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .generation,
                    status: .ok,
                    startedAtMs: generationStartedAtMs,
                    endedAtMs: generationEndedAtMs
                )
                events.append(.generation(BenchmarkGenerationLog(
                    base: generationBase,
                    model: model.rawValue,
                    inputChars: input.text.count,
                    outputChars: outChars.count,
                    postMs: generation.postMs,
                    promptRef: nil,
                    responseRef: nil,
                    error: nil
                )))

                if intentPreservationScore != nil || hallucinationScore != nil || hallucinationRate != nil || llmEvalError != nil {
                    let judgeStatus: BenchmarkEventStatus = llmEvalError == nil ? .ok : .error
                    let judgeBase = makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .judge,
                        status: judgeStatus,
                        startedAtMs: judgeStartedAtMs ?? generationEndedAtMs,
                        endedAtMs: judgeEndedAtMs ?? nowEpochMs()
                    )
                    events.append(.judge(BenchmarkJudgeLog(
                        base: judgeBase,
                        model: llmEvalContext?.model.rawValue ?? options.llmEvalModel?.rawValue,
                        match: nil,
                        score: nil,
                        intentPreservationScore: intentPreservationScore,
                        hallucinationScore: hallucinationScore,
                        hallucinationRate: hallucinationRate,
                        requestRef: nil,
                        responseRef: nil,
                        error: llmEvalError
                    )))
                }

                let aggregateBase = makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .aggregate,
                    status: .ok,
                    startedAtMs: judgeEndedAtMs ?? generationEndedAtMs,
                    endedAtMs: nowEpochMs()
                )
                events.append(.aggregate(BenchmarkAggregateLog(
                    base: aggregateBase,
                    exactMatch: exact,
                    cer: cer,
                    intentMatch: nil,
                    intentScore: nil,
                    intentPreservationScore: intentPreservationScore,
                    hallucinationScore: hallucinationScore,
                    hallucinationRate: hallucinationRate,
                    latencyMs: nil,
                    totalAfterStopMs: nil,
                    outputChars: outChars.count
                )))
            } catch {
                failed += 1
                print("\(item.id)\terror\tfalse\t-\t-\t-\t-")

                let status: BenchmarkCaseStatus = .error
                let message = error.localizedDescription
                caseResults.append(BenchmarkCaseResult(
                    id: item.id,
                    status: status,
                    reason: message,
                    cache: BenchmarkCacheRecord(hit: false, namespace: "generation"),
                    sources: sources,
                    contextUsed: item.context != nil,
                    visionImageAttached: item.visionImageFile != nil,
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
                    sources: sources,
                    contextPresent: item.context != nil,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
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
                    originStage: .generation,
                    errorType: "generation_case_error",
                    message: message
                )))
            }
        }
        }

        let exactRate = executed > 0 ? Double(exactCount) / Double(executed) : 0
        let postDistribution = latencyDistribution(values: postLatencies)

        let metrics = BenchmarkRunMetrics(
            casesTotal: allCases.count,
            casesSelected: selectedCases.count,
            executedCases: executed,
            skippedCases: skipped,
            failedCases: failed,
            cachedHits: cachedHits,
            exactMatchRate: exactRate,
            avgCER: cerValues.isEmpty ? nil : cerValues.reduce(0, +) / Double(cerValues.count),
            weightedCER: totalRefChars > 0 ? Double(totalEdits) / Double(totalRefChars) : nil,
            avgTermsF1: nil,
            intentMatchRate: nil,
            intentAvgScore: nil,
            intentPreservationScore: intentPreservationValues.isEmpty ? nil : intentPreservationValues.reduce(0, +) / Double(intentPreservationValues.count),
            hallucinationScore: hallucinationScoreValues.isEmpty ? nil : hallucinationScoreValues.reduce(0, +) / Double(hallucinationScoreValues.count),
            hallucinationRate: hallucinationRateValues.isEmpty ? nil : hallucinationRateValues.reduce(0, +) / Double(hallucinationRateValues.count),
            latencyMs: nil,
            afterStopLatencyMs: nil,
            postLatencyMs: toBenchmarkLatencyDistribution(postDistribution),
            totalAfterStopLatencyMs: nil
        )

        let finalRunOptions = BenchmarkRunOptions(
            sourceCasesPath: options.jsonlPath,
            datasetHash: options.datasetHash,
            runtimeOptionsHash: options.runtimeOptionsHash,
            evaluatorVersion: options.evaluatorVersion,
            codeVersion: options.codeVersion,
            candidateID: options.candidateID,
            requireContext: options.requireContext,
            useCache: options.useCache,
            llmEvalEnabled: options.llmEvalEnabled,
            llmEvalModel: resolvedLLMEvalModel ?? llmEvalContext?.model.rawValue ?? options.llmEvalModel?.rawValue,
            llmModel: model.rawValue,
            caseLimit: options.limit
        )
        if let persistenceError {
            _ = try? recorder.finalize(metrics: metrics, options: finalRunOptions, status: .failed)
            throw persistenceError
        }
        let run = try recorder.finalize(metrics: metrics, options: finalRunOptions, status: .completed)

        print("")
        print("summary")
        print("executed_cases: \(executed)")
        print("skipped_cases: \(skipped)")
        print("failed_cases: \(failed)")
        print("cached_hits: \(cachedHits)")
        print("exact_match_rate: \(String(format: "%.3f", exactRate))")
        print("avg_cer: \(metrics.avgCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("weighted_cer: \(metrics.weightedCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        if let post = metrics.postLatencyMs {
            print("post_ms: avg=\(post.avg.map(msString) ?? "n/a") p50=\(post.p50.map(msString) ?? "n/a") p95=\(post.p95.map(msString) ?? "n/a") p99=\(post.p99.map(msString) ?? "n/a")")
        } else {
            print("post_ms: n/a")
        }
        print("llm_eval_evaluated_cases: \(llmEvalEvaluatedCases)")
        print("llm_eval_error_cases: \(llmEvalErrorCases)")
        print("intent_preservation_score: \(metrics.intentPreservationScore.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("hallucination_score: \(metrics.hallucinationScore.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("hallucination_rate: \(metrics.hallucinationRate.map { String(format: "%.3f", $0) } ?? "n/a")")
        if let llmEvalUnavailableReason {
            print("llm_eval_note: \(llmEvalUnavailableReason)")
        }
        print("benchmark_run_id: \(run.id)")
        print("benchmark_manifest: \(benchmarkManifestPath(runID: run.id))")
    }

    private struct GenerationCaseIOWrite: Sendable {
        let fileName: String
        let text: String
    }

    private struct GenerationCaseWorkerOutcome: Sendable {
        let displayLine: String
        let result: BenchmarkCaseResult
        let events: [BenchmarkCaseEvent]
        let ioWrites: [GenerationCaseIOWrite]
        let executed: Int
        let skipped: Int
        let failed: Int
        let cachedHits: Int
        let exactCount: Int
        let cer: Double?
        let totalEdits: Int
        let totalRefChars: Int
        let postMs: Double?
        let intentPreservationScore: Double?
        let hallucinationScore: Double?
        let hallucinationRate: Double?
        let llmEvalEvaluatedCases: Int
        let llmEvalErrorCases: Int
        let llmEvalUnavailableReason: String?
        let resolvedLLMEvalModel: String?
    }

    private static func runGenerationCaseBenchmarkWithWorkers(
        runID: String,
        selectedCases: [ManualBenchmarkCase],
        options: GenerationBenchmarkOptions,
        config: Config,
        model: LLMModel,
        apiKey: String,
        recorder: BenchmarkRunRecorder
    ) async throws -> [GenerationCaseWorkerOutcome] {
        try await runBenchmarkCaseWorkers(cases: selectedCases, workers: options.benchmarkWorkers) { _, item in
            try recorder.markCaseStarted(caseID: item.id)
            return await executeGenerationCaseBenchmarkWorker(
                runID: runID,
                item: item,
                options: options,
                config: config,
                model: model,
                apiKey: apiKey
            )
        }
    }

    private static func executeGenerationCaseBenchmarkWorker(
        runID: String,
        item: ManualBenchmarkCase,
        options: GenerationBenchmarkOptions,
        config: Config,
        model: LLMModel,
        apiKey: String
    ) async -> GenerationCaseWorkerOutcome {
        let caseStartedAtMs = nowEpochMs()

        guard let input = item.resolvedGenerationInputSTT() else {
            let status: BenchmarkCaseStatus = .skipped
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: "stt入力がありません",
                cache: BenchmarkCacheRecord(hit: false, namespace: "generation"),
                sources: BenchmarkReferenceSources(),
                contextUsed: item.context != nil,
                visionImageAttached: item.visionImageFile != nil,
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
                    sources: BenchmarkReferenceSources(),
                    contextPresent: item.context != nil,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
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
            return GenerationCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_input_stt\tfalse\t-\t-\t-\t-",
                result: result,
                events: events,
                ioWrites: [],
                executed: 0,
                skipped: 1,
                failed: 0,
                cachedHits: 0,
                exactCount: 0,
                cer: nil,
                totalEdits: 0,
                totalRefChars: 0,
                postMs: nil,
                intentPreservationScore: nil,
                hallucinationScore: nil,
                hallucinationRate: nil,
                llmEvalEvaluatedCases: 0,
                llmEvalErrorCases: 0,
                llmEvalUnavailableReason: nil,
                resolvedLLMEvalModel: nil
            )
        }
        guard let reference = item.resolvedGenerationReferenceText() else {
            let status: BenchmarkCaseStatus = .skipped
            let sources = BenchmarkReferenceSources(input: input.source)
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: "参照テキストがありません",
                cache: BenchmarkCacheRecord(hit: false, namespace: "generation"),
                sources: sources,
                contextUsed: item.context != nil,
                visionImageAttached: item.visionImageFile != nil,
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
                    sources: sources,
                    contextPresent: item.context != nil,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
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
            return GenerationCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_reference\tfalse\t-\t-\t-\t-",
                result: result,
                events: events,
                ioWrites: [],
                executed: 0,
                skipped: 1,
                failed: 0,
                cachedHits: 0,
                exactCount: 0,
                cer: nil,
                totalEdits: 0,
                totalRefChars: 0,
                postMs: nil,
                intentPreservationScore: nil,
                hallucinationScore: nil,
                hallucinationRate: nil,
                llmEvalEvaluatedCases: 0,
                llmEvalErrorCases: 0,
                llmEvalUnavailableReason: nil,
                resolvedLLMEvalModel: nil
            )
        }
        if options.requireContext, item.context == nil {
            let status: BenchmarkCaseStatus = .skipped
            let sources = BenchmarkReferenceSources(input: input.source, reference: reference.source)
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: "--require-context が指定されています",
                cache: BenchmarkCacheRecord(hit: false, namespace: "generation"),
                sources: sources,
                contextUsed: false,
                visionImageAttached: item.visionImageFile != nil,
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
                    sources: sources,
                    contextPresent: false,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
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
            return GenerationCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_context\tfalse\t-\t-\t-\t-",
                result: result,
                events: events,
                ioWrites: [],
                executed: 0,
                skipped: 1,
                failed: 0,
                cachedHits: 0,
                exactCount: 0,
                cer: nil,
                totalEdits: 0,
                totalRefChars: 0,
                postMs: nil,
                intentPreservationScore: nil,
                hallucinationScore: nil,
                hallucinationRate: nil,
                llmEvalEvaluatedCases: 0,
                llmEvalErrorCases: 0,
                llmEvalUnavailableReason: nil,
                resolvedLLMEvalModel: nil
            )
        }

        let sources = BenchmarkReferenceSources(input: input.source, reference: reference.source)
        do {
            let contextHash = sha256Hex(text: canonicalContextString(item.context))
            let inputHash = sha256Hex(text: input.text)
            let cacheKey = sha256Hex(text: "generation-v1|\(model.rawValue)|\(config.inputLanguage)|\(inputHash)|\(contextHash)")
            let loadEndedAtMs = nowEpochMs()
            let cacheStartedAtMs = nowEpochMs()
            var cacheEndedAtMs = cacheStartedAtMs
            var generationStartedAtMs = cacheStartedAtMs
            var generationEndedAtMs = cacheStartedAtMs

            var cachedHits = 0
            let generation: (output: String, postMs: Double, cached: Bool)
            if options.useCache,
               let cached: CachedGenerationResult = loadCacheEntry(component: "generation", key: cacheKey)
            {
                cacheEndedAtMs = nowEpochMs()
                generationStartedAtMs = cacheEndedAtMs
                generationEndedAtMs = nowEpochMs()
                generation = (cached.output, cached.postMs, true)
                cachedHits = 1
            } else {
                cacheEndedAtMs = nowEpochMs()
                generationStartedAtMs = nowEpochMs()
                let startedAt = DispatchTime.now()
                let result = try await postProcessText(
                    model: model,
                    apiKey: apiKey,
                    config: config,
                    sttText: input.text,
                    context: item.context,
                    sttMode: "generation_benchmark"
                )
                let postMs = elapsedMs(since: startedAt)
                generationEndedAtMs = nowEpochMs()
                generation = (result.text, postMs, false)
                if options.useCache {
                    let cache = CachedGenerationResult(
                        key: cacheKey,
                        model: model.rawValue,
                        output: result.text,
                        postMs: postMs,
                        createdAt: ISO8601DateFormatter().string(from: Date())
                    )
                    try saveCacheEntry(component: "generation", key: cacheKey, value: cache)
                }
            }

            let refChars = Array(normalizedEvalText(reference.text))
            let outChars = Array(normalizedEvalText(generation.output))
            let edit = levenshteinDistance(refChars, outChars)
            let cer = Double(edit) / Double(max(1, refChars.count))
            let exact = normalizedEvalText(reference.text) == normalizedEvalText(generation.output)

            var intentPreservationScore: Double?
            var hallucinationScore: Double?
            var hallucinationRate: Double?
            var llmEvalError: String?
            var llmEvalUnavailableReason: String?
            var resolvedLLMEvalModel: String?
            var llmEvalEvaluatedCases = 0
            var llmEvalErrorCases = 0
            var judgeStartedAtMs: Int64?
            var judgeEndedAtMs: Int64?

            if options.llmEvalEnabled {
                do {
                    let judgeContext = try APIKeyResolver.resolveIntentJudgeContext(
                        config: config,
                        preferredModel: options.llmEvalModel
                    )
                    resolvedLLMEvalModel = judgeContext.model.rawValue
                    judgeStartedAtMs = nowEpochMs()
                    do {
                        let evaluation = try await runLLMEvaluation(
                            model: judgeContext.model,
                            apiKey: judgeContext.apiKey,
                            referenceText: reference.text,
                            hypothesisText: generation.output,
                            context: item.context
                        )
                        intentPreservationScore = evaluation.intentPreservationScore
                        hallucinationScore = evaluation.hallucinationScore
                        hallucinationRate = evaluation.hallucinationRate
                        llmEvalEvaluatedCases = 1
                    } catch {
                        llmEvalError = error.localizedDescription
                        llmEvalErrorCases = 1
                    }
                    judgeEndedAtMs = nowEpochMs()
                } catch {
                    llmEvalUnavailableReason = error.localizedDescription
                    llmEvalError = error.localizedDescription
                    llmEvalErrorCases = 1
                    judgeStartedAtMs = nowEpochMs()
                    judgeEndedAtMs = nowEpochMs()
                }
            }

            let status: BenchmarkCaseStatus = .ok
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: nil,
                cache: BenchmarkCacheRecord(hit: generation.cached, key: cacheKey, namespace: "generation"),
                sources: sources,
                contextUsed: item.context != nil,
                visionImageAttached: item.visionImageFile != nil,
                metrics: BenchmarkCaseMetrics(
                    exactMatch: exact,
                    cer: cer,
                    intentPreservationScore: intentPreservationScore,
                    hallucinationScore: hallucinationScore,
                    hallucinationRate: hallucinationRate,
                    postMs: generation.postMs,
                    outputChars: outChars.count
                )
            )

            var events: [BenchmarkCaseEvent] = [
                .loadCase(BenchmarkLoadCaseLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .loadCase,
                        status: .ok,
                        startedAtMs: caseStartedAtMs,
                        endedAtMs: loadEndedAtMs
                    ),
                    sources: sources,
                    contextPresent: item.context != nil,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
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
                    namespace: "generation",
                    key: cacheKey,
                    hit: generation.cached,
                    keyMaterialRef: nil,
                    error: nil
                )),
                .generation(BenchmarkGenerationLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .generation,
                        status: .ok,
                        startedAtMs: generationStartedAtMs,
                        endedAtMs: generationEndedAtMs
                    ),
                    model: model.rawValue,
                    inputChars: input.text.count,
                    outputChars: outChars.count,
                    postMs: generation.postMs,
                    promptRef: nil,
                    responseRef: nil,
                    error: nil
                )),
            ]
            if intentPreservationScore != nil || hallucinationScore != nil || hallucinationRate != nil || llmEvalError != nil {
                let judgeStatus: BenchmarkEventStatus = llmEvalError == nil ? .ok : .error
                events.append(.judge(BenchmarkJudgeLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .judge,
                        status: judgeStatus,
                        startedAtMs: judgeStartedAtMs ?? generationEndedAtMs,
                        endedAtMs: judgeEndedAtMs ?? nowEpochMs()
                    ),
                    model: resolvedLLMEvalModel ?? options.llmEvalModel?.rawValue,
                    match: nil,
                    score: nil,
                    intentPreservationScore: intentPreservationScore,
                    hallucinationScore: hallucinationScore,
                    hallucinationRate: hallucinationRate,
                    requestRef: nil,
                    responseRef: nil,
                    error: llmEvalError
                )))
            }
            events.append(.aggregate(BenchmarkAggregateLog(
                base: makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .aggregate,
                    status: .ok,
                    startedAtMs: judgeEndedAtMs ?? generationEndedAtMs,
                    endedAtMs: nowEpochMs()
                ),
                exactMatch: exact,
                cer: cer,
                intentMatch: nil,
                intentScore: nil,
                intentPreservationScore: intentPreservationScore,
                hallucinationScore: hallucinationScore,
                hallucinationRate: hallucinationRate,
                latencyMs: nil,
                totalAfterStopMs: nil,
                outputChars: outChars.count
            )))

            return GenerationCaseWorkerOutcome(
                displayLine: "\(item.id)\tok\t\(generation.cached)\t\(exact)\t\(String(format: "%.3f", cer))\t\(msString(generation.postMs))\t\(outChars.count)\t\(intentPreservationScore.map { String(format: "%.3f", $0) } ?? "-")\t\(hallucinationRate.map { String(format: "%.3f", $0) } ?? "-")",
                result: result,
                events: events,
                ioWrites: [
                    GenerationCaseIOWrite(fileName: "input_stt.txt", text: input.text),
                    GenerationCaseIOWrite(fileName: "output_generation.txt", text: generation.output),
                    GenerationCaseIOWrite(fileName: "reference.txt", text: reference.text),
                ],
                executed: 1,
                skipped: 0,
                failed: 0,
                cachedHits: cachedHits,
                exactCount: exact ? 1 : 0,
                cer: cer,
                totalEdits: edit,
                totalRefChars: refChars.count,
                postMs: generation.postMs,
                intentPreservationScore: intentPreservationScore,
                hallucinationScore: hallucinationScore,
                hallucinationRate: hallucinationRate,
                llmEvalEvaluatedCases: llmEvalEvaluatedCases,
                llmEvalErrorCases: llmEvalErrorCases,
                llmEvalUnavailableReason: llmEvalUnavailableReason,
                resolvedLLMEvalModel: resolvedLLMEvalModel
            )
        } catch {
            let status: BenchmarkCaseStatus = .error
            let message = error.localizedDescription
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: message,
                cache: BenchmarkCacheRecord(hit: false, namespace: "generation"),
                sources: sources,
                contextUsed: item.context != nil,
                visionImageAttached: item.visionImageFile != nil,
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
                    sources: sources,
                    contextPresent: item.context != nil,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
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
                    originStage: .generation,
                    errorType: "generation_case_error",
                    message: message
                )),
            ]
            return GenerationCaseWorkerOutcome(
                displayLine: "\(item.id)\terror\tfalse\t-\t-\t-\t-",
                result: result,
                events: events,
                ioWrites: [],
                executed: 0,
                skipped: 0,
                failed: 1,
                cachedHits: 0,
                exactCount: 0,
                cer: nil,
                totalEdits: 0,
                totalRefChars: 0,
                postMs: nil,
                intentPreservationScore: nil,
                hallucinationScore: nil,
                hallucinationRate: nil,
                llmEvalEvaluatedCases: 0,
                llmEvalErrorCases: 0,
                llmEvalUnavailableReason: nil,
                resolvedLLMEvalModel: nil
            )
        }
    }
}
