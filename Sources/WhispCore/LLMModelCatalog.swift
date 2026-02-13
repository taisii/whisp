import Foundation

public enum LLMProvider: String, Codable, Sendable {
    case gemini
    case openai
}

public struct LLMModelCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let supportsVision = LLMModelCapabilities(rawValue: 1 << 0)
    public static let supportsDirectAudioInput = LLMModelCapabilities(rawValue: 1 << 1)
    public static let selectableInSettings = LLMModelCapabilities(rawValue: 1 << 2)
    public static let selectableAsBenchmarkJudge = LLMModelCapabilities(rawValue: 1 << 3)
    public static let selectableAsPromptCandidate = LLMModelCapabilities(rawValue: 1 << 4)
    public static let selectableAsLLMEvalModel = LLMModelCapabilities(rawValue: 1 << 5)
}

public enum LLMSelectionSurface: Sendable {
    case appSettings
    case benchmarkJudge
    case benchmarkPromptCandidate
    case cliJudge
    case cliLLMEval
    case pipelineExecution
}

public struct LLMModelSpec: Sendable {
    public let id: LLMModelID
    public let displayName: String
    public let provider: LLMProvider
    public let apiModelName: String
    public let capabilities: LLMModelCapabilities
    public let sortOrder: Int

    public init(
        id: LLMModelID,
        displayName: String,
        provider: LLMProvider,
        apiModelName: String,
        capabilities: LLMModelCapabilities,
        sortOrder: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.apiModelName = apiModelName
        self.capabilities = capabilities
        self.sortOrder = sortOrder
    }
}

public enum LLMModelCatalog {
    public static let specs: [LLMModelSpec] = [
        LLMModelSpec(
            id: .gemini3FlashPreview,
            displayName: "Gemini 3 Flash Preview",
            provider: .gemini,
            apiModelName: "gemini-3-flash-preview",
            capabilities: [.supportsVision, .selectableInSettings, .selectableAsBenchmarkJudge, .selectableAsPromptCandidate, .selectableAsLLMEvalModel],
            sortOrder: 10
        ),
        LLMModelSpec(
            id: .gemini25FlashLite,
            displayName: "Gemini 2.5 Flash Lite",
            provider: .gemini,
            apiModelName: "gemini-2.5-flash-lite",
            capabilities: [.supportsVision, .selectableInSettings, .selectableAsBenchmarkJudge, .selectableAsPromptCandidate, .selectableAsLLMEvalModel],
            sortOrder: 20
        ),
        LLMModelSpec(
            id: .gemini25FlashLiteAudio,
            displayName: "Gemini 2.5 Flash Lite Audio",
            provider: .gemini,
            apiModelName: "gemini-2.5-flash-lite",
            capabilities: [.supportsDirectAudioInput, .selectableInSettings],
            sortOrder: 30
        ),
        LLMModelSpec(
            id: .gpt4oMini,
            displayName: "GPT-4o mini",
            provider: .openai,
            apiModelName: "gpt-4o-mini",
            capabilities: [.supportsVision, .selectableInSettings, .selectableAsBenchmarkJudge, .selectableAsPromptCandidate],
            sortOrder: 40
        ),
        LLMModelSpec(
            id: .gpt5Nano,
            displayName: "GPT-5 nano",
            provider: .openai,
            apiModelName: "gpt-5-nano",
            capabilities: [.selectableInSettings, .selectableAsPromptCandidate, .selectableAsLLMEvalModel],
            sortOrder: 50
        ),
    ]

    private static let specsByID: [LLMModelID: LLMModelSpec] = {
        var table: [LLMModelID: LLMModelSpec] = [:]
        table.reserveCapacity(specs.count)
        for spec in specs {
            if table[spec.id] == nil {
                table[spec.id] = spec
            }
        }
        return table
    }()

    public static func spec(for model: LLMModelID) -> LLMModelSpec? {
        specsByID[model]
    }

    public static func isRegistered(_ model: LLMModelID) -> Bool {
        specsByID[model] != nil
    }

    public static func supports(_ capability: LLMModelCapabilities, model: LLMModelID) -> Bool {
        guard let spec = spec(for: model) else {
            return false
        }
        return spec.capabilities.contains(capability)
    }

    public static func selectionCapability(for surface: LLMSelectionSurface) -> LLMModelCapabilities {
        switch surface {
        case .appSettings:
            return .selectableInSettings
        case .benchmarkJudge, .cliJudge:
            return [.selectableAsBenchmarkJudge, .supportsVision]
        case .benchmarkPromptCandidate:
            return .selectableAsPromptCandidate
        case .cliLLMEval:
            return .selectableAsLLMEvalModel
        case .pipelineExecution:
            return []
        }
    }

    public static func selectableModels(for surface: LLMSelectionSurface) -> [LLMModelSpec] {
        let required = selectionCapability(for: surface)
        return specs
            .filter { spec in
                if required.isEmpty {
                    return true
                }
                return spec.capabilities.contains(required)
            }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.id.rawValue < rhs.id.rawValue
                }
                return lhs.sortOrder < rhs.sortOrder
            }
    }

    public static func selectableModelIDs(for surface: LLMSelectionSurface) -> [LLMModelID] {
        selectableModels(for: surface).map(\.id)
    }

    public static func isSelectable(_ model: LLMModelID, for surface: LLMSelectionSurface) -> Bool {
        let required = selectionCapability(for: surface)
        guard let spec = spec(for: model) else {
            return false
        }
        if required.isEmpty {
            return true
        }
        return spec.capabilities.contains(required)
    }

    public static func defaultModel(for surface: LLMSelectionSurface) -> LLMModelID {
        switch surface {
        case .appSettings, .benchmarkJudge, .benchmarkPromptCandidate, .pipelineExecution, .cliJudge:
            return .gemini25FlashLite
        case .cliLLMEval:
            return .gpt5Nano
        }
    }

    public static func resolveOrFallback(_ requested: LLMModelID, for surface: LLMSelectionSurface) -> LLMModelID {
        if isSelectable(requested, for: surface) {
            return requested
        }
        return defaultModel(for: surface)
    }

    public static func resolveRegistered(rawValue: String) -> LLMModelID? {
        guard let candidate = LLMModelID(rawValue: rawValue), isRegistered(candidate) else {
            return nil
        }
        return candidate
    }

    public static func allowedModelRawValues(for surface: LLMSelectionSurface) -> [String] {
        selectableModelIDs(for: surface).map(\.rawValue)
    }

    public static func allowedModelRawValueText(for surface: LLMSelectionSurface) -> String {
        allowedModelRawValues(for: surface).joined(separator: "|")
    }
}
