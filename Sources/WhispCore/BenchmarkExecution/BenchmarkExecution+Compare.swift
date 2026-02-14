import Foundation

extension BenchmarkExecutor {
    private static let compareGlobalLaneID = "compare_global"

    private struct STTCompareExecutionPlan: Sendable {
        let candidateID: String
        let model: String
        let options: STTBenchmarkOptions
        let capability: STTCompareExecutionCapability
    }

    private actor CompareLaneLimiter {
        private var activeCounts: [String: Int] = [:]

        func withPermit<T: Sendable>(
            laneID: String,
            limit: Int,
            operation: @Sendable () async throws -> T
        ) async rethrows -> T {
            await acquire(laneID: laneID, limit: limit)
            defer { release(laneID: laneID) }
            return try await operation()
        }

        private func acquire(laneID: String, limit: Int) async {
            let maxActive = max(1, limit)
            while true {
                let current = activeCounts[laneID, default: 0]
                if current < maxActive {
                    activeCounts[laneID] = current + 1
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        private func release(laneID: String) {
            let current = activeCounts[laneID, default: 0]
            if current <= 1 {
                activeCounts.removeValue(forKey: laneID)
            } else {
                activeCounts[laneID] = current - 1
            }
        }
    }

    private actor STTCompareFailureCollector {
        private var failures: [(candidateID: String, reason: String)] = []

        func append(candidateID: String, reason: String) {
            failures.append((candidateID, reason))
        }

        func snapshot() -> [(candidateID: String, reason: String)] {
            failures
        }
    }

    static func runBenchmarkCompare(options: BenchmarkCompareOptions) async throws {
        let candidateStore = BenchmarkCandidateStore()
        try BenchmarkCandidateDefaults.ensureSeededAndNormalized(store: candidateStore)
        let benchmarkStore = BenchmarkStore()
        let datasetPath = normalizePath(options.casesPath)
        guard FileManager.default.fileExists(atPath: datasetPath) else {
            throw AppError.invalidArgument("cases file が見つかりません: \(datasetPath)")
        }

        let datasetData = try Data(contentsOf: URL(fileURLWithPath: datasetPath, isDirectory: false))
        let datasetHash = sha256Hex(data: datasetData)

        print("mode: benchmark_compare")
        print("task: \(options.task.rawValue)")
        print("cases: \(datasetPath)")
        print("dataset_hash: \(datasetHash)")
        print("candidate_count: \(options.candidateIDs.count)")
        print("benchmark_workers: \(resolveBenchmarkWorkers(options.benchmarkWorkers))")
        print("compare_workers: \(resolveCompareWorkers(options.compareWorkers))")
        print("force: \(options.force)")

        switch options.task {
        case .stt:
            try await runSTTBenchmarkCompare(
                options: options,
                datasetPath: datasetPath,
                datasetHash: datasetHash,
                candidateStore: candidateStore,
                benchmarkStore: benchmarkStore
            )
        case .generationSingle:
            try await runGenerationSingleBenchmarkCompare(
                options: options,
                datasetPath: datasetPath,
                datasetHash: datasetHash,
                candidateStore: candidateStore,
                benchmarkStore: benchmarkStore
            )
        case .generationBattle:
            try await runGenerationPairwiseBenchmarkCompare(
                options: options,
                datasetPath: datasetPath,
                datasetHash: datasetHash,
                candidateStore: candidateStore,
                benchmarkStore: benchmarkStore
            )
        }
    }

    private static func runGenerationSingleBenchmarkCompare(
        options: BenchmarkCompareOptions,
        datasetPath: String,
        datasetHash: String,
        candidateStore: BenchmarkCandidateStore,
        benchmarkStore: BenchmarkStore
    ) async throws {
        guard options.candidateIDs.count == 1 else {
            throw AppError.invalidArgument("generation-single は --candidate-id を1件指定してください")
        }
        let candidateID = options.candidateIDs[0]
        guard let candidate = try candidateStore.loadCandidate(id: candidateID) else {
            throw AppError.invalidArgument("candidate が見つかりません: \(candidateID)")
        }
        guard candidate.task == .generation else {
            throw AppError.invalidArgument("candidate \(candidate.id) は generation ではありません")
        }

        let runtimeHash = buildRuntimeOptionsHash(candidate: candidate)
        let key = BenchmarkKey(
            task: .generation,
            datasetPath: datasetPath,
            datasetHash: datasetHash,
            candidateID: candidate.id,
            runtimeOptionsHash: runtimeHash,
            evaluatorVersion: "single-v1",
            codeVersion: ProcessInfo.processInfo.environment["WHISP_CODE_VERSION"] ?? "dev"
        )

        print("candidate_id: \(candidate.id)")
        print("candidate_model: \(candidate.model)")
        print("runtime_hash: \(runtimeHash)")

        if !options.force,
           let existing = try benchmarkStore.findLatestCompletedRun(matching: key)
        {
            print("candidate: \(candidate.id)\tstatus: skipped_existing\trun_id: \(existing.id)")
            return
        }

        let runOptions = try makeGenerationSingleCompareOptions(
            candidate: candidate,
            datasetPath: datasetPath,
            datasetHash: datasetHash,
            runtimeHash: runtimeHash,
            benchmarkKey: key,
            benchmarkWorkers: options.benchmarkWorkers,
            compareWorkers: options.compareWorkers
        )
        print("candidate: \(candidate.id)\tstatus: running")
        try await runGenerationCaseBenchmark(options: runOptions)
        print("candidate: \(candidate.id)\tstatus: done")
    }

    static func runBenchmarkListCandidates() throws {
        let store = BenchmarkCandidateStore()
        try BenchmarkCandidateDefaults.ensureSeededAndNormalized(store: store)
        let candidates = try store.listCandidates()
        print("mode: benchmark_list_candidates")
        print("count: \(candidates.count)")
        for candidate in candidates {
            print("\(candidate.id)\ttask=\(candidate.task.rawValue)\tmodel=\(candidate.model)\tprompt_name=\(candidate.promptName ?? "-")")
        }
    }

    private static func runSTTBenchmarkCompare(
        options: BenchmarkCompareOptions,
        datasetPath: String,
        datasetHash: String,
        candidateStore: BenchmarkCandidateStore,
        benchmarkStore: BenchmarkStore
    ) async throws {
        let compareWorkers = resolveCompareWorkers(options.compareWorkers)
        var plans: [STTCompareExecutionPlan] = []

        for candidateID in options.candidateIDs {
            let candidate = try candidateStore.loadCandidate(id: candidateID)
            guard let candidate else {
                throw AppError.invalidArgument("candidate が見つかりません: \(candidateID)")
            }
            guard candidate.task == .stt else {
                throw AppError.invalidArgument("candidate \(candidateID) の task が一致しません (expected=stt, actual=\(candidate.task.rawValue))")
            }

            let runtimeHash = buildRuntimeOptionsHash(candidate: candidate)
            let key = BenchmarkKey(
                task: .stt,
                datasetPath: datasetPath,
                datasetHash: datasetHash,
                candidateID: candidate.id,
                runtimeOptionsHash: runtimeHash,
                evaluatorVersion: "v1",
                codeVersion: ProcessInfo.processInfo.environment["WHISP_CODE_VERSION"] ?? "dev"
            )

            if !options.force,
               let existing = try benchmarkStore.findLatestCompletedRun(matching: key)
            {
                print("candidate: \(candidate.id)\tstatus: skipped_existing\trun_id: \(existing.id)")
                continue
            }

            let sttOptions = try makeSTTCompareOptions(
                candidate: candidate,
                datasetPath: datasetPath,
                datasetHash: datasetHash,
                runtimeHash: runtimeHash,
                benchmarkKey: key,
                benchmarkWorkers: options.benchmarkWorkers,
                compareWorkers: compareWorkers
            )
            let capability = resolveSTTCompareExecutionCapability(
                options: sttOptions,
                compareWorkers: compareWorkers
            )
            plans.append(STTCompareExecutionPlan(
                candidateID: candidate.id,
                model: candidate.model,
                options: sttOptions,
                capability: capability
            ))
            print("candidate: \(candidate.id)\tstatus: queued\tlane: \(capability.laneID)")
        }

        let failureCollector = STTCompareFailureCollector()
        let laneLimiter = CompareLaneLimiter()

        await withTaskGroup(of: Void.self, returning: Void.self) { group in
            for plan in plans {
                group.addTask {
                    await laneLimiter.withPermit(
                        laneID: plan.capability.laneID,
                        limit: plan.capability.maxParallelCandidates
                    ) {
                        await laneLimiter.withPermit(
                            laneID: compareGlobalLaneID,
                            limit: compareWorkers
                        ) {
                            print("candidate: \(plan.candidateID)\tstatus: running\tmodel: \(plan.model)\tlane: \(plan.capability.laneID)")
                            do {
                                try await runSTTCaseBenchmark(options: plan.options)
                                print("candidate: \(plan.candidateID)\tstatus: done")
                            } catch {
                                let reason = error.localizedDescription
                                await failureCollector.append(candidateID: plan.candidateID, reason: reason)
                                print("candidate: \(plan.candidateID)\tstatus: failed\treason: \(reason)")
                            }
                        }
                    }
                }
            }
            await group.waitForAll()
        }

        let failures = await failureCollector.snapshot()
        if !failures.isEmpty {
            print("stt_compare_failures: \(failures.count)")
            for failure in failures {
                print("failed_candidate: \(failure.candidateID)\treason: \(failure.reason)")
            }
        }
    }

    private static func runGenerationPairwiseBenchmarkCompare(
        options: BenchmarkCompareOptions,
        datasetPath: String,
        datasetHash: String,
        candidateStore: BenchmarkCandidateStore,
        benchmarkStore: BenchmarkStore
    ) async throws {
        guard options.candidateIDs.count == 2 else {
            throw AppError.invalidArgument("generation compare は --candidate-id を2件指定してください")
        }
        guard let candidateA = try candidateStore.loadCandidate(id: options.candidateIDs[0]) else {
            throw AppError.invalidArgument("candidate が見つかりません: \(options.candidateIDs[0])")
        }
        guard let candidateB = try candidateStore.loadCandidate(id: options.candidateIDs[1]) else {
            throw AppError.invalidArgument("candidate が見つかりません: \(options.candidateIDs[1])")
        }
        guard candidateA.task == .generation else {
            throw AppError.invalidArgument("candidate \(candidateA.id) は generation ではありません")
        }
        guard candidateB.task == .generation else {
            throw AppError.invalidArgument("candidate \(candidateB.id) は generation ではありません")
        }
        guard candidateA.id != candidateB.id else {
            throw AppError.invalidArgument("generation compare は異なる candidate を2件指定してください")
        }

        let lookupCandidates = try buildGenerationPairwiseLookupCandidates(
            candidateA: candidateA,
            candidateB: candidateB,
            datasetPath: datasetPath,
            datasetHash: datasetHash,
            preferredJudgeModel: options.judgeModel
        )
        if !options.force,
           let existing = try findLatestCompletedPairwiseRun(
               lookupCandidates: lookupCandidates,
               benchmarkStore: benchmarkStore
           )
        {
            print("pair_candidate_a: \(candidateA.id)")
            print("pair_candidate_b: \(candidateB.id)")
            print("judge_model: \(existing.judgeModel.rawValue)")
            print("pair: \(candidateA.id) vs \(candidateB.id)\tstatus: skipped_existing\trun_id: \(existing.id)")
            return
        }

        let config = try loadConfig()
        let judgeContext = try APIKeyResolver.resolveIntentJudgeContext(
            config: config,
            preferredModel: options.judgeModel,
            requiresVision: true
        )
        let key = try makeGenerationPairwiseBenchmarkKey(
            candidateA: candidateA,
            candidateB: candidateB,
            datasetPath: datasetPath,
            datasetHash: datasetHash,
            judgeModel: judgeContext.model
        )

        print("pair_candidate_a: \(candidateA.id)")
        print("pair_candidate_b: \(candidateB.id)")
        print("judge_model: \(judgeContext.model.rawValue)")

        let generationOptions = try makeGenerationPairwiseCompareOptions(
            candidateA: candidateA,
            candidateB: candidateB,
            judgeModel: judgeContext.model,
            judgeAPIKey: judgeContext.apiKey,
            datasetPath: datasetPath,
            datasetHash: datasetHash,
            runtimeHash: key.runtimeOptionsHash,
            benchmarkKey: key,
            benchmarkWorkers: options.benchmarkWorkers,
            compareWorkers: options.compareWorkers
        )
        print("pair: \(candidateA.id) vs \(candidateB.id)\tstatus: running")
        try await runGenerationPairwiseCompare(options: generationOptions)
        print("pair: \(candidateA.id) vs \(candidateB.id)\tstatus: done")
    }

    private static func makeGenerationSingleCompareOptions(
        candidate: BenchmarkCandidate,
        datasetPath: String,
        datasetHash: String,
        runtimeHash: String,
        benchmarkKey: BenchmarkKey,
        benchmarkWorkers: Int?,
        compareWorkers: Int?
    ) throws -> GenerationBenchmarkOptions {
        let promptTemplate = (candidate.generationPromptTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if promptTemplate.isEmpty {
            throw AppError.invalidArgument("candidate \(candidate.id): generation_prompt_template が未設定です")
        }
        let parsedModel = LLMModelCatalog.resolveRegistered(rawValue: candidate.model)
        if parsedModel == nil {
            throw AppError.invalidArgument("candidate \(candidate.id): generation model が不正です: \(candidate.model)")
        }
        let limit = try parseCandidateOptionalInt(candidate.options, key: "limit")
        let requireContext = try parseCandidateBool(candidate.options, key: "require_context", defaultValue: false)
        let useCache = try parseCandidateBool(candidate.options, key: "use_cache", defaultValue: true)

        return GenerationBenchmarkOptions(
            jsonlPath: datasetPath,
            benchmarkWorkers: benchmarkWorkers,
            limit: limit,
            requireContext: requireContext,
            useCache: useCache,
            llmEvalEnabled: false,
            llmEvalModel: nil,
            candidateID: candidate.id,
            datasetHash: datasetHash,
            runtimeOptionsHash: runtimeHash,
            evaluatorVersion: benchmarkKey.evaluatorVersion,
            codeVersion: benchmarkKey.codeVersion,
            benchmarkKey: benchmarkKey,
            modelOverride: parsedModel,
            promptTemplateOverride: promptTemplate,
            promptName: candidate.promptName,
            promptHash: candidate.generationPromptHash ?? promptTemplateHash(promptTemplate),
            candidateSnapshot: makeCandidateSnapshot(candidate),
            compareWorkers: compareWorkers
        )
    }

    private static func makeSTTCompareOptions(
        candidate: BenchmarkCandidate,
        datasetPath: String,
        datasetHash: String,
        runtimeHash: String,
        benchmarkKey: BenchmarkKey,
        benchmarkWorkers: Int?,
        compareWorkers: Int?
    ) throws -> STTBenchmarkOptions {
        guard let preset = STTPresetID(rawValue: candidate.model) else {
            throw AppError.invalidArgument("candidate \(candidate.id): stt preset が不正です: \(candidate.model)")
        }
        guard STTPresetCatalog.isAvailableOnCurrentPlatform(preset) else {
            throw AppError.invalidArgument("candidate \(candidate.id): stt preset はこの環境で利用できません: \(candidate.model)")
        }
        let chunkMs = try parseCandidateInt(candidate.options, key: "chunk_ms", defaultValue: 120)
        let realtime = true
        let minAudioSeconds = try parseCandidateDouble(candidate.options, key: "min_audio_seconds", defaultValue: 2.0)
        let silenceMs = try parseCandidateInt(candidate.options, key: "silence_ms", defaultValue: STTSegmentationConfig().silenceMs)
        let maxSegmentMs = try parseCandidateInt(candidate.options, key: "max_segment_ms", defaultValue: STTSegmentationConfig().maxSegmentMs)
        let preRollMs = try parseCandidateInt(candidate.options, key: "pre_roll_ms", defaultValue: STTSegmentationConfig().preRollMs)
        let useCache = try parseCandidateBool(candidate.options, key: "use_cache", defaultValue: true)
        let limit = try parseCandidateOptionalInt(candidate.options, key: "limit")

        return STTBenchmarkOptions(
            jsonlPath: datasetPath,
            sttPreset: preset,
            chunkMs: chunkMs,
            realtime: realtime,
            silenceMs: silenceMs,
            maxSegmentMs: maxSegmentMs,
            preRollMs: preRollMs,
            benchmarkWorkers: benchmarkWorkers,
            limit: limit,
            minAudioSeconds: minAudioSeconds,
            useCache: useCache,
            candidateID: candidate.id,
            datasetHash: datasetHash,
            runtimeOptionsHash: runtimeHash,
            evaluatorVersion: benchmarkKey.evaluatorVersion,
            codeVersion: benchmarkKey.codeVersion,
            benchmarkKey: benchmarkKey,
            compareWorkers: compareWorkers
        )
    }

    private static func makeGenerationPairwiseCompareOptions(
        candidateA: BenchmarkCandidate,
        candidateB: BenchmarkCandidate,
        judgeModel: LLMModel,
        judgeAPIKey: String,
        datasetPath: String,
        datasetHash: String,
        runtimeHash: String,
        benchmarkKey: BenchmarkKey,
        benchmarkWorkers: Int?,
        compareWorkers: Int?
    ) throws -> GenerationPairwiseCompareOptions {
        _ = try parseGenerationCandidateDescriptor(candidateA)
        _ = try parseGenerationCandidateDescriptor(candidateB)
        let limitA = try parseCandidateOptionalInt(candidateA.options, key: "limit")
        let limitB = try parseCandidateOptionalInt(candidateB.options, key: "limit")
        let limit: Int?
        switch (limitA, limitB) {
        case let (.some(a), .some(b)):
            if a != b {
                throw AppError.invalidArgument("pairwise compare の limit が一致しません: \(candidateA.id)=\(a), \(candidateB.id)=\(b)")
            }
            limit = a
        case let (.some(a), .none):
            limit = a
        case let (.none, .some(b)):
            limit = b
        case (.none, .none):
            limit = nil
        }

        return GenerationPairwiseCompareOptions(
            jsonlPath: datasetPath,
            benchmarkWorkers: benchmarkWorkers,
            limit: limit,
            candidateA: candidateA,
            candidateB: candidateB,
            judgeModel: judgeModel,
            judgeAPIKey: judgeAPIKey,
            datasetHash: datasetHash,
            runtimeOptionsHash: runtimeHash,
            evaluatorVersion: benchmarkKey.evaluatorVersion,
            codeVersion: benchmarkKey.codeVersion,
            benchmarkKey: benchmarkKey,
            pairCandidateASnapshot: makeCandidateSnapshot(candidateA),
            pairCandidateBSnapshot: makeCandidateSnapshot(candidateB),
            compareWorkers: compareWorkers
        )
    }

    private static func parseGenerationCandidateDescriptor(_ candidate: BenchmarkCandidate) throws -> (model: LLMModel, promptTemplate: String, promptHash: String) {
        guard let model = LLMModelCatalog.resolveRegistered(rawValue: candidate.model) else {
            throw AppError.invalidArgument("candidate \(candidate.id): generation model が不正です: \(candidate.model)")
        }
        let trimmedPromptTemplate = (candidate.generationPromptTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPromptTemplate.isEmpty else {
            throw AppError.invalidArgument("candidate \(candidate.id): generation_prompt_template が未設定です")
        }
        let promptHash = candidate.generationPromptHash ?? promptTemplateHash(trimmedPromptTemplate)
        return (model, trimmedPromptTemplate, promptHash)
    }

    private static func buildRuntimeOptionsHash(candidate: BenchmarkCandidate) -> String {
        let effectiveOptions: [String: String]
        if candidate.task == .stt {
            effectiveOptions = candidate.options.filter { $0.key != "realtime" }
        } else {
            effectiveOptions = candidate.options
        }
        let promptHash: String
        if candidate.task == .generation {
            let template = (candidate.generationPromptTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !template.isEmpty {
                promptHash = candidate.generationPromptHash ?? promptTemplateHash(template)
            } else {
                promptHash = candidate.generationPromptHash ?? ""
            }
        } else {
            promptHash = ""
        }
        let sortedOptions = effectiveOptions.keys.sorted().map { "\($0)=\(effectiveOptions[$0] ?? "")" }.joined(separator: "|")
        let material = [
            "task=\(candidate.task.rawValue)",
            "model=\(candidate.model)",
            "prompt_hash=\(promptHash)",
            "options=\(sortedOptions)",
        ].joined(separator: "\n")
        return sha256Hex(text: material)
    }

    private static func buildGenerationPairwiseRuntimeOptionsHash(
        candidateA: BenchmarkCandidate,
        candidateB: BenchmarkCandidate,
        judgeModel: LLMModel
    ) throws -> String {
        let first: BenchmarkCandidate
        let second: BenchmarkCandidate
        if candidateA.id <= candidateB.id {
            first = candidateA
            second = candidateB
        } else {
            first = candidateB
            second = candidateA
        }
        let descriptorA = try parseGenerationCandidateDescriptor(first)
        let descriptorB = try parseGenerationCandidateDescriptor(second)
        let optionsA = first.options.keys.sorted().map { "\($0)=\(first.options[$0] ?? "")" }.joined(separator: "|")
        let optionsB = second.options.keys.sorted().map { "\($0)=\(second.options[$0] ?? "")" }.joined(separator: "|")
        let material = [
            "task=generation",
            "compare_mode=pairwise",
            "a.id=\(first.id)",
            "a.model=\(descriptorA.model.rawValue)",
            "a.prompt_hash=\(descriptorA.promptHash)",
            "a.options=\(optionsA)",
            "b.id=\(second.id)",
            "b.model=\(descriptorB.model.rawValue)",
            "b.prompt_hash=\(descriptorB.promptHash)",
            "b.options=\(optionsB)",
            "judge_model=\(judgeModel.rawValue)",
        ].joined(separator: "\n")
        return sha256Hex(text: material)
    }

    private struct PairwiseSkipLookupCandidate {
        let judgeModel: LLMModel
        let key: BenchmarkKey
    }

    private static func buildGenerationPairwiseLookupCandidates(
        candidateA: BenchmarkCandidate,
        candidateB: BenchmarkCandidate,
        datasetPath: String,
        datasetHash: String,
        preferredJudgeModel: LLMModel?
    ) throws -> [PairwiseSkipLookupCandidate] {
        let judgeModels: [LLMModel]
        if let preferredJudgeModel {
            judgeModels = [preferredJudgeModel]
        } else {
            judgeModels = LLMModelCatalog.selectableModelIDs(for: .cliJudge)
        }

        return try judgeModels.map { judgeModel in
            PairwiseSkipLookupCandidate(
                judgeModel: judgeModel,
                key: try makeGenerationPairwiseBenchmarkKey(
                    candidateA: candidateA,
                    candidateB: candidateB,
                    datasetPath: datasetPath,
                    datasetHash: datasetHash,
                    judgeModel: judgeModel
                )
            )
        }
    }

    private static func findLatestCompletedPairwiseRun(
        lookupCandidates: [PairwiseSkipLookupCandidate],
        benchmarkStore: BenchmarkStore
    ) throws -> (id: String, judgeModel: LLMModel)? {
        var latest: (run: BenchmarkRunRecord, judgeModel: LLMModel)?
        for candidate in lookupCandidates {
            guard let run = try benchmarkStore.findLatestCompletedRun(matching: candidate.key) else {
                continue
            }
            guard let current = latest else {
                latest = (run, candidate.judgeModel)
                continue
            }
            if run.updatedAt > current.run.updatedAt {
                latest = (run, candidate.judgeModel)
            }
        }
        guard let latest else {
            return nil
        }
        return (latest.run.id, latest.judgeModel)
    }

    static func makeGenerationPairwiseBenchmarkKey(
        candidateA: BenchmarkCandidate,
        candidateB: BenchmarkCandidate,
        datasetPath: String,
        datasetHash: String,
        judgeModel: LLMModel
    ) throws -> BenchmarkKey {
        let canonicalPair = BenchmarkPairwiseNormalizer.canonicalize(candidateA.id, candidateB.id)
        let runtimeHash = try buildGenerationPairwiseRuntimeOptionsHash(
            candidateA: candidateA,
            candidateB: candidateB,
            judgeModel: judgeModel
        )
        let pairKey = canonicalPair.pairKeyCandidateID
        return BenchmarkKey(
            task: .generation,
            datasetPath: datasetPath,
            datasetHash: datasetHash,
            candidateID: pairKey,
            runtimeOptionsHash: runtimeHash,
            evaluatorVersion: "pairwise-v1",
            codeVersion: ProcessInfo.processInfo.environment["WHISP_CODE_VERSION"] ?? "dev"
        )
    }

    private static func resolveSTTCompareExecutionCapability(
        options: STTBenchmarkOptions,
        compareWorkers: Int
    ) -> STTCompareExecutionCapability {
        let spec = STTPresetCatalog.spec(for: options.sttPreset)
        if spec.engine == .appleSpeech,
           options.sttMode == .stream
        {
            return STTCompareExecutionCapability(
                laneID: "apple_speech_stream",
                maxParallelCandidates: 1
            )
        }
        return STTCompareExecutionCapability(
            laneID: "stt_default",
            maxParallelCandidates: compareWorkers
        )
    }

    private static func normalizePath(_ raw: String) -> String {
        WhispPaths.normalizeForStorage(raw)
    }

    private static func parseCandidateBool(_ options: [String: String], key: String, defaultValue: Bool) throws -> Bool {
        guard let raw = options[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return defaultValue
        }
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            throw AppError.invalidArgument("candidate option \(key) は bool で指定してください")
        }
    }

    private static func parseCandidateInt(_ options: [String: String], key: String, defaultValue: Int) throws -> Int {
        guard let raw = options[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return defaultValue
        }
        guard let value = Int(raw) else {
            throw AppError.invalidArgument("candidate option \(key) は整数で指定してください")
        }
        return value
    }

    private static func parseCandidateOptionalInt(_ options: [String: String], key: String) throws -> Int? {
        guard let raw = options[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard let value = Int(raw) else {
            throw AppError.invalidArgument("candidate option \(key) は整数で指定してください")
        }
        return value
    }

    private static func parseCandidateDouble(_ options: [String: String], key: String, defaultValue: Double) throws -> Double {
        guard let raw = options[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return defaultValue
        }
        guard let value = Double(raw) else {
            throw AppError.invalidArgument("candidate option \(key) は数値で指定してください")
        }
        return value
    }

    private static func makeCandidateSnapshot(_ candidate: BenchmarkCandidate) -> BenchmarkCandidateSnapshot {
        BenchmarkCandidateSnapshot(
            id: candidate.id,
            model: candidate.model,
            promptName: candidate.promptName,
            generationPromptHash: candidate.generationPromptHash,
            generationPromptTemplate: candidate.generationPromptTemplate,
            options: candidate.options,
            capturedAt: WhispTime.isoNow()
        )
    }
}
