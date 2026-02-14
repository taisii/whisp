import Foundation

public enum BenchmarkCandidateDefaults {
    public static func ensureSeededAndNormalized(store: BenchmarkCandidateStore) throws {
        try ensureSeededIfNeeded(store: store)
        try normalizeGenerationCandidates(store: store)
    }

    public static func ensureSeededIfNeeded(store: BenchmarkCandidateStore) throws {
        let completedInitialSeed = try store.hasCompletedInitialSeed()
        let existing = try store.listCandidates()
        let now = WhispTime.isoNow()
        let defaults = defaultCandidates(now: now)

        if existing.isEmpty {
            try store.saveCandidates(defaults)
        } else {
            var merged = existing
            let existingIDs = Set(existing.map(\.id))
            for candidate in defaults where !existingIDs.contains(candidate.id) {
                merged.append(candidate)
            }
            if merged.count != existing.count {
                try store.saveCandidates(merged)
            }
        }

        if !completedInitialSeed {
            try store.markInitialSeedCompleted()
        }
    }

    public static func normalizeGenerationCandidates(store: BenchmarkCandidateStore) throws {
        let current = try store.listCandidates()
        let normalized = normalizedGenerationCandidates(from: current)
        if normalized.didChange {
            try store.saveCandidates(normalized.candidates)
        }
    }

    public static func defaultCandidates(now: String = WhispTime.isoNow()) -> [BenchmarkCandidate] {
        let defaultGenerationModel = LLMModelCatalog.defaultModel(for: .benchmarkPromptCandidate)
        let sttCandidates = defaultSTTCandidates(now: now)
        return sttCandidates + [
            BenchmarkCandidate(
                id: "generation-\(defaultGenerationModel.rawValue)-default",
                task: .generation,
                model: defaultGenerationModel.rawValue,
                promptName: "default",
                generationPromptTemplate: defaultPostProcessPromptTemplate,
                generationPromptHash: promptTemplateHash(defaultPostProcessPromptTemplate),
                options: [
                    "require_context": "false",
                    "use_cache": "true",
                ],
                createdAt: now,
                updatedAt: now
            ),
        ]
    }

    public static func normalizedGenerationCandidates(
        from candidates: [BenchmarkCandidate],
        now: String = WhispTime.isoNow()
    ) -> (candidates: [BenchmarkCandidate], didChange: Bool) {
        var updated: [BenchmarkCandidate] = []
        updated.reserveCapacity(candidates.count)
        var didChange = false

        for candidate in candidates {
            guard candidate.task == .generation else {
                updated.append(candidate)
                continue
            }

            let resolvedTemplate: String = {
                let trimmed = canonicalPromptTemplate(candidate.generationPromptTemplate ?? "")
                if trimmed.isEmpty {
                    return defaultPostProcessPromptTemplate
                }
                return trimmed
            }()
            let resolvedName: String = {
                let trimmed = (candidate.promptName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return candidate.id
                }
                return trimmed
            }()
            let resolvedHash = promptTemplateHash(resolvedTemplate)

            if candidate.promptName != resolvedName ||
                candidate.generationPromptTemplate != resolvedTemplate ||
                candidate.generationPromptHash != resolvedHash
            {
                didChange = true
                updated.append(BenchmarkCandidate(
                    id: candidate.id,
                    task: candidate.task,
                    model: candidate.model,
                    promptName: resolvedName,
                    generationPromptTemplate: resolvedTemplate,
                    generationPromptHash: resolvedHash,
                    options: candidate.options,
                    createdAt: candidate.createdAt,
                    updatedAt: now
                ))
            } else {
                updated.append(candidate)
            }
        }

        return (updated, didChange)
    }

    private static func defaultSTTCandidates(now: String) -> [BenchmarkCandidate] {
        let baseOptions: [String: String] = [
            "chunk_ms": "120",
            "realtime": "true",
            "silence_ms": "700",
            "max_segment_ms": "25000",
            "pre_roll_ms": "250",
            "min_audio_seconds": "2.0",
            "use_cache": "true",
        ]

        return STTPresetCatalog.settingsSpecs()
            .map { spec in
                let presetID = spec.id.rawValue.replacingOccurrences(of: "_", with: "-")
                return BenchmarkCandidate(
                    id: "stt-\(presetID)-default",
                    task: .stt,
                    model: spec.id.rawValue,
                    options: baseOptions,
                    createdAt: now,
                    updatedAt: now
                )
            }
    }
}
