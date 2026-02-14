import Foundation
import WhispCore

extension WhispCLI {
    static func runSTTCaseBenchmark(options: STTBenchmarkOptions) async throws {
        let config = try loadConfig()
        if options.sttMode == .stream, !STTPresetCatalog.supportsStreaming(options.sttPreset) {
            throw AppError.invalidArgument("--stt-preset=\(options.sttPreset.rawValue) は stream 未対応です")
        }
        if options.sttMode == .rest, !STTPresetCatalog.supportsREST(options.sttPreset) {
            throw AppError.invalidArgument("--stt-preset=\(options.sttPreset.rawValue) は rest 未対応です")
        }
        let credential = try APIKeyResolver.sttCredential(config: config, preset: options.sttPreset)
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases = options.limit.map { Array(allCases.prefix($0)) } ?? allCases
        let runID = defaultBenchmarkRunID(kind: .stt)
        let sttExecutionProfile = "file_replay_realtime"
        let benchmarkWorkers = resolvedSTTBenchmarkWorkers(options: options)

        print("mode: stt_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("stt_preset: \(options.sttPreset.rawValue)")
        print("stt_mode: \(options.sttMode.rawValue)")
        print("chunk_ms: \(options.chunkMs)")
        print("silence_ms: \(options.silenceMs)")
        print("max_segment_ms: \(options.maxSegmentMs)")
        print("pre_roll_ms: \(options.preRollMs)")
        print("realtime: \(options.realtime)")
        print("stt_execution_profile: \(sttExecutionProfile)")
        print("benchmark_workers: \(benchmarkWorkers)")
        if STTPresetCatalog.spec(for: options.sttPreset).engine == .appleSpeech,
           options.sttMode == .stream,
           benchmarkWorkers == 1
        {
            print("note: apple_speech stream は安定性のため benchmark_workers を1に制限します")
        }
        print("min_audio_seconds: \(String(format: "%.2f", options.minAudioSeconds))")
        print("use_cache: \(options.useCache)")
        print("")
        print("id\tstatus\tcached\texact_match\tcer\taudio_seconds\tstt_total_ms\tstt_after_stop_ms")

        let runOptions = BenchmarkRunOptions.stt(BenchmarkSTTRunOptions(
            common: BenchmarkRunCommonOptions(
                sourceCasesPath: options.jsonlPath,
                datasetHash: options.datasetHash,
                runtimeOptionsHash: options.runtimeOptionsHash,
                evaluatorVersion: options.evaluatorVersion,
                codeVersion: options.codeVersion,
                caseLimit: options.limit,
                useCache: options.useCache
            ),
            candidateID: options.candidateID,
            sttExecutionProfile: sttExecutionProfile,
            sttMode: options.sttMode.rawValue,
            chunkMs: options.chunkMs,
            realtime: options.realtime,
            minAudioSeconds: options.minAudioSeconds,
            silenceMs: options.silenceMs,
            maxSegmentMs: options.maxSegmentMs,
            preRollMs: options.preRollMs
        ))
        let recorder = try BenchmarkRunRecorder(
            runID: runID,
            kind: .stt,
            options: runOptions,
            candidateID: options.candidateID,
            benchmarkKey: options.benchmarkKey,
            initialMetrics: .stt(BenchmarkSTTRunMetrics(
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

        let accumulator = STTOutcomeAccumulator()
        let lifecycle = try await executeBenchmarkRunLifecycle(
            selectedCases: selectedCases,
            recorder: recorder
        ) {
            try await runSTTCaseBenchmarkWithWorkers(
                runID: runID,
                selectedCases: selectedCases,
                options: options,
                workers: benchmarkWorkers,
                config: config,
                credential: credential,
                sttExecutionProfile: sttExecutionProfile,
                recorder: recorder
            ) { outcome in
                try await accumulator.consume(outcome, recorder: recorder)
            }
        } snapshotSummary: {
            await accumulator.snapshot()
        } makeMetrics: { summary in
            makeSTTRunMetrics(
                allCasesCount: allCases.count,
                selectedCasesCount: selectedCases.count,
                summary: summary
            )
        } makeRunOptions: { _ in
            runOptions
        }

        let summary = lifecycle.summary
        let exactRate = summary.executed > 0 ? Double(summary.exactCount) / Double(summary.executed) : 0
        let metrics = lifecycle.metrics
        let run = lifecycle.run

        print("")
        print("summary")
        print("executed_cases: \(summary.executed)")
        print("skipped_cases: \(summary.skipped)")
        print("failed_cases: \(summary.failed)")
        print("cached_hits: \(summary.cachedHits)")
        print("exact_match_rate: \(String(format: "%.3f", exactRate))")
        print("avg_cer: \(metrics.avgCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("weighted_cer: \(metrics.weightedCER.map { String(format: "%.3f", $0) } ?? "n/a")")
        if let total = metrics.latencyMs {
            print("stt_total_ms: avg=\(total.avg.map(msString) ?? "n/a") p50=\(total.p50.map(msString) ?? "n/a") p95=\(total.p95.map(msString) ?? "n/a") p99=\(total.p99.map(msString) ?? "n/a")")
        } else {
            print("stt_total_ms: n/a")
        }
        if let afterStop = metrics.afterStopLatencyMs {
            print("stt_after_stop_ms: avg=\(afterStop.avg.map(msString) ?? "n/a") p50=\(afterStop.p50.map(msString) ?? "n/a") p95=\(afterStop.p95.map(msString) ?? "n/a") p99=\(afterStop.p99.map(msString) ?? "n/a")")
        } else {
            print("stt_after_stop_ms: n/a")
        }
        print("benchmark_run_id: \(run.id)")
        print("benchmark_manifest: \(benchmarkManifestPath(runID: run.id))")
    }

    private struct STTCaseIOWrite: Sendable {
        let fileName: String
        let text: String
    }

    private struct STTCaseWorkerOutcome: Sendable {
        let displayLine: String
        let result: BenchmarkCaseResult
        let events: [BenchmarkCaseEvent]
        let ioWrites: [STTCaseIOWrite]
        let executed: Int
        let skipped: Int
        let failed: Int
        let cachedHits: Int
        let exactCount: Int
        let cer: Double?
        let totalEdits: Int
        let totalRefChars: Int
        let totalLatencyMs: Double?
        let afterStopLatencyMs: Double?
    }

    private struct STTOutcomeSummary: Sendable {
        var executed = 0
        var skipped = 0
        var failed = 0
        var cachedHits = 0
        var exactCount = 0
        var cerValues: [Double] = []
        var totalEdits = 0
        var totalRefChars = 0
        var totalLatencies: [Double] = []
        var afterStopLatencies: [Double] = []
    }

    private actor STTOutcomeAccumulator {
        private var summary = STTOutcomeSummary()

        func consume(_ outcome: STTCaseWorkerOutcome, recorder: BenchmarkRunRecorder) throws {
            print(outcome.displayLine)
            summary.executed += outcome.executed
            summary.skipped += outcome.skipped
            summary.failed += outcome.failed
            summary.cachedHits += outcome.cachedHits
            summary.exactCount += outcome.exactCount
            if let cer = outcome.cer {
                summary.cerValues.append(cer)
            }
            summary.totalEdits += outcome.totalEdits
            summary.totalRefChars += outcome.totalRefChars
            if let totalMs = outcome.totalLatencyMs {
                summary.totalLatencies.append(totalMs)
            }
            if let afterStopMs = outcome.afterStopLatencyMs {
                summary.afterStopLatencies.append(afterStopMs)
            }
            try recorder.appendCaseResult(outcome.result)
            try recorder.appendEvents(outcome.events)
            for write in outcome.ioWrites {
                try recorder.writeCaseIOText(caseID: outcome.result.id, fileName: write.fileName, text: write.text)
            }
        }

        func snapshot() -> STTOutcomeSummary {
            summary
        }
    }

    private static func makeSTTRunMetrics(
        allCasesCount: Int,
        selectedCasesCount: Int,
        summary: STTOutcomeSummary
    ) -> BenchmarkRunMetrics {
        let exactRate = summary.executed > 0 ? Double(summary.exactCount) / Double(summary.executed) : 0
        let totalLatencyDistribution = latencyDistribution(values: summary.totalLatencies)
        let afterStopDistribution = latencyDistribution(values: summary.afterStopLatencies)
        return .stt(BenchmarkSTTRunMetrics(
            counts: BenchmarkRunCounts(
                casesTotal: allCasesCount,
                casesSelected: selectedCasesCount,
                executedCases: summary.executed,
                skippedCases: summary.skipped,
                failedCases: summary.failed,
                cachedHits: summary.cachedHits
            ),
            exactMatchRate: exactRate,
            avgCER: summary.cerValues.isEmpty ? nil : summary.cerValues.reduce(0, +) / Double(summary.cerValues.count),
            weightedCER: summary.totalRefChars > 0 ? Double(summary.totalEdits) / Double(summary.totalRefChars) : nil,
            latencyMs: toBenchmarkLatencyDistribution(totalLatencyDistribution),
            afterStopLatencyMs: toBenchmarkLatencyDistribution(afterStopDistribution)
        ))
    }

    private static func runSTTCaseBenchmarkWithWorkers(
        runID: String,
        selectedCases: [ManualBenchmarkCase],
        options: STTBenchmarkOptions,
        workers: Int,
        config: Config,
        credential: STTCredential,
        sttExecutionProfile: String,
        recorder: BenchmarkRunRecorder,
        onOutcome: @escaping @Sendable (STTCaseWorkerOutcome) async throws -> Void
    ) async throws {
        try await runBenchmarkCaseWorkers(
            cases: selectedCases,
            workers: workers
        ) { _, item in
            try recorder.markCaseStarted(caseID: item.id)
            return await executeSTTCaseBenchmarkWorker(
                runID: runID,
                item: item,
                options: options,
                config: config,
                credential: credential,
                sttExecutionProfile: sttExecutionProfile
            )
        } onResult: { outcome in
            try await onOutcome(outcome)
        }
    }

    private static func resolvedSTTBenchmarkWorkers(options: STTBenchmarkOptions) -> Int {
        let requested = resolveBenchmarkWorkers(options.benchmarkWorkers)
        if STTPresetCatalog.spec(for: options.sttPreset).engine == .appleSpeech,
           options.sttMode == .stream
        {
            return 1
        }
        return requested
    }

    private static func executeSTTCaseBenchmarkWorker(
        runID: String,
        item: ManualBenchmarkCase,
        options: STTBenchmarkOptions,
        config: Config,
        credential: STTCredential,
        sttExecutionProfile: String
    ) async -> STTCaseWorkerOutcome {
        let caseStartedAtMs = nowEpochMs()

        guard let reference = item.resolvedSTTReferenceTranscript() else {
            let artifacts = makeSkippedCaseArtifacts(
                runID: runID,
                caseID: item.id,
                caseStartedAtMs: caseStartedAtMs,
                reason: "参照transcriptがありません",
                cacheNamespace: "stt",
                sources: BenchmarkReferenceSources(),
                contextPresent: item.context != nil,
                visionImagePresent: item.visionImageFile != nil,
                audioFilePath: item.audioFile
            )
            return STTCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_reference\tfalse\t-\t-\t-\t-\t-",
                result: artifacts.result,
                events: artifacts.events,
                ioWrites: [],
                executed: 0,
                skipped: 1,
                failed: 0,
                cachedHits: 0,
                exactCount: 0,
                cer: nil,
                totalEdits: 0,
                totalRefChars: 0,
                totalLatencyMs: nil,
                afterStopLatencyMs: nil
            )
        }

        guard FileManager.default.fileExists(atPath: item.audioFile) else {
            let sources = BenchmarkReferenceSources(transcript: reference.source)
            let artifacts = makeSkippedCaseArtifacts(
                runID: runID,
                caseID: item.id,
                caseStartedAtMs: caseStartedAtMs,
                reason: "audio_file が見つかりません",
                cacheNamespace: "stt",
                sources: sources,
                contextPresent: item.context != nil,
                visionImagePresent: item.visionImageFile != nil,
                audioFilePath: item.audioFile
            )
            return STTCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_audio\tfalse\t-\t-\t-\t-\t-",
                result: artifacts.result,
                events: artifacts.events,
                ioWrites: [],
                executed: 0,
                skipped: 1,
                failed: 0,
                cachedHits: 0,
                exactCount: 0,
                cer: nil,
                totalEdits: 0,
                totalRefChars: 0,
                totalLatencyMs: nil,
                afterStopLatencyMs: nil
            )
        }

        do {
            let wavData = try Data(contentsOf: URL(fileURLWithPath: item.audioFile))
            let audio = try parsePCM16MonoWAV(wavData)
            let audioSeconds = audioDurationSeconds(audio: audio)
            if audioSeconds < options.minAudioSeconds {
                let sources = BenchmarkReferenceSources(transcript: reference.source)
                let artifacts = makeSkippedCaseArtifacts(
                    runID: runID,
                    caseID: item.id,
                    caseStartedAtMs: caseStartedAtMs,
                    reason: "audio_seconds(\(String(format: "%.2f", audioSeconds))) < min_audio_seconds(\(String(format: "%.2f", options.minAudioSeconds)))",
                    cacheNamespace: "stt",
                    sources: sources,
                    contextPresent: item.context != nil,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
                    metrics: BenchmarkCaseMetrics(audioSeconds: audioSeconds)
                )
                return STTCaseWorkerOutcome(
                    displayLine: "\(item.id)\tskipped_too_short_audio\tfalse\t-\t-\t\(String(format: "%.2f", audioSeconds))\t-\t-",
                    result: artifacts.result,
                    events: artifacts.events,
                    ioWrites: [],
                    executed: 0,
                    skipped: 1,
                    failed: 0,
                    cachedHits: 0,
                    exactCount: 0,
                    cer: nil,
                    totalEdits: 0,
                    totalRefChars: 0,
                    totalLatencyMs: nil,
                    afterStopLatencyMs: nil
                )
            }

            let audioHash = sha256Hex(data: wavData)
            let cacheKey = sha256Hex(
                text: "stt-v4|\(options.sttPreset.rawValue)|\(options.chunkMs)|\(options.realtime)|\(options.silenceMs)|\(options.maxSegmentMs)|\(options.preRollMs)|\(config.inputLanguage)|\(audioHash)"
            )
            let loadEndedAtMs = nowEpochMs()
            let cacheStartedAtMs = nowEpochMs()
            var cacheEndedAtMs = cacheStartedAtMs
            var sttStartedAtMs = cacheStartedAtMs
            var sttEndedAtMs = cacheStartedAtMs

            let sttOutput: (
                transcript: String,
                totalMs: Double,
                afterStopMs: Double,
                replayStartedAtMs: Int64?,
                replayEndedAtMs: Int64?,
                attempts: [BenchmarkSTTAttempt],
                segmentCount: Int?,
                vadSilenceCount: Int?,
                cached: Bool
            )
            var cachedHits = 0

            if options.useCache,
               let cached: CachedSTTResult = loadCacheEntry(component: "stt", key: cacheKey)
            {
                cacheEndedAtMs = nowEpochMs()
                let cachedOutput = await buildCachedSTTOutput(
                    cached: cached,
                    audio: audio,
                    realtime: options.realtime
                )
                sttStartedAtMs = cachedOutput.sttStartedAtMs
                sttEndedAtMs = cachedOutput.sttEndedAtMs
                sttOutput = (
                    cachedOutput.transcript,
                    cachedOutput.totalMs,
                    cachedOutput.afterStopMs,
                    cachedOutput.replayStartedAtMs,
                    cachedOutput.replayEndedAtMs,
                    cachedOutput.attempts,
                    cachedOutput.segmentCount,
                    cachedOutput.vadSilenceCount,
                    true
                )
                cachedHits = 1
            } else {
                cacheEndedAtMs = nowEpochMs()
                let result = try await runSTTInference(
                    preset: options.sttPreset,
                    credential: credential,
                    audio: audio,
                    languageHint: config.inputLanguage,
                    chunkMs: options.chunkMs,
                    realtime: options.realtime,
                    segmentation: STTSegmentationConfig(
                        silenceMs: options.silenceMs,
                        maxSegmentMs: options.maxSegmentMs,
                        preRollMs: options.preRollMs,
                        livePreviewEnabled: false
                    )
                )
                sttOutput = (
                    result.transcript,
                    result.totalMs,
                    result.afterStopMs,
                    result.replayStartedAtMs,
                    result.replayEndedAtMs,
                    result.attempts,
                    result.segmentCount,
                    result.vadSilenceCount,
                    false
                )
                sttStartedAtMs = result.attempts.map(\.startedAtMs).min() ?? nowEpochMs()
                sttEndedAtMs = result.attempts.map(\.endedAtMs).max() ?? nowEpochMs()
                if options.useCache {
                    let cache = CachedSTTResult(
                        key: cacheKey,
                        mode: options.sttMode.rawValue,
                        transcript: result.transcript,
                        totalMs: result.totalMs,
                        afterStopMs: result.afterStopMs,
                        segmentCount: result.segmentCount,
                        vadSilenceCount: result.vadSilenceCount,
                        createdAt: WhispTime.isoNow()
                    )
                    try saveCacheEntry(component: "stt", key: cacheKey, value: cache)
                }
            }

            let refChars = Array(normalizedEvalText(reference.text))
            let hypChars = Array(normalizedEvalText(sttOutput.transcript))
            let edit = levenshteinDistance(refChars, hypChars)
            let cer = Double(edit) / Double(max(1, refChars.count))
            let exact = normalizedEvalText(reference.text) == normalizedEvalText(sttOutput.transcript)

            let status: BenchmarkCaseStatus = .ok
            let sources = BenchmarkReferenceSources(transcript: reference.source)
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: nil,
                cache: BenchmarkCacheRecord(hit: sttOutput.cached, key: cacheKey, namespace: "stt"),
                sources: sources,
                contextUsed: item.context != nil,
                visionImageAttached: item.visionImageFile != nil,
                metrics: BenchmarkCaseMetrics(
                    exactMatch: exact,
                    cer: cer,
                    sttTotalMs: sttOutput.totalMs,
                    sttAfterStopMs: sttOutput.afterStopMs,
                    latencyMs: sttOutput.totalMs,
                    audioSeconds: audioSeconds,
                    outputChars: hypChars.count,
                    segmentCount: sttOutput.segmentCount,
                    vadSilenceCount: sttOutput.vadSilenceCount
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
                    namespace: "stt",
                    key: cacheKey,
                    hit: sttOutput.cached,
                    keyMaterialRef: nil,
                    error: nil
                )),
            ]
            if let replayStartedAtMs = sttOutput.replayStartedAtMs,
               let replayEndedAtMs = sttOutput.replayEndedAtMs,
               replayEndedAtMs >= replayStartedAtMs
            {
                events.append(.audioReplay(BenchmarkAudioReplayLog(
                    base: makeEventBase(
                        runID: runID,
                        caseID: item.id,
                        stage: .audioReplay,
                        status: .ok,
                        startedAtMs: replayStartedAtMs,
                        endedAtMs: replayEndedAtMs
                    ),
                    profile: sttExecutionProfile,
                    chunkMs: options.chunkMs,
                    realtime: options.realtime
                )))
            }
            events.append(.stt(BenchmarkSTTLog(
                base: makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .stt,
                    status: .ok,
                    startedAtMs: sttStartedAtMs,
                    endedAtMs: sttEndedAtMs
                ),
                provider: options.sttPreset.rawValue,
                mode: options.sttMode.rawValue,
                transcriptText: sttOutput.transcript,
                referenceText: reference.text,
                transcriptChars: hypChars.count,
                cer: cer,
                sttTotalMs: sttOutput.totalMs,
                sttAfterStopMs: sttOutput.afterStopMs,
                attempts: sttOutput.attempts,
                rawResponseRef: nil,
                error: nil
            )))
            events.append(.aggregate(BenchmarkAggregateLog(
                base: makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .aggregate,
                    status: eventStatus(from: status),
                    startedAtMs: sttEndedAtMs,
                    endedAtMs: nowEpochMs()
                ),
                exactMatch: exact,
                cer: cer,
                intentMatch: nil,
                intentScore: nil,
                intentPreservationScore: nil,
                hallucinationScore: nil,
                hallucinationRate: nil,
                latencyMs: sttOutput.totalMs,
                totalAfterStopMs: sttOutput.afterStopMs,
                outputChars: hypChars.count
            )))

            return STTCaseWorkerOutcome(
                displayLine: "\(item.id)\tok\t\(sttOutput.cached)\t\(exact)\t\(String(format: "%.3f", cer))\t\(String(format: "%.2f", audioSeconds))\t\(msString(sttOutput.totalMs))\t\(msString(sttOutput.afterStopMs))",
                result: result,
                events: events,
                ioWrites: [
                    STTCaseIOWrite(fileName: "output_stt.txt", text: sttOutput.transcript),
                    STTCaseIOWrite(fileName: "reference.txt", text: reference.text),
                ],
                executed: 1,
                skipped: 0,
                failed: 0,
                cachedHits: cachedHits,
                exactCount: exact ? 1 : 0,
                cer: cer,
                totalEdits: edit,
                totalRefChars: refChars.count,
                totalLatencyMs: sttOutput.totalMs,
                afterStopLatencyMs: sttOutput.afterStopMs
            )
        } catch {
            let status: BenchmarkCaseStatus = .error
            let sources = BenchmarkReferenceSources(transcript: reference.source)
            let message = error.localizedDescription
            let result = BenchmarkCaseResult(
                id: item.id,
                status: status,
                reason: message,
                cache: BenchmarkCacheRecord(hit: false, namespace: "stt"),
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
                        status: eventStatus(from: status),
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
                    errorType: "stt_case_error",
                    message: message
                )),
            ]
            return STTCaseWorkerOutcome(
                displayLine: "\(item.id)\terror\tfalse\t-\t-\t-\t-\t-",
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
                totalLatencyMs: nil,
                afterStopLatencyMs: nil
            )
        }
    }

    private static func buildCachedSTTOutput(
        cached: CachedSTTResult,
        audio: AudioData,
        realtime: Bool
    ) async -> (
        transcript: String,
        totalMs: Double,
        afterStopMs: Double,
        replayStartedAtMs: Int64?,
        replayEndedAtMs: Int64?,
        attempts: [BenchmarkSTTAttempt],
        segmentCount: Int?,
        vadSilenceCount: Int?,
        sttStartedAtMs: Int64,
        sttEndedAtMs: Int64
    ) {
        if !realtime {
            let startedAtMs = nowEpochMs()
            let endedAtMs = nowEpochMs()
            return (
                cached.transcript,
                cached.totalMs,
                cached.afterStopMs,
                nil,
                nil,
                [BenchmarkSTTAttempt(
                    kind: "cache_hit",
                    status: .ok,
                    startedAtMs: startedAtMs,
                    endedAtMs: endedAtMs
                )],
                cached.segmentCount,
                cached.vadSilenceCount,
                startedAtMs,
                endedAtMs
            )
        }

        let replayStartedAtMs = nowEpochMs()
        let replaySecondsRaw = audioDurationSeconds(audio: audio)
        let replaySeconds = (replaySecondsRaw.isFinite && replaySecondsRaw > 0) ? replaySecondsRaw : 0
        let replayDurationNs = UInt64(replaySeconds * 1_000_000_000)
        if replayDurationNs > 0 {
            try? await Task.sleep(nanoseconds: replayDurationNs)
        }
        let replayEndedAtMs = nowEpochMs()

        let simulatedAfterStopMsRaw = cached.afterStopMs
        let simulatedAfterStopMs = (simulatedAfterStopMsRaw.isFinite && simulatedAfterStopMsRaw > 0) ? simulatedAfterStopMsRaw : 0
        let simulatedAfterStopNs = UInt64(simulatedAfterStopMs * 1_000_000)
        if simulatedAfterStopNs > 0 {
            try? await Task.sleep(nanoseconds: simulatedAfterStopNs)
        }
        let sttEndedAtMs = nowEpochMs()

        let streamMode = cached.mode == STTMode.stream.rawValue
        let sttStartedAtMs = streamMode ? replayStartedAtMs : replayEndedAtMs
        let measuredAfterStopMs = Double(max(0, sttEndedAtMs - replayEndedAtMs))
        let measuredTotalMs = Double(max(0, sttEndedAtMs - sttStartedAtMs))

        return (
            cached.transcript,
            measuredTotalMs,
            measuredAfterStopMs,
            replayStartedAtMs,
            replayEndedAtMs,
            [BenchmarkSTTAttempt(
                kind: "cache_hit",
                status: .ok,
                startedAtMs: sttStartedAtMs,
                endedAtMs: sttEndedAtMs
            )],
            cached.segmentCount,
            cached.vadSilenceCount,
            sttStartedAtMs,
            sttEndedAtMs
        )
    }
}
