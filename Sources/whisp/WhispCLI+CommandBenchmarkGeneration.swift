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
        print("benchmark_log_dir: \(logPaths.baseDir)")
        print("")
        print("id\tstatus\tcached\texact_match\tcer\tpost_ms\toutput_chars")

        var executed = 0
        var skipped = 0
        var failed = 0
        var cachedHits = 0
        var exactCount = 0
        var cerValues: [Double] = []
        var totalEdits = 0
        var totalRefChars = 0
        var postLatencies: [Double] = []

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

                executed += 1
                if exact { exactCount += 1 }
                cerValues.append(cer)
                totalEdits += edit
                totalRefChars += refChars.count
                postLatencies.append(generation.postMs)

                print("\(item.id)\tok\t\(generation.cached)\t\(exact)\t\(String(format: "%.3f", cer))\t\(msString(generation.postMs))\t\(outChars.count)")
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
                        postMs: nil,
                        outputChars: nil
                    ),
                    to: rowHandle
                )
            }
        }

        let exactRate = executed > 0 ? Double(exactCount) / Double(executed) : 0
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
            avgLatencyMs: postLatencies.isEmpty ? nil : postLatencies.reduce(0, +) / Double(postLatencies.count),
            avgAfterStopMs: nil,
            avgTermsF1: nil
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
        print("avg_post_ms: \(summary.avgLatencyMs.map(msString) ?? "n/a")")
        print("case_rows_log: \(logPaths.rowsPath)")
        print("summary_log: \(logPaths.summaryPath)")

        _ = importLegacyBenchmarkLogs(
            kind: .generation,
            rowsPath: logPaths.rowsPath,
            summaryPath: logPaths.summaryPath,
            logDirectoryPath: logPaths.baseDir,
            options: BenchmarkRunOptions(
                sourceCasesPath: options.jsonlPath,
                requireContext: options.requireContext,
                useCache: options.useCache,
                llmModel: model.rawValue,
                caseLimit: options.limit
            )
        )
    }

}
