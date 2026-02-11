import Foundation
import WhispCore

extension WhispCLI {
    static func runVisionCaseBenchmark(options: VisionBenchmarkOptions) async throws {
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases = options.limit.map { Array(allCases.prefix($0)) } ?? allCases
        let logPaths = try prepareComponentBenchmarkLogPaths(
            customDir: options.benchmarkLogDir,
            defaultPrefix: "whisp-visionbench",
            rowsFilename: "vision_case_rows.jsonl",
            summaryFilename: "vision_summary.json"
        )
        let rowHandle = try openWriteHandle(path: logPaths.rowsPath)
        defer { try? rowHandle.close() }

        let modeLabel = VisionContextMode.ocr.rawValue

        print("mode: vision_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("use_cache: \(options.useCache)")
        print("vision_mode: \(modeLabel)")
        print("benchmark_log_dir: \(logPaths.baseDir)")
        print("")
        print("id\tstatus\tcached\tsummary_cer\tterms_f1\tlatency_ms")

        var executed = 0
        var skipped = 0
        var failed = 0
        var cachedHits = 0
        var summaryCERs: [Double] = []
        var termsF1s: [Double] = []
        var latencies: [Double] = []

        for item in selectedCases {
            guard let imagePath = item.visionImageFile, !imagePath.isEmpty else {
                skipped += 1
                print("\(item.id)\tskipped_missing_image\tfalse\t-\t-\t-")
                try appendJSONLine(
                    VisionCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_image",
                        reason: "vision_image_file がありません",
                        cached: false,
                        summaryCER: nil,
                        termsPrecision: nil,
                        termsRecall: nil,
                        termsF1: nil,
                        latencyMs: nil
                    ),
                    to: rowHandle
                )
                continue
            }
            guard FileManager.default.fileExists(atPath: imagePath) else {
                skipped += 1
                print("\(item.id)\tskipped_image_not_found\tfalse\t-\t-\t-")
                try appendJSONLine(
                    VisionCaseLogRow(
                        id: item.id,
                        status: "skipped_image_not_found",
                        reason: "画像ファイルが見つかりません: \(imagePath)",
                        cached: false,
                        summaryCER: nil,
                        termsPrecision: nil,
                        termsRecall: nil,
                        termsF1: nil,
                        latencyMs: nil
                    ),
                    to: rowHandle
                )
                continue
            }
            guard let ref = item.resolvedVisionReference() else {
                skipped += 1
                print("\(item.id)\tskipped_missing_reference_context\tfalse\t-\t-\t-")
                try appendJSONLine(
                    VisionCaseLogRow(
                        id: item.id,
                        status: "skipped_missing_reference_context",
                        reason: "context.visionSummary/visionTerms がありません",
                        cached: false,
                        summaryCER: nil,
                        termsPrecision: nil,
                        termsRecall: nil,
                        termsF1: nil,
                        latencyMs: nil
                    ),
                    to: rowHandle
                )
                continue
            }

            do {
                let imageData = try Data(contentsOf: URL(fileURLWithPath: imagePath))
                let imageHash = sha256Hex(data: imageData)
                let cacheKey = sha256Hex(text: "vision-v2|\(modeLabel)|\(imageHash)")

                let output: (summary: String, terms: [String], latencyMs: Double, cached: Bool)
                if options.useCache,
                   let cached: CachedVisionResult = loadCacheEntry(component: "vision", key: cacheKey)
                {
                    output = (cached.summary, cached.terms, cached.latencyMs, true)
                    cachedHits += 1
                } else {
                    let startedAt = DispatchTime.now()
                    let context = try analyzeVisionContextOCR(imageData: imageData)
                    let latency = elapsedMs(since: startedAt)
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
                try appendJSONLine(
                    VisionCaseLogRow(
                        id: item.id,
                        status: "ok",
                        reason: nil,
                        cached: output.cached,
                        summaryCER: summaryCER,
                        termsPrecision: termScore.precision,
                        termsRecall: termScore.recall,
                        termsF1: termScore.f1,
                        latencyMs: output.latencyMs
                    ),
                    to: rowHandle
                )
            } catch {
                failed += 1
                print("\(item.id)\terror\tfalse\t-\t-\t-")
                try appendJSONLine(
                    VisionCaseLogRow(
                        id: item.id,
                        status: "error",
                        reason: error.localizedDescription,
                        cached: false,
                        summaryCER: nil,
                        termsPrecision: nil,
                        termsRecall: nil,
                        termsF1: nil,
                        latencyMs: nil
                    ),
                    to: rowHandle
                )
            }
        }

        let summary = ComponentSummaryLog(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            benchmark: "vision",
            jsonlPath: options.jsonlPath,
            casesTotal: allCases.count,
            casesSelected: selectedCases.count,
            executedCases: executed,
            skippedCases: skipped,
            failedCases: failed,
            cachedHits: cachedHits,
            exactMatchRate: nil,
            avgCER: summaryCERs.isEmpty ? nil : summaryCERs.reduce(0, +) / Double(summaryCERs.count),
            weightedCER: nil,
            avgLatencyMs: latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count),
            avgAfterStopMs: nil,
            avgTermsF1: termsF1s.isEmpty ? nil : termsF1s.reduce(0, +) / Double(termsF1s.count)
        )
        try writeJSONFile(summary, path: logPaths.summaryPath)

        print("")
        print("summary")
        print("executed_cases: \(executed)")
        print("skipped_cases: \(skipped)")
        print("failed_cases: \(failed)")
        print("cached_hits: \(cachedHits)")
        print("avg_summary_cer: \(summary.avgCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("avg_terms_f1: \(summary.avgTermsF1.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("avg_latency_ms: \(summary.avgLatencyMs.map(msString) ?? "n/a")")
        print("case_rows_log: \(logPaths.rowsPath)")
        print("summary_log: \(logPaths.summaryPath)")

        _ = importLegacyBenchmarkLogs(
            kind: .vision,
            rowsPath: logPaths.rowsPath,
            summaryPath: logPaths.summaryPath,
            logDirectoryPath: logPaths.baseDir,
            options: BenchmarkRunOptions(
                sourceCasesPath: options.jsonlPath,
                useCache: options.useCache,
                caseLimit: options.limit
            )
        )
    }

}
