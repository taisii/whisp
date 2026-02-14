import Foundation

public struct GenerationPrimarySnapshot: Codable, Equatable, Sendable {
    public var model: LLMModel
    public var promptName: String?
    public var promptTemplate: String
    public var promptHash: String
    public var options: [String: String]
    public var capturedAt: String

    public init(
        model: LLMModel,
        promptName: String? = nil,
        promptTemplate: String,
        promptHash: String,
        options: [String: String] = [:],
        capturedAt: String
    ) {
        self.model = model
        self.promptName = promptName
        self.promptTemplate = promptTemplate
        self.promptHash = promptHash
        self.options = options
        self.capturedAt = capturedAt
    }
}

public struct GenerationPrimarySelection: Codable, Equatable, Sendable {
    public var candidateID: String
    public var snapshot: GenerationPrimarySnapshot
    public var selectedAt: String

    public init(candidateID: String, snapshot: GenerationPrimarySnapshot, selectedAt: String) {
        self.candidateID = candidateID
        self.snapshot = snapshot
        self.selectedAt = selectedAt
    }
}

public struct ResolvedGenerationPrimaryConfig: Equatable, Sendable {
    public var model: LLMModel
    public var promptTemplateOverride: String?
    public var requireContext: Bool
    public var usesSelection: Bool

    public init(
        model: LLMModel,
        promptTemplateOverride: String?,
        requireContext: Bool,
        usesSelection: Bool
    ) {
        self.model = model
        self.promptTemplateOverride = promptTemplateOverride
        self.requireContext = requireContext
        self.usesSelection = usesSelection
    }
}

public enum GenerationPrimaryConfigResolver {
    public static func resolve(config: Config) -> ResolvedGenerationPrimaryConfig {
        let fallbackModel = LLMModelCatalog.resolveOrFallback(config.llmModel, for: .pipelineExecution)
        guard let selection = config.generationPrimary else {
            return ResolvedGenerationPrimaryConfig(
                model: fallbackModel,
                promptTemplateOverride: nil,
                requireContext: false,
                usesSelection: false
            )
        }

        let snapshot = selection.snapshot
        guard LLMModelCatalog.isRegistered(snapshot.model) else {
            return ResolvedGenerationPrimaryConfig(
                model: fallbackModel,
                promptTemplateOverride: nil,
                requireContext: false,
                usesSelection: false
            )
        }

        let canonicalTemplate = canonicalPromptTemplate(snapshot.promptTemplate)
        guard !canonicalTemplate.isEmpty else {
            return ResolvedGenerationPrimaryConfig(
                model: fallbackModel,
                promptTemplateOverride: nil,
                requireContext: false,
                usesSelection: false
            )
        }

        return ResolvedGenerationPrimaryConfig(
            model: LLMModelCatalog.resolveOrFallback(snapshot.model, for: .pipelineExecution),
            promptTemplateOverride: canonicalTemplate,
            requireContext: boolOption(snapshot.options, key: "require_context", defaultValue: false),
            usesSelection: true
        )
    }

    private static func boolOption(_ options: [String: String], key: String, defaultValue: Bool) -> Bool {
        guard let raw = options[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else {
            return defaultValue
        }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }
}

public enum GenerationPrimarySelectionFactory {
    public static func makeSelection(
        candidate: BenchmarkCandidate,
        selectedAt: String = WhispTime.isoNow()
    ) -> GenerationPrimarySelection? {
        guard candidate.task == .generation else {
            return nil
        }
        guard let model = LLMModelCatalog.resolveRegistered(rawValue: candidate.model) else {
            return nil
        }
        let canonicalTemplate = canonicalPromptTemplate(candidate.generationPromptTemplate ?? "")
        guard !canonicalTemplate.isEmpty else {
            return nil
        }
        let now = selectedAt
        let snapshot = GenerationPrimarySnapshot(
            model: model,
            promptName: candidate.promptName,
            promptTemplate: canonicalTemplate,
            promptHash: candidate.generationPromptHash ?? promptTemplateHash(canonicalTemplate),
            options: candidate.options,
            capturedAt: now
        )
        return GenerationPrimarySelection(
            candidateID: candidate.id,
            snapshot: snapshot,
            selectedAt: now
        )
    }
}
