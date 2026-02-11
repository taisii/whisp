import Foundation
import WhispCore

extension WhispCLI {
    static func runGenerationCaseBenchmark(options: GenerationBenchmarkOptions) async throws {
        let config = try loadConfig()
        let model = APIKeyResolver.effectivePostProcessModel(config.llmModel)
        let apiKey = try APIKeyResolver.llmKey(config: config, model: model)
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases = options.limit.map { Array(allCases.prefix($0)) } ?? allCases
        let logPaths = try prepareComponentBenchmarkLogPaths(
            customDir: options.benchmarkLogDir,
            defaultPrefix: "whisp-generationbench",
            rowsFilename: "generation_case_rows.jsonl",
            summaryFilename: "generation_summary.json"
        )
        let rowHandle = try openWriteHandle(path: logPaths.rowsPath)
        defer { try? rowHandle.close() }

        print("mode: generation_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("model: \(model.rawValue)")
        print("require_context: \(options.requireContext)")
        print("use_cache: \(options.useCache)")
        print("llm_eval: \(options.llmEvalEnabled)")
        print("llm_eval_model: \(options.llmEvalModel?.rawValue ?? "auto")")
        print("benchmark_log_dir: \(logPaths.baseDir)")
        print("")
        print("id\tstatus\tcached\texact_match\tcer\tpost_ms\toutput_chars\tintent_preservation\thallucination_rate")

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
        var llmEvalEvaluatedCases = 0
        var llmEvalErrorCases = 0
        var intentPreservationValues: [Double] = []
        var hallucinationScoreValues: [Double] = []
        var hallucinationRateValues: [Double] = []

        for item in selectedCases {
            guard let input = item.resolvedGenerationInputSTT() else {
                skipped += 1
                print("\(item.id)\tskipped_missing_input_stt\tfalse\t-\t-\t-\t-")
                try appendJSONLine(
                    GenerationCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_input_stt",
                        reason: "stt入力がありません",
                        cached: false,
                        inputSource: nil,
                        referenceSource: nil,
                        exactMatch: nil,
                        cer: nil,
                        postMs: nil,
                        outputChars: nil
                    ),
                    to: rowHandle
                )
                continue
            }
            guard let reference = item.resolvedGenerationReferenceText() else {
                skipped += 1
                print("\(item.id)\tskipped_missing_reference\tfalse\t-\t-\t-\t-")
                try appendJSONLine(
                    GenerationCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_reference",
                        reason: "参照テキストがありません",
                        cached: false,
                        inputSource: input.source,
                        referenceSource: nil,
                        exactMatch: nil,
                        cer: nil,
                        postMs: nil,
                        outputChars: nil
                    ),
                    to: rowHandle
                )
                continue
            }
            if options.requireContext, item.context == nil {
                skipped += 1
                print("\(item.id)\tskipped_missing_context\tfalse\t-\t-\t-\t-")
                try appendJSONLine(
                    GenerationCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_context",
                        reason: "--require-context が指定されています",
                        cached: false,
                        inputSource: input.source,
                        referenceSource: reference.source,
                        exactMatch: nil,
                        cer: nil,
                        postMs: nil,
                        outputChars: nil
                    ),
                    to: rowHandle
                )
                continue
            }

            do {
                let contextHash = sha256Hex(text: canonicalContextString(item.context))
                let inputHash = sha256Hex(text: input.text)
                let cacheKey = sha256Hex(text: "generation-v1|\(model.rawValue)|\(config.inputLanguage)|\(inputHash)|\(contextHash)")
                let generation: (output: String, postMs: Double, cached: Bool)
                if options.useCache,
                   let cached: CachedGenerationResult = loadCacheEntry(component: "generation", key: cacheKey)
                {
                    generation = (cached.output, cached.postMs, true)
                    cachedHits += 1
                } else {
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
                    } else if let reason = llmEvalUnavailableReason {
                        llmEvalError = reason
                        llmEvalErrorCases += 1
                    }
                }

                executed += 1
                if exact { exactCount += 1 }
                cerValues.append(cer)
                totalEdits += edit
                totalRefChars += refChars.count
                postLatencies.append(generation.postMs)

