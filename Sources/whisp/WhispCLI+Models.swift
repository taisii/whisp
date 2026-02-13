import Foundation
import WhispCore

enum STTMode: String {
    case rest
    case stream
}

enum EmitMode: String {
    case discard
    case stdout
    case pbcopy
}

struct PipelineOptions {
    let path: String
    let sttMode: STTMode
    let chunkMs: Int
    let realtime: Bool
    let emitMode: EmitMode
    let contextFilePath: String?
}

struct PipelineRunResult {
    let model: LLMModel
    let sttText: String
    let outputText: String
    let sttSource: String
    let sttSendMs: Double
    let sttFinalizeMs: Double
    let sttTotalMs: Double
    let sttAfterStopMs: Double
    let postMs: Double
    let outputMs: Double
    let totalAfterStopMs: Double
    let totalWallMs: Double
    let audioSeconds: Double
}

enum IntentSource: String {
    case auto
    case gold
    case silver
}

struct IntentLabel: Codable {
    let intent: String
    let slots: [String: String]

    enum CodingKeys: String, CodingKey {
        case intent
        case slots
    }

    init(intent: String, slots: [String: String] = [:]) {
        self.intent = intent
        self.slots = slots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intent = try c.decode(String.self, forKey: .intent)
        slots = (try? c.decode([String: String].self, forKey: .slots)) ?? [:]
    }

    var canonicalJSONString: String {
        let payload: [String: Any] = [
            "intent": intent,
            "slots": slots,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{\"intent\":\"\(intent)\",\"slots\":{}}"
        }
        return text
    }
}

struct ManualBenchmarkLabels: Decodable {
    let transcriptGold: String?
    let transcriptSilver: String?
    let intentGold: IntentLabel?
    let intentSilver: IntentLabel?
    let labelConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case transcriptGold = "transcript_gold"
        case transcriptSilver = "transcript_silver"
        case intentGold = "intent_gold"
        case intentSilver = "intent_silver"
        case labelConfidence = "label_confidence"
    }
}

struct ManualBenchmarkAccessibilityTextRange: Decodable {
    let location: Int?
    let length: Int?
}

struct ManualBenchmarkAccessibilityFocusedElement: Decodable {
    let selectedText: String?
    let selectedRange: ManualBenchmarkAccessibilityTextRange?
    let caretContext: String?
    let caretContextRange: ManualBenchmarkAccessibilityTextRange?

    enum CodingKeys: String, CodingKey {
        case selectedText
        case selectedRange
        case caretContext
        case caretContextRange
    }
}

struct ManualBenchmarkAccessibilitySnapshot: Decodable {
    let focusedElement: ManualBenchmarkAccessibilityFocusedElement?

    enum CodingKeys: String, CodingKey {
        case focusedElement
    }
}

struct ManualBenchmarkCase: Decodable {
    let id: String
    let runID: String?
    let audioFile: String
    let sttText: String?
    let outputText: String?
    let groundTruthText: String?
    let createdAt: String?
    let llmModel: String?
    let appName: String?
    let context: ContextInfo?
    let accessibility: ManualBenchmarkAccessibilitySnapshot?
    let visionImageFile: String?
    let visionImageMimeType: String?
    let intentGold: IntentLabel?
    let intentSilver: IntentLabel?
    let labelConfidence: Double?
    let labels: ManualBenchmarkLabels?

    enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case audioFile = "audio_file"
        case sttText = "stt_text"
        case outputText = "output_text"
        case groundTruthText = "ground_truth_text"
        case createdAt = "created_at"
        case llmModel = "llm_model"
        case appName = "app_name"
        case context
        case accessibility
        case visionImageFile = "vision_image_file"
        case visionImageMimeType = "vision_image_mime_type"
        case intentGold = "intent_gold"
        case intentSilver = "intent_silver"
        case labelConfidence = "label_confidence"
        case labels
    }

    func resolvedReferenceTranscript() -> (text: String, source: String)? {
        let direct = (groundTruthText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return (direct, "ground_truth_text")
        }
        let gold = (labels?.transcriptGold ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gold.isEmpty {
            return (gold, "labels.transcript_gold")
        }
        let silver = (labels?.transcriptSilver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !silver.isEmpty {
            return (silver, "labels.transcript_silver")
        }
        return nil
    }

    func resolvedSTTReferenceTranscript() -> (text: String, source: String)? {
        let gold = (labels?.transcriptGold ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gold.isEmpty {
            return (gold, "labels.transcript_gold")
        }
        let stt = (sttText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stt.isEmpty {
            return (stt, "stt_text")
        }
        let silver = (labels?.transcriptSilver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !silver.isEmpty {
            return (silver, "labels.transcript_silver")
        }
        let direct = (groundTruthText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return (direct, "ground_truth_text")
        }
        return nil
    }

    func resolvedGenerationInputSTT() -> (text: String, source: String)? {
        let stt = (sttText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stt.isEmpty {
            return (stt, "stt_text")
        }
        return nil
    }

    func resolvedGenerationReferenceText() -> (text: String, source: String)? {
        let direct = (groundTruthText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return (direct, "ground_truth_text")
        }
        let gold = (labels?.transcriptGold ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gold.isEmpty {
            return (gold, "labels.transcript_gold")
        }
        let silver = (labels?.transcriptSilver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !silver.isEmpty {
            return (silver, "labels.transcript_silver")
        }
        return nil
    }

    func resolvedVisionReference() -> (summary: String, terms: [String])? {
        guard let context else { return nil }
        let summary = (context.visionSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = context.visionTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if summary.isEmpty, terms.isEmpty {
            return nil
        }
        return (summary, terms)
    }

    func resolvedLabelConfidence() -> Double? {
        if let labelConfidence {
            return labelConfidence
        }
        return labels?.labelConfidence
    }

    func resolvedReferenceIntent(source: IntentSource) -> (label: IntentLabel, source: String)? {
        switch source {
        case .gold:
            if let intentGold {
                return (intentGold, "intent_gold")
            }
            if let intent = labels?.intentGold {
                return (intent, "labels.intent_gold")
            }
            return nil
        case .silver:
            if let intentSilver {
                return (intentSilver, "intent_silver")
            }
            if let intent = labels?.intentSilver {
                return (intent, "labels.intent_silver")
            }
            return nil
        case .auto:
            if let intentGold {
                return (intentGold, "intent_gold")
            }
            if let intent = labels?.intentGold {
                return (intent, "labels.intent_gold")
            }
            if let intentSilver {
                return (intentSilver, "intent_silver")
            }
            if let intent = labels?.intentSilver {
                return (intent, "labels.intent_silver")
            }
            return nil
        }
    }
}

struct IntentJudgeResult {
    let match: Bool
    let score: Int
}

struct IntentJudgeResponse: Decodable {
    let match: Bool
    let score: Int
    let errorType: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case match
        case score
        case errorType = "error_type"
        case reason
    }
}

struct LLMEvaluationResult {
    let intentPreservationScore: Double
    let hallucinationScore: Double
    let hallucinationRate: Double
}

struct LLMEvaluationResponse: Decodable {
    let intentPreservationScore: Double
    let hallucinationScore: Double
    let hallucinationRate: Double
    let reason: String?
    let errorType: String?

    enum CodingKeys: String, CodingKey {
        case intentPreservationScore = "intent_preservation_score"
        case hallucinationScore = "hallucination_score"
        case hallucinationRate = "hallucination_rate"
        case reason
        case errorType = "error_type"
    }
}

struct PairwiseJudgeResponse: Decodable {
    let overallWinner: String
    let intentWinner: String
    let hallucinationWinner: String
    let styleContextWinner: String
    let overallReason: String?
    let intentReason: String?
    let hallucinationReason: String?
    let styleContextReason: String?
    let confidence: String?

    enum CodingKeys: String, CodingKey {
        case overallWinner = "overall_winner"
        case intentWinner = "intent_winner"
        case hallucinationWinner = "hallucination_winner"
        case styleContextWinner = "style_context_winner"
        case overallReason = "overall_reason"
        case intentReason = "intent_reason"
        case hallucinationReason = "hallucination_reason"
        case styleContextReason = "style_context_reason"
        case confidence
    }
}

struct PairwiseJudgeResult {
    let overallWinner: PairwiseWinner
    let intentWinner: PairwiseWinner
    let hallucinationWinner: PairwiseWinner
    let styleContextWinner: PairwiseWinner
    let overallReason: String?
    let intentReason: String?
    let hallucinationReason: String?
    let styleContextReason: String?
    let confidence: String?
}

struct LatencyDistributionLog: Codable {
    let avg: Double?
    let p50: Double?
    let p95: Double?
    let p99: Double?
}

struct VisionBenchmarkOptions {
    let jsonlPath: String
    let limit: Int?
    let useCache: Bool
    let benchmarkWorkers: Int?
}

struct STTBenchmarkOptions {
    let jsonlPath: String
    let sttMode: STTMode
    let chunkMs: Int
    let realtime: Bool
    let benchmarkWorkers: Int?
    let limit: Int?
    let minAudioSeconds: Double
    let useCache: Bool
    let candidateID: String?
    let datasetHash: String?
    let runtimeOptionsHash: String?
    let evaluatorVersion: String?
    let codeVersion: String?
    let benchmarkKey: BenchmarkKey?
    let sttProvider: STTProvider
}

struct GenerationBenchmarkOptions {
    let jsonlPath: String
    let benchmarkWorkers: Int?
    let limit: Int?
    let requireContext: Bool
    let useCache: Bool
    let llmEvalEnabled: Bool
    let llmEvalModel: LLMModel?
    let candidateID: String?
    let datasetHash: String?
    let runtimeOptionsHash: String?
    let evaluatorVersion: String?
    let codeVersion: String?
    let benchmarkKey: BenchmarkKey?
    let modelOverride: LLMModel?
    let promptTemplateOverride: String?
    let promptName: String?
    let promptHash: String?
    let candidateSnapshot: BenchmarkCandidateSnapshot?
}

enum BenchmarkCompareFlow: String, Codable, CaseIterable, Sendable {
    case stt
    case generationSingle = "generation-single"
    case generationBattle = "generation-battle"

    var benchmarkKind: BenchmarkKind {
        switch self {
        case .stt:
            return .stt
        case .generationSingle, .generationBattle:
            return .generation
        }
    }

    var isGenerationSingle: Bool {
        self == .generationSingle
    }

    var isGenerationBattle: Bool {
        self == .generationBattle
    }
}

struct BenchmarkCompareOptions {
    let task: BenchmarkCompareFlow
    let casesPath: String
    let candidateIDs: [String]
    let force: Bool
    let benchmarkWorkers: Int?
    let judgeModel: LLMModel?
}

struct GenerationPairwiseCompareOptions {
    let jsonlPath: String
    let benchmarkWorkers: Int?
    let limit: Int?
    let candidateA: BenchmarkCandidate
    let candidateB: BenchmarkCandidate
    let judgeModel: LLMModel
    let judgeAPIKey: String?
    let datasetHash: String?
    let runtimeOptionsHash: String?
    let evaluatorVersion: String?
    let codeVersion: String?
    let benchmarkKey: BenchmarkKey?
    let pairCandidateASnapshot: BenchmarkCandidateSnapshot?
    let pairCandidateBSnapshot: BenchmarkCandidateSnapshot?
}

struct BenchmarkIntegrityScanOptions {
    let task: BenchmarkKind
    let casesPath: String
}

struct CachedVisionResult: Codable {
    let key: String
    let model: String
    let summary: String
    let terms: [String]
    let latencyMs: Double
    let createdAt: String
}

struct CachedSTTResult: Codable {
    let key: String
    let mode: String
    let transcript: String
    let totalMs: Double
    let afterStopMs: Double
    let createdAt: String
}

struct CachedGenerationResult: Codable {
    let key: String
    let model: String
    let output: String
    let postMs: Double
    let createdAt: String
}

struct TermScore {
    let precision: Double
    let recall: Double
    let f1: Double
}

struct GeminiTextPart: Encodable {
    let text: String
}

struct GeminiTextContent: Encodable {
    let role: String
    let parts: [GeminiTextPart]
}

struct GeminiTextRequest: Encodable {
    let contents: [GeminiTextContent]
}

struct OpenAITextMessage: Encodable {
    let role: String
    let content: String
}

struct OpenAITextRequest: Encodable {
    let model: String
    let messages: [OpenAITextMessage]
}

struct GeminiInlineData: Encodable {
    let mimeType: String
    let data: String
}

enum GeminiMultimodalPart: Encodable {
    case text(String)
    case inlineData(GeminiInlineData)

    private enum CodingKeys: String, CodingKey {
        case text
        case inlineData
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode(value, forKey: .text)
        case let .inlineData(value):
            try container.encode(value, forKey: .inlineData)
        }
    }
}

struct GeminiMultimodalContent: Encodable {
    let role: String
    let parts: [GeminiMultimodalPart]
}

struct GeminiMultimodalRequest: Encodable {
    let contents: [GeminiMultimodalContent]
}

struct OpenAIImageURLContent: Encodable {
    let url: String
}

enum OpenAIChatContentPart: Encodable {
    case text(String)
    case imageURL(OpenAIImageURLContent)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    private enum ContentType: String, Encodable {
        case text
        case imageURL = "image_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode(ContentType.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case let .imageURL(value):
            try container.encode(ContentType.imageURL, forKey: .type)
            try container.encode(value, forKey: .imageURL)
        }
    }
}

enum OpenAIChatMessageContent: Encodable {
    case text(String)
    case parts([OpenAIChatContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value):
            try container.encode(value)
        case let .parts(value):
            try container.encode(value)
        }
    }
}

struct OpenAIChatMessage: Encodable {
    let role: String
    let content: OpenAIChatMessageContent
}

struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
}
