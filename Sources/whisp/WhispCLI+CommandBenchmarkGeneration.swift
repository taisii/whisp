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
        let effectivePromptTemplate = options.promptTemplateOverride ?? defaultPostProcessPromptTemplate
        let effectivePromptHash = options.promptHash ?? promptTemplateHash(effectivePromptTemplate)

        print("mode: generation_case_benchmark")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("model: \(model.rawValue)")
        print("prompt_name: \(options.promptName ?? "-")")
        print("prompt_hash: \(effectivePromptHash)")
        print("require_context: \(options.requireContext)")
        print("use_cache: \(options.useCache)")
        print("llm_eval: \(options.llmEvalEnabled)")
        print("llm_eval_model: \(options.llmEvalModel?.rawValue ?? "auto")")
        print("benchmark_workers: \(benchmarkWorkers)")
        print("")
        print("id\tstatus\tcached\texact_match\tcer\tpost_ms\toutput_chars\tintent_preservation\thallucination_rate")

        func makeRunOptions(resolvedLLMEvalModel: String?) -> BenchmarkRunOptions {
            .generation(BenchmarkGenerationRunOptions(
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
                promptName: options.promptName,
                generationPromptHash: effectivePromptHash,
                requireContext: options.requireContext,
                llmEvalEnabled: options.llmEvalEnabled,
                llmEvalModel: resolvedLLMEvalModel ?? options.llmEvalModel?.rawValue,
                llmModel: model.rawValue,
                candidateSnapshot: options.candidateSnapshot
            ))
        }

        let initialRunOptions = makeRunOptions(resolvedLLMEvalModel: nil)
        let recorder = try BenchmarkRunRecorder(
            runID: runID,
            kind: .generation,
            options: initialRunOptions,
            candidateID: options.candidateID,
            benchmarkKey: options.benchmarkKey,
            initialMetrics: .generation(BenchmarkGenerationRunMetrics(
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

        let accumulator = GenerationOutcomeAccumulator()
        let lifecycle = try await executeBenchmarkRunLifecycle(
            selectedCases: selectedCases,
            recorder: recorder
        ) {
            try await runGenerationCaseBenchmarkWithWorkers(
                runID: runID,
                selectedCases: selectedCases,
                options: options,
                config: config,
                model: model,
                apiKey: apiKey,
                recorder: recorder
            ) { outcome in
                try await accumulator.consume(outcome, recorder: recorder)
            }
        } snapshotSummary: {
            await accumulator.snapshot()
        } makeMetrics: { summary in
            makeGenerationRunMetrics(
                allCasesCount: allCases.count,
                selectedCasesCount: selectedCases.count,
                summary: summary
            )
        } makeRunOptions: { summary in
            makeRunOptions(resolvedLLMEvalModel: summary.resolvedLLMEvalModel)
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
        if let post = metrics.postLatencyMs {
            print("post_ms: avg=\(post.avg.map(msString) ?? "n/a") p50=\(post.p50.map(msString) ?? "n/a") p95=\(post.p95.map(msString) ?? "n/a") p99=\(post.p99.map(msString) ?? "n/a")")
        } else {
            print("post_ms: n/a")
        }
        print("llm_eval_evaluated_cases: \(summary.llmEvalEvaluatedCases)")
        print("llm_eval_error_cases: \(summary.llmEvalErrorCases)")
        print("intent_preservation_score: \(metrics.intentPreservationScore.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("hallucination_score: \(metrics.hallucinationScore.map { String(format: "%.3f", $0) } ?? "n/a")")
        print("hallucination_rate: \(metrics.hallucinationRate.map { String(format: "%.3f", $0) } ?? "n/a")")
        if let llmEvalUnavailableReason = summary.llmEvalUnavailableReason {
            print("llm_eval_note: \(llmEvalUnavailableReason)")
        }
        print("benchmark_run_id: \(run.id)")
        print("benchmark_manifest: \(benchmarkManifestPath(runID: run.id))")
    }

    static func runGenerationPairwiseCompare(options: GenerationPairwiseCompareOptions) async throws {
        let config = try loadConfig()
        let descriptorA = try makePairwiseCandidateDescriptor(candidate: options.candidateA, config: config)
        let descriptorB = try makePairwiseCandidateDescriptor(candidate: options.candidateB, config: config)
        let judgeContext: (model: LLMModel, apiKey: String)
        if let judgeAPIKey = options.judgeAPIKey {
            judgeContext = (model: options.judgeModel, apiKey: judgeAPIKey)
        } else {
            judgeContext = try APIKeyResolver.resolveIntentJudgeContext(
                config: config,
                preferredModel: options.judgeModel,
                requiresVision: true
            )
        }
        let allCases = try loadManualBenchmarkCases(path: options.jsonlPath)
        let selectedCases = options.limit.map { Array(allCases.prefix($0)) } ?? allCases
        let runID = defaultBenchmarkRunID(kind: .generation)
        let benchmarkWorkers = resolveBenchmarkWorkers(options.benchmarkWorkers)

        print("mode: generation_pairwise_compare")
        print("jsonl: \(options.jsonlPath)")
        print("cases_total: \(allCases.count)")
        print("cases_selected: \(selectedCases.count)")
        print("candidate_a: \(descriptorA.id)")
        print("candidate_b: \(descriptorB.id)")
        print("model_a: \(descriptorA.model.rawValue)")
        print("model_b: \(descriptorB.model.rawValue)")
        print("prompt_hash_a: \(descriptorA.promptHash)")
        print("prompt_hash_b: \(descriptorB.promptHash)")
        print("judge_model: \(judgeContext.model.rawValue)")
        print("benchmark_workers: \(benchmarkWorkers)")
        print("")
        print("id\tstatus\toverall\tintent\thallucination\tstyle_context")

        let runOptions = BenchmarkRunOptions.generationPairwise(BenchmarkGenerationPairwiseRunOptions(
            common: BenchmarkRunCommonOptions(
                sourceCasesPath: options.jsonlPath,
                datasetHash: options.datasetHash,
                runtimeOptionsHash: options.runtimeOptionsHash,
                evaluatorVersion: options.evaluatorVersion,
                codeVersion: options.codeVersion,
                caseLimit: options.limit
            ),
            pairCandidateAID: descriptorA.id,
            pairCandidateBID: descriptorB.id,
            pairJudgeModel: judgeContext.model.rawValue,
            llmModel: "\(descriptorA.model.rawValue)|\(descriptorB.model.rawValue)",
            pairCandidateASnapshot: options.pairCandidateASnapshot,
            pairCandidateBSnapshot: options.pairCandidateBSnapshot
        ))
        let recorder = try BenchmarkRunRecorder(
            runID: runID,
            kind: .generation,
            options: runOptions,
            candidateID: nil,
            benchmarkKey: options.benchmarkKey,
            initialMetrics: .generationPairwise(BenchmarkGenerationPairwiseRunMetrics(
                counts: BenchmarkRunCounts(
                    casesTotal: allCases.count,
                    casesSelected: selectedCases.count,
                    executedCases: 0,
                    skippedCases: 0,
                    failedCases: 0,
                    cachedHits: 0
                ),
                pairwiseSummary: PairwiseRunSummary()
            ))
        )

        let accumulator = PairwiseOutcomeAccumulator()
        let lifecycle = try await executeBenchmarkRunLifecycle(
            selectedCases: selectedCases,
            recorder: recorder
        ) {
            try await runBenchmarkCaseWorkers(
                cases: selectedCases,
                workers: options.benchmarkWorkers
            ) { _, item in
                try recorder.markCaseStarted(caseID: item.id)
                return await executeGenerationPairwiseWorker(
                    runID: runID,
                    item: item,
                    config: config,
                    descriptorA: descriptorA,
                    descriptorB: descriptorB,
                    judgeModel: judgeContext.model,
                    judgeAPIKey: judgeContext.apiKey
                )
            } onResult: { outcome in
                try await accumulator.consume(outcome, recorder: recorder)
            }
        } snapshotSummary: {
            await accumulator.snapshot()
        } makeMetrics: { summary in
            makeGenerationPairwiseRunMetrics(
                allCasesCount: allCases.count,
                selectedCasesCount: selectedCases.count,
                summary: summary
            )
        } makeRunOptions: { _ in
            runOptions
        }

        let summary = lifecycle.summary
        let run = lifecycle.run

        print("")
        print("summary")
        print("executed_cases: \(summary.executed)")
        print("skipped_cases: \(summary.skipped)")
        print("failed_cases: \(summary.failed)")
        print("cached_hits: \(summary.cachedHits)")
        print("judged_cases: \(summary.pairwiseSummary.judgedCases)")
        print("judge_error_cases: \(summary.pairwiseSummary.judgeErrorCases)")
        print("overall: a=\(summary.pairwiseSummary.overallAWins) b=\(summary.pairwiseSummary.overallBWins) tie=\(summary.pairwiseSummary.overallTies)")
        print("intent: a=\(summary.pairwiseSummary.intentAWins) b=\(summary.pairwiseSummary.intentBWins) tie=\(summary.pairwiseSummary.intentTies)")
        print("hallucination: a=\(summary.pairwiseSummary.hallucinationAWins) b=\(summary.pairwiseSummary.hallucinationBWins) tie=\(summary.pairwiseSummary.hallucinationTies)")
        print("style_context: a=\(summary.pairwiseSummary.styleContextAWins) b=\(summary.pairwiseSummary.styleContextBWins) tie=\(summary.pairwiseSummary.styleContextTies)")
        print("benchmark_run_id: \(run.id)")
        print("benchmark_manifest: \(benchmarkManifestPath(runID: run.id))")
    }

    private struct PairwiseCandidateDescriptor: Sendable {
        let id: String
        let model: LLMModel
        let promptName: String?
        let promptTemplate: String
        let promptHash: String
        let requireContext: Bool
        let useCache: Bool
        let apiKey: String
    }

    private struct PairwiseGenerationOutput: Sendable {
        let text: String
        let prompt: String
        let postMs: Double
        let cached: Bool
        let cacheKey: String
    }

    private struct PairwiseJudgeImageInput: Sendable {
        let path: String?
        let mimeType: String?
        let data: Data?
        let imageMissing: Bool
        let missingReason: String?
    }

    private struct PairwiseJudgeInputMeta: Codable {
        let visionImagePath: String?
        let visionImageMimeType: String?
        let imageAttached: Bool
        let imageMissing: Bool
        let imageMissingReason: String?
        let sttInputTextPresent: Bool

        enum CodingKeys: String, CodingKey {
            case visionImagePath = "vision_image_path"
            case visionImageMimeType = "vision_image_mime_type"
            case imageAttached = "image_attached"
            case imageMissing = "image_missing"
            case imageMissingReason = "image_missing_reason"
            case sttInputTextPresent = "stt_input_text_present"
        }
    }

    private struct PairwiseCaseWorkerOutcome: Sendable {
        let displayLine: String
        let result: BenchmarkCaseResult
        let events: [BenchmarkCaseEvent]
        let ioWrites: [GenerationCaseIOWrite]
        let executed: Int
        let skipped: Int
        let failed: Int
        let cachedHits: Int
        let pairwise: PairwiseCaseJudgement?
        let judgeError: Bool
    }

    private struct PairwiseOutcomeSummary: Sendable {
        var executed = 0
        var skipped = 0
        var failed = 0
        var cachedHits = 0
        var pairwiseSummary = PairwiseRunSummary()
    }

    private actor PairwiseOutcomeAccumulator {
        private var summary = PairwiseOutcomeSummary()

        func consume(_ outcome: PairwiseCaseWorkerOutcome, recorder: BenchmarkRunRecorder) throws {
            print(outcome.displayLine)
            summary.executed += outcome.executed
            summary.skipped += outcome.skipped
            summary.failed += outcome.failed
            summary.cachedHits += outcome.cachedHits
            if let judgement = outcome.pairwise {
                summary.pairwiseSummary.judgedCases += 1
                switch judgement.overallWinner {
                case .a:
                    summary.pairwiseSummary.overallAWins += 1
                case .b:
                    summary.pairwiseSummary.overallBWins += 1
                case .tie:
                    summary.pairwiseSummary.overallTies += 1
                }
                switch judgement.intentWinner {
                case .a:
                    summary.pairwiseSummary.intentAWins += 1
                case .b:
                    summary.pairwiseSummary.intentBWins += 1
                case .tie:
                    summary.pairwiseSummary.intentTies += 1
                }
                switch judgement.hallucinationWinner {
                case .a:
                    summary.pairwiseSummary.hallucinationAWins += 1
                case .b:
                    summary.pairwiseSummary.hallucinationBWins += 1
                case .tie:
                    summary.pairwiseSummary.hallucinationTies += 1
                }
                switch judgement.styleContextWinner {
                case .a:
                    summary.pairwiseSummary.styleContextAWins += 1
                case .b:
                    summary.pairwiseSummary.styleContextBWins += 1
                case .tie:
                    summary.pairwiseSummary.styleContextTies += 1
                }
            }
            if outcome.judgeError {
                summary.pairwiseSummary.judgeErrorCases += 1
            }

            try recorder.appendCaseResult(outcome.result)
            try recorder.appendEvents(outcome.events)
            for write in outcome.ioWrites {
                try recorder.writeCaseIOText(caseID: outcome.result.id, fileName: write.fileName, text: write.text)
            }
        }

        func snapshot() -> PairwiseOutcomeSummary {
            summary
        }
    }

    private static func executeGenerationPairwiseWorker(
        runID: String,
        item: ManualBenchmarkCase,
        config: Config,
        descriptorA: PairwiseCandidateDescriptor,
        descriptorB: PairwiseCandidateDescriptor,
        judgeModel: LLMModel,
        judgeAPIKey: String
    ) async -> PairwiseCaseWorkerOutcome {
        let caseStartedAtMs = nowEpochMs()
        guard let input = item.resolvedGenerationInputSTT() else {
            return makePairwiseSkippedOutcome(
                runID: runID,
                caseStartedAtMs: caseStartedAtMs,
                item: item,
                reason: "stt入力がありません"
            )
        }
        let requireContext = descriptorA.requireContext || descriptorB.requireContext
        if requireContext, item.context == nil {
            return makePairwiseSkippedOutcome(
                runID: runID,
                caseStartedAtMs: caseStartedAtMs,
                item: item,
                reason: "候補の require_context 条件を満たせません"
            )
        }

        let sources = BenchmarkReferenceSources(
            input: input.source,
            reference: item.resolvedGenerationReferenceText()?.source
        )
        do {
            let reference = item.resolvedGenerationReferenceText()?.text
            let contextHash = sha256Hex(text: canonicalContextString(item.context))
            let inputHash = sha256Hex(text: input.text)
            let judgeImageInput = resolvePairwiseJudgeImageInput(item: item)
            let generationA = try await generateForPairwiseCandidate(
                descriptor: descriptorA,
                config: config,
                inputText: input.text,
                context: item.context,
                inputHash: inputHash,
                contextHash: contextHash
            )
            let generationB = try await generateForPairwiseCandidate(
                descriptor: descriptorB,
                config: config,
                inputText: input.text,
                context: item.context,
                inputHash: inputHash,
                contextHash: contextHash
            )

            let judgeRound1: (result: PairwiseJudgeResult, prompt: String, responseJSON: String)
            let judgeRound2: (result: PairwiseJudgeResult, prompt: String, responseJSON: String)
            do {
                judgeRound1 = try await runPairwiseJudge(
                    model: judgeModel,
                    apiKey: judgeAPIKey,
                    referenceText: reference,
                    sttInputText: input.text,
                    candidateAText: generationA.text,
                    candidateBText: generationB.text,
                    visionImageData: judgeImageInput.data,
                    visionImageMimeType: judgeImageInput.mimeType
                )
                judgeRound2 = try await runPairwiseJudge(
                    model: judgeModel,
                    apiKey: judgeAPIKey,
                    referenceText: reference,
                    sttInputText: input.text,
                    candidateAText: generationB.text,
                    candidateBText: generationA.text,
                    visionImageData: judgeImageInput.data,
                    visionImageMimeType: judgeImageInput.mimeType
                )
            } catch {
                throw AppError.io("pairwise_judge_failed: \(error.localizedDescription)")
            }
            let judgement = aggregatePairwiseJudgement(round1: judgeRound1.result, round2Swapped: judgeRound2.result)
            let decisionJSON = encodePairwiseDecisionJSON(judgement)

            let outputChars = generationA.text.count + generationB.text.count
            let result = BenchmarkCaseResult(
                id: item.id,
                status: .ok,
                reason: nil,
                cache: BenchmarkCacheRecord(
                    hit: generationA.cached && generationB.cached,
                    key: "\(generationA.cacheKey)|\(generationB.cacheKey)",
                    namespace: "generation_pairwise"
                ),
                sources: sources,
                contextUsed: item.context != nil,
                visionImageAttached: item.visionImageFile != nil,
                metrics: BenchmarkCaseMetrics(
                    postMs: max(generationA.postMs, generationB.postMs),
                    outputChars: outputChars,
                    pairwise: judgement
                )
            )

            var events: [BenchmarkCaseEvent] = []
            let loadEndedAtMs = nowEpochMs()
            events.append(.loadCase(BenchmarkLoadCaseLog(
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
            )))
            events.append(.cache(BenchmarkCacheLog(
                base: makeEventBase(runID: runID, caseID: item.id, stage: .cache, status: .ok),
                namespace: "generation_a",
                key: generationA.cacheKey,
                hit: generationA.cached,
                keyMaterialRef: nil,
                error: nil
            )))
            events.append(.cache(BenchmarkCacheLog(
                base: makeEventBase(runID: runID, caseID: item.id, stage: .cache, status: .ok),
                namespace: "generation_b",
                key: generationB.cacheKey,
                hit: generationB.cached,
                keyMaterialRef: nil,
                error: nil
            )))
            events.append(.generation(BenchmarkGenerationLog(
                base: makeEventBase(runID: runID, caseID: item.id, stage: .generation, status: .ok),
                model: descriptorA.model.rawValue,
                inputChars: input.text.count,
                outputChars: generationA.text.count,
                postMs: generationA.postMs,
                promptRef: nil,
                responseRef: nil,
                error: nil
            )))
            events.append(.generation(BenchmarkGenerationLog(
                base: makeEventBase(runID: runID, caseID: item.id, stage: .generation, status: .ok),
                model: descriptorB.model.rawValue,
                inputChars: input.text.count,
                outputChars: generationB.text.count,
                postMs: generationB.postMs,
                promptRef: nil,
                responseRef: nil,
                error: nil
            )))
            events.append(.judge(BenchmarkJudgeLog(
                base: makeEventBase(runID: runID, caseID: item.id, stage: .judge, status: .ok),
                model: judgeModel.rawValue,
                match: nil,
                score: nil,
                intentPreservationScore: nil,
                hallucinationScore: nil,
                hallucinationRate: nil,
                requestRef: nil,
                responseRef: nil,
                error: judgeImageInput.imageMissing ? "image_missing: fallback_to_text_only" : nil
            )))
            events.append(.aggregate(BenchmarkAggregateLog(
                base: makeEventBase(runID: runID, caseID: item.id, stage: .aggregate, status: .ok),
                exactMatch: nil,
                cer: nil,
                intentMatch: nil,
                intentScore: nil,
                intentPreservationScore: nil,
                hallucinationScore: nil,
                hallucinationRate: nil,
                latencyMs: nil,
                totalAfterStopMs: nil,
                outputChars: outputChars
            )))

            var ioWrites: [GenerationCaseIOWrite] = [
                GenerationCaseIOWrite(fileName: "input_stt.txt", text: input.text),
                GenerationCaseIOWrite(fileName: "prompt_generation_a.txt", text: generationA.prompt),
                GenerationCaseIOWrite(fileName: "output_generation_a.txt", text: generationA.text),
                GenerationCaseIOWrite(fileName: "prompt_generation_b.txt", text: generationB.prompt),
                GenerationCaseIOWrite(fileName: "output_generation_b.txt", text: generationB.text),
                GenerationCaseIOWrite(fileName: "prompt_pairwise_round1.txt", text: judgeRound1.prompt),
                GenerationCaseIOWrite(fileName: "prompt_pairwise_round2.txt", text: judgeRound2.prompt),
                GenerationCaseIOWrite(fileName: "pairwise_round1_response.json", text: judgeRound1.responseJSON),
                GenerationCaseIOWrite(fileName: "pairwise_round2_response.json", text: judgeRound2.responseJSON),
                GenerationCaseIOWrite(fileName: "pairwise_decision.json", text: decisionJSON),
                GenerationCaseIOWrite(
                    fileName: "pairwise_judge_input_meta.json",
                    text: encodePairwiseJudgeInputMeta(
                        PairwiseJudgeInputMeta(
                            visionImagePath: judgeImageInput.path,
                            visionImageMimeType: judgeImageInput.mimeType,
                            imageAttached: WhispCLI.pairwiseJudgeHasImagePayload(
                                visionImageData: judgeImageInput.data,
                                visionImageMimeType: judgeImageInput.mimeType
                            ),
                            imageMissing: judgeImageInput.imageMissing,
                            imageMissingReason: judgeImageInput.missingReason,
                            sttInputTextPresent: !input.text
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                    )
                ),
            ]
            if let reference, !reference.isEmpty {
                ioWrites.append(GenerationCaseIOWrite(fileName: "reference.txt", text: reference))
            }

            return PairwiseCaseWorkerOutcome(
                displayLine: "\(item.id)\tok\t\(judgement.overallWinner.rawValue)\t\(judgement.intentWinner.rawValue)\t\(judgement.hallucinationWinner.rawValue)\t\(judgement.styleContextWinner.rawValue)",
                result: result,
                events: events,
                ioWrites: ioWrites,
                executed: 1,
                skipped: 0,
                failed: 0,
                cachedHits: (generationA.cached ? 1 : 0) + (generationB.cached ? 1 : 0),
                pairwise: judgement,
                judgeError: false
            )
        } catch {
            let reason = error.localizedDescription
            let isJudgeError = reason.contains("pairwise_judge_failed:")
            let result = BenchmarkCaseResult(
                id: item.id,
                status: .error,
                reason: reason,
                cache: BenchmarkCacheRecord(hit: false, namespace: "generation_pairwise"),
                sources: sources,
                contextUsed: item.context != nil,
                visionImageAttached: item.visionImageFile != nil,
                metrics: BenchmarkCaseMetrics()
            )
            let events: [BenchmarkCaseEvent] = [
                .loadCase(BenchmarkLoadCaseLog(
                    base: makeEventBase(runID: runID, caseID: item.id, stage: .loadCase, status: .ok, startedAtMs: caseStartedAtMs, endedAtMs: nowEpochMs()),
                    sources: sources,
                    contextPresent: item.context != nil,
                    visionImagePresent: item.visionImageFile != nil,
                    audioFilePath: item.audioFile,
                    rawRowRef: nil
                )),
                .judge(BenchmarkJudgeLog(
                    base: makeEventBase(runID: runID, caseID: item.id, stage: .judge, status: isJudgeError ? .error : .skipped),
                    model: judgeModel.rawValue,
                    match: nil,
                    score: nil,
                    intentPreservationScore: nil,
                    hallucinationScore: nil,
                    hallucinationRate: nil,
                    requestRef: nil,
                    responseRef: nil,
                    error: reason
                )),
                .aggregate(BenchmarkAggregateLog(
                    base: makeEventBase(runID: runID, caseID: item.id, stage: .aggregate, status: .error),
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
                    base: makeEventBase(runID: runID, caseID: item.id, stage: .error, status: .error),
                    originStage: isJudgeError ? .judge : .generation,
                    errorType: isJudgeError ? "pairwise_judge_error" : "pairwise_generation_error",
                    message: reason
                )),
            ]
            return PairwiseCaseWorkerOutcome(
                displayLine: "\(item.id)\terror\t-\t-\t-\t-",
                result: result,
                events: events,
                ioWrites: [],
                executed: 0,
                skipped: 0,
                failed: 1,
                cachedHits: 0,
                pairwise: nil,
                judgeError: isJudgeError
            )
        }
    }

    private static func makePairwiseSkippedOutcome(
        runID: String,
        caseStartedAtMs: Int64,
        item: ManualBenchmarkCase,
        reason: String
    ) -> PairwiseCaseWorkerOutcome {
        let result = BenchmarkCaseResult(
            id: item.id,
            status: .skipped,
            reason: reason,
            cache: BenchmarkCacheRecord(hit: false, namespace: "generation_pairwise"),
            sources: BenchmarkReferenceSources(),
            contextUsed: item.context != nil,
            visionImageAttached: item.visionImageFile != nil,
            metrics: BenchmarkCaseMetrics()
        )
        let events: [BenchmarkCaseEvent] = [
            .loadCase(BenchmarkLoadCaseLog(
                base: makeEventBase(
                    runID: runID,
                    caseID: item.id,
                    stage: .loadCase,
                    status: .ok,
                    startedAtMs: caseStartedAtMs,
                    endedAtMs: nowEpochMs()
                ),
                sources: BenchmarkReferenceSources(),
                contextPresent: item.context != nil,
                visionImagePresent: item.visionImageFile != nil,
                audioFilePath: item.audioFile,
                rawRowRef: nil
            )),
            .aggregate(BenchmarkAggregateLog(
                base: makeEventBase(runID: runID, caseID: item.id, stage: .aggregate, status: .skipped),
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
        return PairwiseCaseWorkerOutcome(
            displayLine: "\(item.id)\tskipped\t-\t-\t-\t-",
            result: result,
            events: events,
            ioWrites: [],
            executed: 0,
            skipped: 1,
            failed: 0,
            cachedHits: 0,
            pairwise: nil,
            judgeError: false
        )
    }

    private static func resolvePairwiseJudgeImageInput(item: ManualBenchmarkCase) -> PairwiseJudgeImageInput {
        let trimmedPath = (item.visionImageFile ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return PairwiseJudgeImageInput(
                path: nil,
                mimeType: nil,
                data: nil,
                imageMissing: false,
                missingReason: nil
            )
        }
        guard FileManager.default.fileExists(atPath: trimmedPath) else {
            return PairwiseJudgeImageInput(
                path: trimmedPath,
                mimeType: nil,
                data: nil,
                imageMissing: true,
                missingReason: "画像ファイルが見つかりません: \(trimmedPath)"
            )
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: trimmedPath))
            guard !data.isEmpty else {
                return PairwiseJudgeImageInput(
                    path: trimmedPath,
                    mimeType: nil,
                    data: nil,
                    imageMissing: true,
                    missingReason: "画像ファイルが空です: \(trimmedPath)"
                )
            }
            let trimmedMime = (item.visionImageMimeType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let mimeType = trimmedMime.isEmpty ? inferImageMimeType(path: trimmedPath) : trimmedMime
            return PairwiseJudgeImageInput(
                path: trimmedPath,
                mimeType: mimeType,
                data: data,
                imageMissing: false,
                missingReason: nil
            )
        } catch {
            return PairwiseJudgeImageInput(
                path: trimmedPath,
                mimeType: nil,
                data: nil,
                imageMissing: true,
                missingReason: "画像ファイルの読み込みに失敗: \(error.localizedDescription)"
            )
        }
    }

    private static func encodePairwiseJudgeInputMeta(_ meta: PairwiseJudgeInputMeta) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(meta),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{\"image_missing\":\(meta.imageMissing ? "true" : "false")}"
        }
        return text
    }

    private static func generateForPairwiseCandidate(
        descriptor: PairwiseCandidateDescriptor,
        config: Config,
        inputText: String,
        context: ContextInfo?,
        inputHash: String,
        contextHash: String
    ) async throws -> PairwiseGenerationOutput {
        let prompt = makePostProcessPrompt(
            config: config,
            sttText: inputText,
            context: context,
            templateOverride: descriptor.promptTemplate
        )
        let cacheKey = sha256Hex(
            text: "generation-v2|\(descriptor.model.rawValue)|\(config.inputLanguage)|\(descriptor.promptHash)|\(inputHash)|\(contextHash)"
        )

        if descriptor.useCache,
           let cached: CachedGenerationResult = loadCacheEntry(component: "generation", key: cacheKey)
        {
            return PairwiseGenerationOutput(
                text: cached.output,
                prompt: prompt,
                postMs: cached.postMs,
                cached: true,
                cacheKey: cacheKey
            )
        }

        let startedAt = DispatchTime.now()
        let result = try await postProcessText(
            model: descriptor.model,
            apiKey: descriptor.apiKey,
            config: config,
            sttText: inputText,
            context: context,
            sttMode: "generation_pairwise_compare",
            templateOverride: descriptor.promptTemplate
        )
        let postMs = elapsedMs(since: startedAt)
        if descriptor.useCache {
            let cache = CachedGenerationResult(
                key: cacheKey,
                model: descriptor.model.rawValue,
                output: result.text,
                postMs: postMs,
                createdAt: WhispTime.isoNow()
            )
            try saveCacheEntry(component: "generation", key: cacheKey, value: cache)
        }
        return PairwiseGenerationOutput(
            text: result.text,
            prompt: prompt,
            postMs: postMs,
            cached: false,
            cacheKey: cacheKey
        )
    }

    private static func makePairwiseCandidateDescriptor(candidate: BenchmarkCandidate, config: Config) throws -> PairwiseCandidateDescriptor {
        guard let parsed = LLMModelCatalog.resolveRegistered(rawValue: candidate.model) else {
            throw AppError.invalidArgument("candidate \(candidate.id): generation model が不正です: \(candidate.model)")
        }
        let model = APIKeyResolver.effectivePostProcessModel(parsed)
        let apiKey = try APIKeyResolver.llmKey(config: config, model: model)
        let promptTemplate = (candidate.generationPromptTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptTemplate.isEmpty else {
            throw AppError.invalidArgument("candidate \(candidate.id): generation_prompt_template が未設定です")
        }
        let promptHash = candidate.generationPromptHash ?? promptTemplateHash(promptTemplate)
        return PairwiseCandidateDescriptor(
            id: candidate.id,
            model: model,
            promptName: candidate.promptName,
            promptTemplate: promptTemplate,
            promptHash: promptHash,
            requireContext: try parseCandidateBoolOption(candidate.options, key: "require_context", defaultValue: false),
            useCache: try parseCandidateBoolOption(candidate.options, key: "use_cache", defaultValue: true),
            apiKey: apiKey
        )
    }

    static func parseCandidateBoolOption(_ options: [String: String], key: String, defaultValue: Bool) throws -> Bool {
        guard let raw = options[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return defaultValue
        }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            throw AppError.invalidArgument("candidate option \(key) は bool で指定してください")
        }
    }

    private static func aggregatePairwiseJudgement(round1: PairwiseJudgeResult, round2Swapped: PairwiseJudgeResult) -> PairwiseCaseJudgement {
        let round2 = normalizeSwappedJudgeResult(round2Swapped)
        let intentWinner = consensusWinner(primary: round1.intentWinner, secondary: round2.intentWinner)
        let hallucinationWinner = consensusWinner(primary: round1.hallucinationWinner, secondary: round2.hallucinationWinner)
        let styleWinner = consensusWinner(primary: round1.styleContextWinner, secondary: round2.styleContextWinner)
        let overallWinner = majorityWinner(intentWinner: intentWinner, hallucinationWinner: hallucinationWinner, styleWinner: styleWinner)
        return PairwiseCaseJudgement(
            overallWinner: overallWinner,
            intentWinner: intentWinner,
            hallucinationWinner: hallucinationWinner,
            styleContextWinner: styleWinner,
            overallReason: mergedReason(primaryWinner: round1.overallWinner, primaryReason: round1.overallReason, secondaryWinner: round2.overallWinner, secondaryReason: round2.overallReason, finalWinner: overallWinner),
            intentReason: mergedReason(primaryWinner: round1.intentWinner, primaryReason: round1.intentReason, secondaryWinner: round2.intentWinner, secondaryReason: round2.intentReason, finalWinner: intentWinner),
            hallucinationReason: mergedReason(primaryWinner: round1.hallucinationWinner, primaryReason: round1.hallucinationReason, secondaryWinner: round2.hallucinationWinner, secondaryReason: round2.hallucinationReason, finalWinner: hallucinationWinner),
            styleContextReason: mergedReason(primaryWinner: round1.styleContextWinner, primaryReason: round1.styleContextReason, secondaryWinner: round2.styleContextWinner, secondaryReason: round2.styleContextReason, finalWinner: styleWinner),
            confidence: mergedConfidence(round1.confidence, round2.confidence)
        )
    }

    private static func normalizeSwappedJudgeResult(_ result: PairwiseJudgeResult) -> PairwiseJudgeResult {
        PairwiseJudgeResult(
            overallWinner: swappedWinner(result.overallWinner),
            intentWinner: swappedWinner(result.intentWinner),
            hallucinationWinner: swappedWinner(result.hallucinationWinner),
            styleContextWinner: swappedWinner(result.styleContextWinner),
            overallReason: result.overallReason,
            intentReason: result.intentReason,
            hallucinationReason: result.hallucinationReason,
            styleContextReason: result.styleContextReason,
            confidence: result.confidence
        )
    }

    private static func swappedWinner(_ winner: PairwiseWinner) -> PairwiseWinner {
        switch winner {
        case .a:
            return .b
        case .b:
            return .a
        case .tie:
            return .tie
        }
    }

    private static func consensusWinner(primary: PairwiseWinner, secondary: PairwiseWinner) -> PairwiseWinner {
        primary == secondary ? primary : .tie
    }

    private static func majorityWinner(intentWinner: PairwiseWinner, hallucinationWinner: PairwiseWinner, styleWinner: PairwiseWinner) -> PairwiseWinner {
        let winners = [intentWinner, hallucinationWinner, styleWinner]
        let aWins = winners.filter { $0 == .a }.count
        let bWins = winners.filter { $0 == .b }.count
        if aWins > bWins {
            return .a
        }
        if bWins > aWins {
            return .b
        }
        return .tie
    }

    private static func mergedReason(
        primaryWinner: PairwiseWinner,
        primaryReason: String?,
        secondaryWinner: PairwiseWinner,
        secondaryReason: String?,
        finalWinner: PairwiseWinner
    ) -> String? {
        if finalWinner == primaryWinner {
            return primaryReason
        }
        if finalWinner == secondaryWinner {
            return secondaryReason
        }
        let trimmedPrimary = (primaryReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecondary = (secondaryReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrimary.isEmpty && trimmedSecondary.isEmpty {
            return "2回判定が一致しなかったため tie"
        }
        if trimmedPrimary.isEmpty {
            return "\(trimmedSecondary) / 不一致のため tie"
        }
        if trimmedSecondary.isEmpty {
            return "\(trimmedPrimary) / 不一致のため tie"
        }
        return "\(trimmedPrimary) / \(trimmedSecondary)"
    }

    private static func mergedConfidence(_ primary: String?, _ secondary: String?) -> String? {
        let p = (primary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let s = (secondary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return s.isEmpty ? nil : s }
        if s.isEmpty { return p }
        return p == s ? p : "mixed"
    }

    private static func encodePairwiseDecisionJSON(_ judgement: PairwiseCaseJudgement) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(judgement),
           let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        return "{}"
    }

    private static func makeGenerationPairwiseRunMetrics(
        allCasesCount: Int,
        selectedCasesCount: Int,
        summary: PairwiseOutcomeSummary
    ) -> BenchmarkRunMetrics {
        .generationPairwise(BenchmarkGenerationPairwiseRunMetrics(
            counts: BenchmarkRunCounts(
                casesTotal: allCasesCount,
                casesSelected: selectedCasesCount,
                executedCases: summary.executed,
                skippedCases: summary.skipped,
                failedCases: summary.failed,
                cachedHits: summary.cachedHits
            ),
            pairwiseSummary: summary.pairwiseSummary
        ))
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

    private struct GenerationOutcomeSummary: Sendable {
        var executed = 0
        var skipped = 0
        var failed = 0
        var cachedHits = 0
        var exactCount = 0
        var cerValues: [Double] = []
        var totalEdits = 0
        var totalRefChars = 0
        var postLatencies: [Double] = []
        var intentPreservationValues: [Double] = []
        var hallucinationScoreValues: [Double] = []
        var hallucinationRateValues: [Double] = []
        var llmEvalEvaluatedCases = 0
        var llmEvalErrorCases = 0
        var llmEvalUnavailableReason: String?
        var resolvedLLMEvalModel: String?
    }

    private actor GenerationOutcomeAccumulator {
        private var summary = GenerationOutcomeSummary()

        func consume(_ outcome: GenerationCaseWorkerOutcome, recorder: BenchmarkRunRecorder) throws {
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
            if let postMs = outcome.postMs {
                summary.postLatencies.append(postMs)
            }
            if let score = outcome.intentPreservationScore {
                summary.intentPreservationValues.append(score)
            }
            if let score = outcome.hallucinationScore {
                summary.hallucinationScoreValues.append(score)
            }
            if let rate = outcome.hallucinationRate {
                summary.hallucinationRateValues.append(rate)
            }
            summary.llmEvalEvaluatedCases += outcome.llmEvalEvaluatedCases
            summary.llmEvalErrorCases += outcome.llmEvalErrorCases
            if summary.llmEvalUnavailableReason == nil, let note = outcome.llmEvalUnavailableReason {
                summary.llmEvalUnavailableReason = note
            }
            if summary.resolvedLLMEvalModel == nil, let model = outcome.resolvedLLMEvalModel {
                summary.resolvedLLMEvalModel = model
            }

            try recorder.appendCaseResult(outcome.result)
            try recorder.appendEvents(outcome.events)
            for write in outcome.ioWrites {
                try recorder.writeCaseIOText(caseID: outcome.result.id, fileName: write.fileName, text: write.text)
            }
        }

        func snapshot() -> GenerationOutcomeSummary {
            summary
        }
    }

    private static func makeGenerationRunMetrics(
        allCasesCount: Int,
        selectedCasesCount: Int,
        summary: GenerationOutcomeSummary
    ) -> BenchmarkRunMetrics {
        let exactRate = summary.executed > 0 ? Double(summary.exactCount) / Double(summary.executed) : 0
        let postDistribution = latencyDistribution(values: summary.postLatencies)
        return .generation(BenchmarkGenerationRunMetrics(
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
            intentPreservationScore: summary.intentPreservationValues.isEmpty ? nil : summary.intentPreservationValues.reduce(0, +) / Double(summary.intentPreservationValues.count),
            hallucinationScore: summary.hallucinationScoreValues.isEmpty ? nil : summary.hallucinationScoreValues.reduce(0, +) / Double(summary.hallucinationScoreValues.count),
            hallucinationRate: summary.hallucinationRateValues.isEmpty ? nil : summary.hallucinationRateValues.reduce(0, +) / Double(summary.hallucinationRateValues.count),
            postLatencyMs: toBenchmarkLatencyDistribution(postDistribution)
        ))
    }

    private static func runGenerationCaseBenchmarkWithWorkers(
        runID: String,
        selectedCases: [ManualBenchmarkCase],
        options: GenerationBenchmarkOptions,
        config: Config,
        model: LLMModel,
        apiKey: String,
        recorder: BenchmarkRunRecorder,
        onOutcome: @escaping @Sendable (GenerationCaseWorkerOutcome) async throws -> Void
    ) async throws {
        try await runBenchmarkCaseWorkers(
            cases: selectedCases,
            workers: options.benchmarkWorkers
        ) { _, item in
            try recorder.markCaseStarted(caseID: item.id)
            return await executeGenerationCaseBenchmarkWorker(
                runID: runID,
                item: item,
                options: options,
                config: config,
                model: model,
                apiKey: apiKey
            )
        } onResult: { outcome in
            try await onOutcome(outcome)
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
            let artifacts = makeSkippedCaseArtifacts(
                runID: runID,
                caseID: item.id,
                caseStartedAtMs: caseStartedAtMs,
                reason: "stt入力がありません",
                cacheNamespace: "generation",
                sources: BenchmarkReferenceSources(),
                contextPresent: item.context != nil,
                visionImagePresent: item.visionImageFile != nil,
                audioFilePath: item.audioFile
            )
            return GenerationCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_input_stt\tfalse\t-\t-\t-\t-",
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
            let sources = BenchmarkReferenceSources(input: input.source)
            let artifacts = makeSkippedCaseArtifacts(
                runID: runID,
                caseID: item.id,
                caseStartedAtMs: caseStartedAtMs,
                reason: "参照テキストがありません",
                cacheNamespace: "generation",
                sources: sources,
                contextPresent: item.context != nil,
                visionImagePresent: item.visionImageFile != nil,
                audioFilePath: item.audioFile
            )
            return GenerationCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_reference\tfalse\t-\t-\t-\t-",
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
            let sources = BenchmarkReferenceSources(input: input.source, reference: reference.source)
            let artifacts = makeSkippedCaseArtifacts(
                runID: runID,
                caseID: item.id,
                caseStartedAtMs: caseStartedAtMs,
                reason: "--require-context が指定されています",
                cacheNamespace: "generation",
                sources: sources,
                contextPresent: false,
                visionImagePresent: item.visionImageFile != nil,
                audioFilePath: item.audioFile
            )
            return GenerationCaseWorkerOutcome(
                displayLine: "\(item.id)\tskipped_missing_context\tfalse\t-\t-\t-\t-",
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
            let promptTemplate = options.promptTemplateOverride ?? defaultPostProcessPromptTemplate
            let promptHash = options.promptHash ?? promptTemplateHash(promptTemplate)
            let renderedPrompt = makePostProcessPrompt(
                config: config,
                sttText: input.text,
                context: item.context,
                templateOverride: options.promptTemplateOverride
            )
            let cacheKey = sha256Hex(text: "generation-v2|\(model.rawValue)|\(config.inputLanguage)|\(promptHash)|\(inputHash)|\(contextHash)")
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
                    sttMode: "generation_benchmark",
                    templateOverride: options.promptTemplateOverride
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
                        createdAt: WhispTime.isoNow()
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
                    GenerationCaseIOWrite(fileName: "prompt_generation.txt", text: renderedPrompt),
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
