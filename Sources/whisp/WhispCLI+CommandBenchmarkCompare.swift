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

        for candidateID in options.candidateIDs {
            let candidate = try candidateStore.loadCandidate(id: candidateID)
            guard let candidate else {
                throw AppError.invalidArgument("candidate が見つかりません: \(candidateID)")
            }
            guard candidate.task == options.task else {
                throw AppError.invalidArgument("candidate \(candidateID) の task が一致しません (expected=\(options.task.rawValue), actual=\(candidate.task.rawValue))")
            }

            let runtimeHash = buildRuntimeOptionsHash(candidate: candidate)
            let key = BenchmarkKey(
                task: options.task,
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

            switch options.task {
            case .stt:
                let sttOptions = try makeSTTCompareOptions(
                    candidate: candidate,
                    datasetPath: datasetPath,
                    datasetHash: datasetHash,
                    runtimeHash: runtimeHash,
                    benchmarkKey: key,
                    benchmarkWorkers: options.benchmarkWorkers
                )
                try await runSTTCaseBenchmark(options: sttOptions)
            case .generation:
                let generationOptions = try makeGenerationCompareOptions(
                    candidate: candidate,
                    datasetPath: datasetPath,
                    datasetHash: datasetHash,
                    runtimeHash: runtimeHash,
                    benchmarkKey: key,
                    benchmarkWorkers: options.benchmarkWorkers
                )
                try await runGenerationCaseBenchmark(options: generationOptions)
            case .vision:
                throw AppError.invalidArgument("--benchmark-compare は stt/generation のみ対応です")
            }

            print("candidate: \(candidate.id)\tstatus: done")
        }
    }

    static func runBenchmarkListCandidates() throws {
        let store = BenchmarkCandidateStore()
        let candidates = try store.listCandidates()
        print("mode: benchmark_list_candidates")
        print("count: \(candidates.count)")
        for candidate in candidates {
            print("\(candidate.id)\ttask=\(candidate.task.rawValue)\tmodel=\(candidate.model)\tprompt_profile=\(candidate.promptProfileID ?? "-")")
        }
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
        // STT benchmark compare は fileReplayRealtime に固定する。
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

    private static func makeGenerationCompareOptions(
        candidate: BenchmarkCandidate,
        datasetPath: String,
        datasetHash: String,
        runtimeHash: String,
        benchmarkKey: BenchmarkKey,
        benchmarkWorkers: Int?
    ) throws -> GenerationBenchmarkOptions {
        guard let model = LLMModel(rawValue: candidate.model) else {
            throw AppError.invalidArgument("candidate \(candidate.id): generation model が不正です: \(candidate.model)")
        }

        let limit = try parseCandidateOptionalInt(candidate.options, key: "limit")
        let requireContext = try parseCandidateBool(candidate.options, key: "require_context", defaultValue: false)
        let useCache = try parseCandidateBool(candidate.options, key: "use_cache", defaultValue: true)
        let llmEvalEnabled = try parseCandidateBool(candidate.options, key: "llm_eval", defaultValue: false)
        let llmEvalModel: LLMModel?
        if let raw = candidate.options["llm_eval_model"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            guard let parsed = LLMModel(rawValue: raw) else {
                throw AppError.invalidArgument("candidate \(candidate.id): llm_eval_model が不正です: \(raw)")
            }
            llmEvalModel = parsed
        } else {
            llmEvalModel = nil
        }

        return GenerationBenchmarkOptions(
            jsonlPath: datasetPath,
            benchmarkWorkers: benchmarkWorkers,
            limit: limit,
            requireContext: requireContext,
            useCache: useCache,
            llmEvalEnabled: llmEvalEnabled,
            llmEvalModel: llmEvalModel,
            candidateID: candidate.id,
            datasetHash: datasetHash,
            runtimeOptionsHash: runtimeHash,
            evaluatorVersion: benchmarkKey.evaluatorVersion,
            codeVersion: benchmarkKey.codeVersion,
            benchmarkKey: benchmarkKey,
            modelOverride: model
        )
    }

    private static func buildRuntimeOptionsHash(candidate: BenchmarkCandidate) -> String {
        let effectiveOptions: [String: String]
        if candidate.task == .stt {
            effectiveOptions = candidate.options.filter { $0.key != "realtime" }
        } else {
            effectiveOptions = candidate.options
        }
        let sortedOptions = effectiveOptions.keys.sorted().map { "\($0)=\(effectiveOptions[$0] ?? "")" }.joined(separator: "|")
        let material = [
            "task=\(candidate.task.rawValue)",
            "model=\(candidate.model)",
            "prompt_profile=\(candidate.promptProfileID ?? "")",
            "options=\(sortedOptions)",
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
