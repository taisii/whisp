import Foundation
import WhispCore

extension WhispCLI {
    static func runBenchmarkCompare(options: BenchmarkCompareOptions) async throws {
        let candidateStore = BenchmarkCandidateStore()
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
        case .generation:
            try await runGenerationPairwiseBenchmarkCompare(
                options: options,
                datasetPath: datasetPath,
                datasetHash: datasetHash,
                candidateStore: candidateStore,
                benchmarkStore: benchmarkStore
            )
        case .vision:
            throw AppError.invalidArgument("--benchmark-compare は stt/generation のみ対応です")
        }
    }

    static func runBenchmarkListCandidates() throws {
        let store = BenchmarkCandidateStore()
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

            print("candidate: \(candidate.id)\tstatus: running\tmodel: \(candidate.model)")
            let sttOptions = try makeSTTCompareOptions(
                candidate: candidate,
                datasetPath: datasetPath,
                datasetHash: datasetHash,
                runtimeHash: runtimeHash,
                benchmarkKey: key,
                benchmarkWorkers: options.benchmarkWorkers
            )
            try await runSTTCaseBenchmark(options: sttOptions)
            print("candidate: \(candidate.id)\tstatus: done")
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

        let config = try loadConfig()
        let judgeModel = options.judgeModel ?? APIKeyResolver.effectivePostProcessModel(config.llmModel)
        let runtimeHash = try buildGenerationPairwiseRuntimeOptionsHash(
            candidateA: candidateA,
            candidateB: candidateB,
            judgeModel: judgeModel
        )
        let pairKey = "pair:\(candidateA.id)__vs__\(candidateB.id)"
        let key = BenchmarkKey(
            task: .generation,
            datasetPath: datasetPath,
            datasetHash: datasetHash,
            candidateID: pairKey,
            runtimeOptionsHash: runtimeHash,
            evaluatorVersion: "pairwise-v1",
            codeVersion: ProcessInfo.processInfo.environment["WHISP_CODE_VERSION"] ?? "dev"
        )

        print("pair_candidate_a: \(candidateA.id)")
        print("pair_candidate_b: \(candidateB.id)")
        print("judge_model: \(judgeModel.rawValue)")

        if !options.force,
           let existing = try benchmarkStore.findLatestCompletedRun(matching: key)
        {
            print("pair: \(candidateA.id) vs \(candidateB.id)\tstatus: skipped_existing\trun_id: \(existing.id)")
            return
        }

        let generationOptions = try makeGenerationPairwiseCompareOptions(
            candidateA: candidateA,
            candidateB: candidateB,
            judgeModel: judgeModel,
            datasetPath: datasetPath,
            datasetHash: datasetHash,
            runtimeHash: runtimeHash,
            benchmarkKey: key,
            benchmarkWorkers: options.benchmarkWorkers
        )
        print("pair: \(candidateA.id) vs \(candidateB.id)\tstatus: running")
        try await runGenerationPairwiseCompare(options: generationOptions)
        print("pair: \(candidateA.id) vs \(candidateB.id)\tstatus: done")
    }

    private static func makeSTTCompareOptions(
        candidate: BenchmarkCandidate,
        datasetPath: String,
        datasetHash: String,
        runtimeHash: String,
        benchmarkKey: BenchmarkKey,
        benchmarkWorkers: Int?
    ) throws -> STTBenchmarkOptions {
        let sttModeRaw = candidate.options["stt_mode"] ?? "stream"
        guard let sttMode = STTMode(rawValue: sttModeRaw) else {
            throw AppError.invalidArgument("candidate \(candidate.id): stt_mode は rest|stream を指定してください")
        }
        let chunkMs = try parseCandidateInt(candidate.options, key: "chunk_ms", defaultValue: 120)
        let realtime = true
        let minAudioSeconds = try parseCandidateDouble(candidate.options, key: "min_audio_seconds", defaultValue: 2.0)
        let useCache = try parseCandidateBool(candidate.options, key: "use_cache", defaultValue: true)
        let limit = try parseCandidateOptionalInt(candidate.options, key: "limit")
        guard let provider = STTProvider(rawValue: candidate.model) else {
            throw AppError.invalidArgument("candidate \(candidate.id): stt provider が不正です: \(candidate.model)")
        }
        if provider != .deepgram, sttMode == .stream {
            throw AppError.invalidArgument("candidate \(candidate.id): provider=\(provider.rawValue) は stt_mode=rest のみ対応です")
        }

        return STTBenchmarkOptions(
            jsonlPath: datasetPath,
            sttMode: sttMode,
            chunkMs: chunkMs,
            realtime: realtime,
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
            sttProvider: provider
        )
    }

    private static func makeGenerationPairwiseCompareOptions(
        candidateA: BenchmarkCandidate,
        candidateB: BenchmarkCandidate,
        judgeModel: LLMModel,
        datasetPath: String,
        datasetHash: String,
        runtimeHash: String,
        benchmarkKey: BenchmarkKey,
        benchmarkWorkers: Int?
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
            datasetHash: datasetHash,
            runtimeOptionsHash: runtimeHash,
            evaluatorVersion: benchmarkKey.evaluatorVersion,
            codeVersion: benchmarkKey.codeVersion,
            benchmarkKey: benchmarkKey
        )
    }

    private static func parseGenerationCandidateDescriptor(_ candidate: BenchmarkCandidate) throws -> (model: LLMModel, promptTemplate: String, promptHash: String) {
        guard let model = LLMModel(rawValue: candidate.model) else {
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
        let descriptorA = try parseGenerationCandidateDescriptor(candidateA)
        let descriptorB = try parseGenerationCandidateDescriptor(candidateB)
        let optionsA = candidateA.options.keys.sorted().map { "\($0)=\(candidateA.options[$0] ?? "")" }.joined(separator: "|")
        let optionsB = candidateB.options.keys.sorted().map { "\($0)=\(candidateB.options[$0] ?? "")" }.joined(separator: "|")
        let material = [
            "task=generation",
            "compare_mode=pairwise",
            "a.id=\(candidateA.id)",
            "a.model=\(descriptorA.model.rawValue)",
            "a.prompt_hash=\(descriptorA.promptHash)",
            "a.options=\(optionsA)",
            "b.id=\(candidateB.id)",
            "b.model=\(descriptorB.model.rawValue)",
            "b.prompt_hash=\(descriptorB.promptHash)",
            "b.options=\(optionsB)",
            "judge_model=\(judgeModel.rawValue)",
        ].joined(separator: "\n")
        return sha256Hex(text: material)
    }

    private static func normalizePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + "/" + trimmed.dropFirst(2)
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
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
}