                print("\(item.id)\tok\t\(generation.cached)\t\(exact)\t\(String(format: "%.3f", cer))\t\(msString(generation.postMs))\t\(outChars.count)\t\(intentPreservationScore.map { String(format: "%.3f", $0) } ?? "-")\t\(hallucinationRate.map { String(format: "%.3f", $0) } ?? "-")")
                try appendJSONLine(
                    GenerationCaseLogRow(
                        id: item.id,
                        status: "ok",
                        reason: nil,
                        cached: generation.cached,
                        inputSource: input.source,
                        referenceSource: reference.source,
                        exactMatch: exact,
                        cer: cer,
                        intentPreservationScore: intentPreservationScore,
                        hallucinationScore: hallucinationScore,
                        hallucinationRate: hallucinationRate,
                        llmEvalError: llmEvalError,
                        postMs: generation.postMs,
                        outputChars: outChars.count
                    ),
                    to: rowHandle
                )
            } catch {
                failed += 1
                print("\(item.id)\terror\tfalse\t-\t-\t-\t-")
                try appendJSONLine(
                    GenerationCaseLogRow(
                        id: item.id,
                        status: "error",
                        reason: error.localizedDescription,
                        cached: false,
                        inputSource: input.source,
                        referenceSource: reference.source,
                        exactMatch: nil,
                        cer: nil,
                        intentPreservationScore: nil,
                        hallucinationScore: nil,
                        hallucinationRate: nil,
                        llmEvalError: nil,
                        postMs: nil,
                        outputChars: nil
                    ),
                    to: rowHandle
                )
            }
        }

        let exactRate = executed > 0 ? Double(exactCount) / Double(executed) : 0
        let postDistribution = latencyDistribution(values: postLatencies)
        let summary = ComponentSummaryLog(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            benchmark: "generation",
            jsonlPath: options.jsonlPath,
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
            intentPreservationScore: intentPreservationValues.isEmpty ? nil : intentPreservationValues.reduce(0, +) / Double(intentPreservationValues.count),
            hallucinationScore: hallucinationScoreValues.isEmpty ? nil : hallucinationScoreValues.reduce(0, +) / Double(hallucinationScoreValues.count),
            hallucinationRate: hallucinationRateValues.isEmpty ? nil : hallucinationRateValues.reduce(0, +) / Double(hallucinationRateValues.count),
            llmEvalEnabled: options.llmEvalEnabled,
            llmEvalModel: llmEvalContext?.model.rawValue ?? options.llmEvalModel?.rawValue,
            llmEvalEvaluatedCases: llmEvalEvaluatedCases,
            llmEvalErrorCases: llmEvalErrorCases,
            latencyMs: nil,
            afterStopLatencyMs: nil,
            postLatencyMs: postDistribution,
            totalAfterStopLatencyMs: nil
        )
        try writeJSONFile(summary, path: logPaths.summaryPath)

        print("")
        print("summary")
        print("executed_cases: \(executed)")
        print("skipped_cases: \(skipped)")
        print("failed_cases: \(failed)")
        print("cached_hits: \(cachedHits)")
        print("exact_match_rate: \(String(format: "%.3f", exactRate))")
        print("avg_cer: \(summary.avgCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("weighted_cer: \(summary.weightedCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        if let post = summary.postLatencyMs {
            print("post_ms: avg=\(post.avg.map(msString) ?? "n/a") p50=\(post.p50.map(msString) ?? "n/a") p95=\(post.p95.map(msString) ?? "n/a") p99=\(post.p99.map(msString) ?? "n/a")")
        } else {
            print("post_ms: n/a")
        }
        print("llm_eval_evaluated_cases: \(summary.llmEvalEvaluatedCases)")
        print("llm_eval_error_cases: \(summary.llmEvalErrorCases)")
        print("intent_preservation_score: \(summary.intentPreservationScore.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("hallucination_score: \(summary.hallucinationScore.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("hallucination_rate: \(summary.hallucinationRate.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("case_rows_log: \(logPaths.rowsPath)")
        print("summary_log: \(logPaths.summaryPath)")
        if let llmEvalUnavailableReason {
            print("llm_eval_note: \(llmEvalUnavailableReason)")
        }

        _ = importLegacyBenchmarkLogs(
            kind: .generation,
            rowsPath: logPaths.rowsPath,
            summaryPath: logPaths.summaryPath,
            logDirectoryPath: logPaths.baseDir,
            options: BenchmarkRunOptions(
                sourceCasesPath: options.jsonlPath,
                requireContext: options.requireContext,
                useCache: options.useCache,
                llmEvalEnabled: options.llmEvalEnabled,
                llmEvalModel: llmEvalContext?.model.rawValue ?? options.llmEvalModel?.rawValue,
                llmModel: model.rawValue,
                caseLimit: options.limit
            )
        )
    }

}
